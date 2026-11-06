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

    /// Jumps to a window that may be on another Space: the private focus
    /// call, then a raise of the window's element, which is what makes the
    /// Space follow. Making the app frontmost through Accessibility switches
    /// sooner, but the app then brings its other windows forward too, and a
    /// switch to one of those on another Space can win [F41]. `failed` runs on
    /// the main thread if the window cannot be reached.
    static func jump(pid: pid_t, window id: CGWindowID, failed: @escaping () -> Void) {
        queue.async {
            guard let element = RemoteAX.window(pid: pid, id: id),
                  SkyLight.focus(pid: pid, window: id),
                  AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
            else {
                DispatchQueue.main.async(execute: failed)
                return
            }
        }
    }
}
