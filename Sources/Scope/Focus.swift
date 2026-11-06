// Bringing one window forward without dragging every other window of its app
// along, which is what activating the app would do.

import AppKit
import ApplicationServices

enum Focus {
    private static let queue = DispatchQueue(label: "scope.focus", qos: .userInteractive)

    /// Off the main thread: the target app may be the slow one, and the
    /// overlay should be gone the moment the choice is made.
    static func window(_ window: Window) {
        queue.async {
            let focused = SkyLight.focus(pid: window.pid, window: window.id)
            if !focused {
                Log.trace("private focus unavailable; activating pid \(window.pid)")
                AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
                DispatchQueue.main.async {
                    NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
                }
            }
            // Raise last: SetFrontProcess orders the app forward but leaves the
            // window wherever it was among the app's own windows.
            AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        }
    }
}
