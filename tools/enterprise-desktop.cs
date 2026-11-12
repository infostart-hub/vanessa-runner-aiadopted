using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace VanessaRunner {
    // Read-only prerequisite of native interactive input, independent of MCP reachability.
    public sealed class ExecutionDesktop {
        public int sessionId;
        public string connection;
        public string desktop;
        public string inputDesktop;
        public int win32Error;
        public bool available;

        [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] private static extern IntPtr GetThreadDesktop(uint thread);
        [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
        [DllImport("user32.dll")] private static extern bool CloseDesktop(IntPtr handle);
        [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool GetUserObjectInformation(
            IntPtr handle, int index, StringBuilder data, int length, out int needed);
        [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool WTSQuerySessionInformation(
            IntPtr server, int session, int info, out IntPtr buffer, out int size);
        [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr buffer);

        private static string Name(IntPtr handle) {
            var data = new StringBuilder(256);
            int needed;
            if (handle == IntPtr.Zero || !GetUserObjectInformation(handle, 2, data, data.Capacity * 2, out needed))
                throw new InvalidOperationException("Execution desktop identity is unavailable: " + Marshal.GetLastWin32Error());
            return data.ToString();
        }

        public static ExecutionDesktop Read() {
            var context = new ExecutionDesktop();
            using (var process = Process.GetCurrentProcess()) context.sessionId = process.SessionId;
            IntPtr buffer; int size;
            if (!WTSQuerySessionInformation(IntPtr.Zero, context.sessionId, 8, out buffer, out size))
                throw new InvalidOperationException("Execution session state is unavailable: " + Marshal.GetLastWin32Error());
            int state;
            try {
                if (size < 4) throw new InvalidOperationException("Execution session state is incomplete");
                state = Marshal.ReadInt32(buffer);
            } finally { WTSFreeMemory(buffer); }
            var names = new [] { "active", "connected", "connect_query", "shadow", "disconnected", "idle", "listen", "reset", "down", "initializing" };
            if (state < 0 || state >= names.Length) throw new InvalidOperationException("Execution session state is unknown");
            context.connection = names[state];
            context.desktop = Name(GetThreadDesktop(GetCurrentThreadId()));
            var input = OpenInputDesktop(0, false, 1);
            if (input == IntPtr.Zero) context.win32Error = Marshal.GetLastWin32Error();
            else {
                try { context.inputDesktop = Name(input); }
                finally { CloseDesktop(input); }
            }
            context.available = state == 0 && context.inputDesktop == context.desktop;
            return context;
        }
    }
}
