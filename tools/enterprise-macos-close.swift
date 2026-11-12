import AppKit
import Foundation
// The observer supplies only members of its own still-live process group.
for argument in CommandLine.arguments.dropFirst() {
    guard let pid = Int32(argument), let application = NSRunningApplication(processIdentifier: pid) else { continue }
    let accepted = application.terminate()
    print("\(pid): terminate requested=\(accepted)")
}
