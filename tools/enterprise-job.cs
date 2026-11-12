using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace VanessaRunner {
    // Run-scoped job. No KILL_ON_JOB_CLOSE: losing a connection never kills 1C.
    public sealed class ProcessJob : IDisposable {
        private IntPtr job;
        private IntPtr port;
        [StructLayout(LayoutKind.Sequential)]
        private struct CompletionPort { public IntPtr Key; public IntPtr Port; }
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        private static extern IntPtr OpenJobObject(uint access, bool inherit, string name);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool inside);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref CompletionPort info, uint length);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern IntPtr CreateIoCompletionPort(IntPtr file, IntPtr existing, IntPtr key, uint concurrency);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetQueuedCompletionStatus(IntPtr port, out uint message, out IntPtr key, out IntPtr value, uint milliseconds);
        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        public ProcessJob() : this(null) { }
        public ProcessJob(string name) {
            job = CreateJobObject(IntPtr.Zero, name);
            if (job == IntPtr.Zero) throw new Win32Exception();
            if (name != null && Marshal.GetLastWin32Error() == 183) {
                Dispose();
                throw new InvalidOperationException("Run job already exists");
            }
            try {
                port = CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, IntPtr.Zero, 1);
                if (port == IntPtr.Zero) throw new Win32Exception();
                var association = new CompletionPort { Key = new IntPtr(1), Port = port };
                if (!SetInformationJobObject(job, 7, ref association, (uint)Marshal.SizeOf(association))) throw new Win32Exception();
            } catch { Dispose(); throw; }
        }

        private ProcessJob(IntPtr handle) { job = handle; }
        // A missing name is not proof of exit: last-handle closure can remove the name.
        // Access denied or any other error is uncertainty, never an empty group.
        public static ProcessJob Open(string name) { return Open(name, 0x4); }
        public static ProcessJob OpenForCancellation(string name) { return Open(name, 0xC); }
        private static ProcessJob Open(string name, uint access) {
            IntPtr handle = OpenJobObject(access, false, name); // QUERY; cancellation additionally requires TERMINATE
            if (handle != IntPtr.Zero) return new ProcessJob(handle);
            int error = Marshal.GetLastWin32Error();
            if (error == 2) return null;
            throw new Win32Exception(error);
        }

        // Attach the supervisor BEFORE Process.Start. Its children inherit the job at creation,
        // including children of launchers that exit between notifications. No suspended-process race.
        public void BindCurrentProcess() {
            if (!AssignProcessToJobObject(job, GetCurrentProcess())) throw new Win32Exception();
        }
        public bool Contains(IntPtr process) {
            bool inside;
            if (!IsProcessInJob(process, job, out inside)) throw new Win32Exception();
            return inside;
        }
        public int[] ProcessIds() {
            int capacity = 16;
            while (true) {
                int size = checked(8 + capacity * IntPtr.Size);
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try {
                    if (!QueryInformationJobObject(job, 3, buffer, (uint)size, IntPtr.Zero)) {
                        int error = Marshal.GetLastWin32Error();
                        if (error != 234) throw new Win32Exception(error);
                        capacity = checked(capacity * 2);
                        continue;
                    }
                    int count = Marshal.ReadInt32(buffer, 4);
                    var ids = new int[count];
                    for (int i = 0; i < count; i++) ids[i] = checked((int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size).ToInt64());
                    return ids;
                } finally { Marshal.FreeHGlobal(buffer); }
            }
        }
        // Explicit cancellation only. A graceful close never falls through here.
        public void Cancel() {
            if (Contains(GetCurrentProcess())) throw new InvalidOperationException("Cancellation caller belongs to the target job");
            if (!TerminateJobObject(job, 1223)) throw new Win32Exception();
            while (ProcessIds().Length != 0) WaitForChange(100);
        }
        // Notifications wake observation promptly; the kernel membership query is authoritative.
        // Completion notifications alone are not guaranteed to cover every process transition.
        public void WaitForChange(uint milliseconds) {
            // Completion port belongs to the original observer. A reopened job uses
            // bounded kernel observation; it does not impose a run deadline.
            if (port == IntPtr.Zero) { System.Threading.Thread.Sleep(checked((int)milliseconds)); return; }
            uint message; IntPtr key, value;
            if (!GetQueuedCompletionStatus(port, out message, out key, out value, milliseconds)) {
                int error = Marshal.GetLastWin32Error();
                if (error != 258) throw new Win32Exception(error);
            }
        }
        public void Dispose() {
            if (port != IntPtr.Zero) { CloseHandle(port); port = IntPtr.Zero; }
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
        }
    }
    // Packaged hosts may virtualize LocalAppData. Hand the independent observer a physical
    // storage reference; never make it search different folders or copy saved run state.
    public static class RunStore {
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        private static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        private static extern uint GetFinalPathNameByHandle(IntPtr handle, System.Text.StringBuilder path, uint length, uint flags);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
        public static string Resolve(string directory) {
            IntPtr handle = CreateFile(directory, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
            if (handle == new IntPtr(-1)) throw new Win32Exception();
            try {
                var path = new System.Text.StringBuilder(32768);
                uint length = GetFinalPathNameByHandle(handle, path, (uint)path.Capacity, 0);
                if (length == 0) throw new Win32Exception();
                if (length >= path.Capacity) throw new InvalidOperationException("Run store path too long");
                string value = path.ToString();
                if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Run store must be local");
                return value.StartsWith(@"\\?\", StringComparison.Ordinal) ? value.Substring(4) : value;
            } finally { CloseHandle(handle); }
        }
    }

}
