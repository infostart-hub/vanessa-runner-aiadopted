using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace VanessaRunner {
    // Read the native listening endpoint; opening a window alone is not TestClient readiness.
    public static class TestClientEndpoint {
        [DllImport("iphlpapi.dll")] private static extern uint GetExtendedTcpTable(
            IntPtr table, ref uint size, bool ordered, uint family, uint tableClass, uint reserved);

        private static bool Read(int process, int port, uint family, int stride, int portOffset, int pidOffset) {
            uint size = 0;
            uint error = GetExtendedTcpTable(IntPtr.Zero, ref size, false, family, 3, 0);
            if (error != 122) throw new Win32Exception((int)error);
            while (true) {
                var table = Marshal.AllocHGlobal((int)size);
                try {
                    error = GetExtendedTcpTable(table, ref size, false, family, 3, 0);
                    if (error == 122) continue; // The kernel table grew between size and read.
                    if (error != 0) throw new Win32Exception((int)error);
                    int count = Marshal.ReadInt32(table);
                    for (int i = 0; i < count; i++) {
                        var row = IntPtr.Add(table, 4 + i * stride);
                        uint networkPort = unchecked((uint)Marshal.ReadInt32(row, portOffset));
                        int localPort = (int)(((networkPort & 0xff) << 8) | ((networkPort >> 8) & 0xff));
                        if (localPort == port && Marshal.ReadInt32(row, pidOffset) == process) return true;
                    }
                    return false;
                } finally { Marshal.FreeHGlobal(table); }
            }
        }

        public static bool OwnedListener(int process, int port) {
            if (process <= 0 || port < 1 || port > 65535) throw new ArgumentOutOfRangeException();
            return Read(process, port, 2, 24, 8, 20) || Read(process, port, 23, 56, 20, 52);
        }
    }
}
