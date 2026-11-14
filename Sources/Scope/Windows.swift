// The current Space's windows, read fresh on every open.
//
// Which windows are on this Space comes from the window server: CGWindowList
// with onScreenOnly lists exactly the windows ordered in on the Spaces that
// are showing, frontmost first, and it is public API. Which of them are real
// windows, and what they are called, comes from Accessibility. The two are
// joined on the window-server id.
//
// Native tabs are why it works this way. A tab that is swapped out is not on
// screen, so it never makes the list; the tab that is up always does, under
// its own title. There is no cache of windows to go stale when an app swaps
// one tab for another without telling anyone.

import AppKit
import ApplicationServices

struct Window: Rankable {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let title: String
    /// Global coordinates, top-left origin, as CGWindowList and AX report them.
    let frame: CGRect
    /// Position in the window server's stacking order; 0 is frontmost.
    let z: Int
}

enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String, as _: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let position = value, CFGetTypeID(position) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let extent = value, CFGetTypeID(extent) == AXValueGetTypeID(),
              AXValueGetValue(extent as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let value = attribute(app, kAXFocusedWindowAttribute, as: CFTypeRef.self),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// The focused window of the frontmost app: a live query, never a cache.
    static func focusedWindowID() -> CGWindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window = focusedWindow(of: pid)
        else { return nil }
        return windowID(window)
    }
}

extension WindowLister {
    /// The ids of the ordinary windows on screen now, on any Space showing.
    static func onScreenIDs() -> [CGWindowID] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return info.compactMap { w in
            (w[kCGWindowLayer as String] as? Int) == 0 ? (w[kCGWindowNumber as String] as? CGWindowID) : nil
        }
    }
}

final class WindowLister {
    // How long one app may take to answer before scope stops waiting for it.
    // Set globally, through the system-wide element, so it bounds every
    // Accessibility call scope makes. A busy emulator or IDE is what this is
    // for: it costs that app's rows their fresh titles, not the whole switcher.
    static let messagingTimeout: Float = 0.25

    static func configureTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    private struct Known {
        let element: AXUIElement
        let title: String
        let listed: Bool
    }

    // The last answer for every window an app has described, used in place of
    // a fresh one when the app does not answer in time.
    private var known: [CGWindowID: Known] = [:]

    private struct OnScreen {
        let id: CGWindowID
        let pid: pid_t
        let frame: CGRect
        let z: Int
    }

    /// Whether the window is ordered in on a Space that is showing [F6].
    static func isOnScreen(_ id: CGWindowID) -> Bool {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let entry = info.first
        else { return false }
        return entry[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    private func onScreen() -> [OnScreen] {
        let own = getpid()
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var result: [OnScreen] = []
        for entry in info {
            // Layer 0 is where document windows live; menus, the Dock, panels
            // that float above everything and the menu bar are all higher.
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            result.append(OnScreen(id: id, pid: pid, frame: frame, z: result.count))
        }
        return result
    }

    /// What one app says about its windows, or nil if it did not answer.
    private static func describe(pid: pid_t, wanted: Set<CGWindowID>) -> [CGWindowID: Known]? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }

        var result: [CGWindowID: Known] = [:]
        let attributes = [kAXSubroleAttribute, kAXTitleAttribute, kAXModalAttribute] as CFArray
        for window in windows {
            guard let id = AX.windowID(window), wanted.contains(id) else { continue }
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(
                window, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                let triple = values as? [Any], triple.count == 3
            else { continue }

            // A window without the modal attribute is not modal.
            result[id] = Known(
                element: window,
                title: triple[1] as? String ?? "",
                listed: Switcher.isListed(subrole: triple[0] as? String, modal: triple[2] as? Bool ?? false))
        }
        return result
    }

    /// The listed windows on the Spaces now showing, frontmost first.
    func currentSpace() -> [Window] {
        let screen = onScreen()
        let pids = Array(Set(screen.map(\.pid)))
        var wantedByPid: [pid_t: Set<CGWindowID>] = [:]
        for w in screen { wantedByPid[w.pid, default: []].insert(w.id) }

        // Apps are asked in parallel, so the open costs the slowest app's
        // answer rather than the sum of them all.
        let lock = NSLock()
        var answers: [pid_t: [CGWindowID: Known]] = [:]
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let pid = pids[i]
            guard let described = Self.describe(pid: pid, wanted: wantedByPid[pid] ?? []) else {
                Log.trace("pid \(pid) did not answer; using its last known windows")
                return
            }
            lock.lock()
            answers[pid] = described
            lock.unlock()
        }

        var result: [Window] = []
        for w in screen {
            let entry: Known?
            if let fresh = answers[w.pid] {
                entry = fresh[w.id]
                known[w.id] = entry
            } else {
                entry = known[w.id]
            }
            guard let entry, entry.listed else { continue }
            result.append(Window(
                id: w.id, pid: w.pid, element: entry.element,
                title: entry.title, frame: w.frame, z: w.z))
        }

        // Only windows still on screen are worth remembering; one that comes
        // back from another Space is asked about again then.
        if known.count > 512 {
            let live = Set(screen.map(\.id))
            known = known.filter { live.contains($0.key) }
        }
        return result
    }
}
