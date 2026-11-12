using System;
using System.IO;
using System.Threading;

namespace VanessaRunner {
    // Buffered notification: a replacement between reading and waiting cannot
    // be lost. The receipt remains the evidence; this signal only wakes reading.
    public sealed class ObservationChanges : IDisposable {
        private readonly AutoResetEvent changed = new AutoResetEvent(false);
        private readonly FileSystemWatcher watcher;
        private readonly object gate = new object();
        private bool disposed;

        public ObservationChanges(string directory) {
            watcher = new FileSystemWatcher(directory, "state.json");
            watcher.Changed += Signal;
            watcher.Created += Signal;
            watcher.Deleted += Signal;
            watcher.Renamed += Signal;
            watcher.EnableRaisingEvents = true;
        }
        private void Signal(object sender, FileSystemEventArgs args) {
            lock (gate) { if (!disposed) changed.Set(); }
        }
        public void Wait() { changed.WaitOne(); }
        public void Dispose() {
            lock (gate) { disposed = true; }
            watcher.Dispose();
            changed.Dispose();
        }
    }
}
