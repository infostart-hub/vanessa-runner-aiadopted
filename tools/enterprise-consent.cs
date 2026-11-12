using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Text;

namespace VanessaRunner {
    // Address input to the validated 1C dialog. No global keyboard, cursor,
    // foreground activation or dependency on the user's RDP connection.
    public static class ProcessingConsentInput {
        [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll")] private static extern IntPtr GetThreadDesktop(uint thread);
        [DllImport("user32.dll", SetLastError=true)] private static extern bool PostMessage(
            IntPtr window, uint message, UIntPtr key, IntPtr flags);
        [DllImport("user32.dll")] private static extern uint MapVirtualKey(uint key, uint mapping);

        private delegate bool WindowVisitor(IntPtr window, IntPtr data);
        [DllImport("user32.dll", SetLastError=true)] private static extern bool EnumWindows(WindowVisitor visitor, IntPtr data);
        [DllImport("user32.dll", SetLastError=true)] private static extern bool EnumDesktopWindows(IntPtr desktop, WindowVisitor visitor, IntPtr data);
        [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr OpenDesktop(string desktop, uint flags, bool inherit, uint access);
        [DllImport("user32.dll", SetLastError=true)] private static extern bool CloseDesktop(IntPtr desktop);
        [DllImport("user32.dll", SetLastError=true)] private static extern bool SetThreadDesktop(IntPtr desktop);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder buffer, int capacity);

        // Enumerate native HWNDs without querying UIA providers on the desktop.
        // UI Automation starts only at an exact, visible, process-owned HWND.
        [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint relationship);
        [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr window);

        private static string WindowClassName(IntPtr window) {
            var buffer = new StringBuilder(128);
            int length = GetClassName(window, buffer, buffer.Capacity);
            return length > 0 ? buffer.ToString(0, length) : string.Empty;
        }

        private static bool IsAuxiliaryPopup(IntPtr window) {
            string cls = WindowClassName(window);
            return cls == "V8DropWindowExWnd" || cls == "#32768";
        }

        public static bool WindowBelongsToProcess(int expectedProcess, IntPtr window) {
            if (expectedProcess <= 0) throw new ArgumentOutOfRangeException("expectedProcess");
            uint process;
            return window != IntPtr.Zero && GetWindowThreadProcessId(window, out process) != 0 && process == expectedProcess;
        }

        public static IntPtr[] DialogsForProcess(int expectedProcess) {
            var result = new List<IntPtr>();
            foreach (var window in WindowsForProcess(expectedProcess)) {
                // 1C can place a visible dialog over an invisible owned container.
                // Validate the complete native owner chain, never a foreign HWND.
                var owner = GetWindow(window, 4);
                var visited = new HashSet<IntPtr>();
                while (owner != IntPtr.Zero && visited.Add(owner)) {
                    uint process;
                    if (GetWindowThreadProcessId(owner, out process) == 0 || process != expectedProcess) break;
                    if (!IsWindowEnabled(owner)) { result.Add(window); break; }
                    owner = GetWindow(owner, 4);
                }
            }
            return result.ToArray();
        }

        public static IntPtr[] WindowsForProcess(int expectedProcess) {
            if (expectedProcess <= 0) throw new ArgumentOutOfRangeException("expectedProcess");
            var seen = new HashSet<IntPtr>();
            var result = new List<IntPtr>();
            WindowVisitor visitor = delegate(IntPtr window, IntPtr data) {
                uint process;
                if (GetWindowThreadProcessId(window, out process) != 0 &&
                    process == expectedProcess && IsWindowVisible(window) && seen.Add(window)) {
                    result.Add(window);
                }
                return true;
            };
            if (!EnumWindows(visitor, IntPtr.Zero))
                throw new InvalidOperationException("Owned window enumeration failed: " + Marshal.GetLastWin32Error());
            var previousDesktop = GetThreadDesktop(GetCurrentThreadId());
            var desktop = OpenDesktop("Default", 0, false, 0x10000000);
            if (desktop != IntPtr.Zero) {
                try {
                    SetThreadDesktop(desktop);
                    EnumDesktopWindows(desktop, visitor, IntPtr.Zero);
                } finally {
                    if (previousDesktop != IntPtr.Zero) SetThreadDesktop(previousDesktop);
                    CloseDesktop(desktop);
                }
            }
            return result.ToArray();
        }

        // A process's cached MainWindowHandle is not a live execution surface.
        // A visible root may be owned by an invisible platform container.
        public static IntPtr PrimaryWindowForProcess(int expectedProcess) {
            var visible = new HashSet<IntPtr>(WindowsForProcess(expectedProcess));
            var roots = new List<IntPtr>();
            foreach (var window in visible) {
                if (IsAuxiliaryPopup(window)) continue;
                var owner = GetWindow(window, 4);
                var visited = new HashSet<IntPtr>();
                bool nested = false;
                while (owner != IntPtr.Zero && visited.Add(owner)) {
                    uint process;
                    if (GetWindowThreadProcessId(owner, out process) == 0 || process != expectedProcess)
                        return IntPtr.Zero; // Refuse the surface; process observation remains available.
                    if (visible.Contains(owner)) { nested = true; break; }
                    owner = GetWindow(owner, 4);
                }
                if (!nested) roots.Add(window);
            }
            if (roots.Count != 1) return IntPtr.Zero;
            if (IsIconic(roots[0])) {
                ShowWindow(roots[0], 9);
                if (IsIconic(roots[0])) return IntPtr.Zero;
            }
            return roots[0];
        }

        public static int DismissPopups(int expectedProcess) {
            var visible = WindowsForProcess(expectedProcess);
            int dismissed = 0;
            foreach (var window in visible) {
                if (!IsAuxiliaryPopup(window)) continue;
                var root = PrimaryWindowForProcess(expectedProcess);
                if (root != IntPtr.Zero) {
                    const uint vkReturn = 0x0D;
                    uint flags = 1 | (MapVirtualKey(vkReturn, 0) << 16);
                    PostMessage(root, 0x0100, new UIntPtr(vkReturn), new IntPtr((long)flags));
                    PostMessage(root, 0x0101, new UIntPtr(vkReturn), new IntPtr(unchecked((int)(flags | 0xc0000000))));
                }
                PostMessage(window, 0x0010, UIntPtr.Zero, IntPtr.Zero);
                dismissed++;
            }
            return dismissed;
        }

        public static bool RequestClose(int expectedProcess, IntPtr window) {
            uint process;
            if (window == IntPtr.Zero || !IsWindowVisible(window) ||
                GetWindowThreadProcessId(window, out process) == 0 || process != expectedProcess)
                throw new InvalidOperationException("Close surface is not currently owned and visible");
            return PostMessage(window, 0x0010, UIntPtr.Zero, IntPtr.Zero);
        }

        public static void Activate(int expectedProcess, IntPtr window) {
            uint process;
            if (window == IntPtr.Zero || window == new IntPtr(0xffff) ||
                GetWindowThreadProcessId(window, out process) == 0 || process != expectedProcess)
                throw new InvalidOperationException("Consent window is not owned by the manager");
            const uint space = 0x20;
            uint flags = 1 | (MapVirtualKey(space, 0) << 16);
            if (!PostMessage(window, 0x0100, new UIntPtr(space), new IntPtr((long)flags)))
                throw new InvalidOperationException("Consent key down was not queued: " + Marshal.GetLastWin32Error());
            if (!PostMessage(window, 0x0101, new UIntPtr(space), new IntPtr(unchecked((int)(flags | 0xc0000000)))))
                throw new InvalidOperationException("Consent key up was not queued: " + Marshal.GetLastWin32Error());
            // Queuing input is not acceptance. The owner observes actual
            // processing/client/scenario progress separately.
        }
    }
}
