using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace VanessaRunner {
    // Read-only WCT diagnostics. Never enables privileges or controls a thread.
    public static class WaitDiagnostics {
        [DllImport("advapi32.dll", SetLastError=true)]
        private static extern IntPtr OpenThreadWaitChainSession(uint flags, IntPtr callback);
        [DllImport("advapi32.dll")]
        private static extern void CloseThreadWaitChainSession(IntPtr session);
        [DllImport("advapi32.dll", SetLastError=true)]
        private static extern bool GetThreadWaitChain(IntPtr session, IntPtr context, uint flags,
            uint thread, ref uint count, IntPtr nodes, out bool cycle);

        public static string[] Read(Process process) {
            var result = new List<string>();
            var session = OpenThreadWaitChainSession(0, IntPtr.Zero);
            if (session == IntPtr.Zero) return new [] { "WCT unavailable: " + Marshal.GetLastWin32Error() };
            // wct.h: 16 nodes, 280-byte WAITCHAIN_NODE_INFO, union starts at byte 8.
            var buffer = Marshal.AllocHGlobal(16 * 280);
            try {
                foreach (ProcessThread thread in process.Threads) {
                    uint count = 16; bool cycle;
                    if (!GetThreadWaitChain(session, IntPtr.Zero, 0, (uint)thread.Id, ref count, buffer, out cycle)) {
                        result.Add("thread=" + thread.Id + " WCT error=" + Marshal.GetLastWin32Error());
                        continue;
                    }
                    var nodes = new List<string>();
                    for (int i = 0; i < Math.Min(count, 16); i++) {
                        var node = IntPtr.Add(buffer, i * 280);
                        int kind = Marshal.ReadInt32(node), status = Marshal.ReadInt32(node, 4);
                        string value = kind == 8
                            ? "pid=" + Marshal.ReadInt32(node, 8) + ",tid=" + Marshal.ReadInt32(node, 12)
                            : "object=" + Marshal.PtrToStringUni(IntPtr.Add(node, 8), 128).TrimEnd('\0');
                        nodes.Add("type=" + kind + ",status=" + status + "," + value);
                    }
                    result.Add("thread=" + thread.Id + " cycle=" + cycle + ": " + String.Join(" -> ", nodes));
                }
            } finally { Marshal.FreeHGlobal(buffer); CloseThreadWaitChainSession(session); }
            return result.ToArray();
        }
    }
}
