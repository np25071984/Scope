// Most-recently-used order, kept by hand.
//
// Every window that gains focus is stamped with the time. The sources are an
// Accessibility observer per app for focused-window changes -- which, unlike
// hs.window.filter, fires for any window including a native tab the app just
// swapped in -- and app activation and deactivation from NSWorkspace.
// Deactivation counts as use for the same reason it did in the Lua version:
// a tab switched to by keyboard and then left is still the one the app names
// as focused on the way out, and every Space switch deactivates something.
//
// All of it runs on a thread of its own. An app that is slow to answer holds
// up the stamp for that app, never the key tap or the overlay.

import AppKit
import ApplicationServices

final class Recency {
    /// How far back `rank(_:before:)` and `lastUsed(_:before:)` can look past
    /// a window's latest stamp: each stamp keeps the newest use at least this
    /// much older than itself.
    static let history: TimeInterval = 1

    private struct Stamp {
        let at: TimeInterval
        let previous: TimeInterval?
        let pid: pid_t
        let frame: CGRect?
        let space: UInt64?

        /// This stamp as it stood at `cutoff`, or nil if the window had not
        /// been used by then as far as the stamp remembers.
        func before(_ cutoff: TimeInterval) -> Stamp? {
            if at < cutoff { return self }
            guard let previous, previous < cutoff else { return nil }
            return Stamp(at: previous, previous: nil, pid: pid, frame: frame, space: space)
        }
    }

    private let thread = RunLoopThread(name: "scope.recency")
    private let lock = NSLock()
    private var stamps: [CGWindowID: Stamp] = [:]  // guarded by lock
    private var observers: [pid_t: AXObserver] = [:]  // recency thread only
    private var tokens: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ handle: @escaping (Recency, pid_t) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                let pid = app.processIdentifier
                self.thread.async { handle(self, pid) }
            })
        }
        on(NSWorkspace.didActivateApplicationNotification) { $0.stampFocused(of: $1, why: "activated") }
        on(NSWorkspace.didDeactivateApplicationNotification) { $0.stampFocused(of: $1, why: "deactivated") }
        on(NSWorkspace.didLaunchApplicationNotification) { $0.observe($1, attempt: 0) }
        on(NSWorkspace.didTerminateApplicationNotification) { $0.unobserve($1) }

        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .map(\.processIdentifier)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        thread.async { [self] in
            for pid in pids { observe(pid, attempt: 0) }
            if let front { stampFocused(of: front, why: "startup") }
        }
    }

    // MARK: Recency thread

    private func observe(_ pid: pid_t, attempt: Int) {
        guard observers[pid] == nil, pid != getpid() else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<Recency>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return }
            me.stampFocused(of: pid, why: "focus changed")
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(
            observer, app, kAXFocusedWindowChangedNotification as CFString, refcon)

        // An app that has only just launched often cannot take an observer
        // yet. Give it a few seconds to finish starting up.
        guard result == .success || result == .notificationAlreadyRegistered else {
            if attempt < 5 {
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                    thread.async { self.observe(pid, attempt: attempt + 1) }
                }
            }
            return
        }
        thread.add(AXObserverGetRunLoopSource(observer))
        observers[pid] = observer
    }

    private func unobserve(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            thread.remove(AXObserverGetRunLoopSource(observer))
        }
        lock.lock()
        stamps = stamps.filter { $0.value.pid != pid }
        lock.unlock()
    }

    private func stampFocused(of pid: pid_t, why: String) {
        guard let window = AX.focusedWindow(of: pid), let id = AX.windowID(window) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let frame = AX.frame(window), space = SkyLight.activeSpace()

        lock.lock()
        // A window is stamped several times in a burst -- activated, focus
        // changed, deactivated -- so the use kept behind the latest is the
        // newest one from before the burst, not simply the one replaced.
        let previous = stamps[id].flatMap { now - $0.at >= Self.history ? $0.at : $0.previous }
        stamps[id] = Stamp(at: now, previous: previous, pid: pid, frame: frame, space: space)
        if stamps.count > 1024 {
            // Oldest first; a window untouched that long ranks by z-order
            // just as well.
            let keep = stamps.sorted { $0.value.at > $1.value.at }.prefix(512)
            stamps = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        lock.unlock()
        Log.trace("\(why): stamped window \(id) of pid \(pid)")
    }

    // MARK: Any thread

    /// Time the window was last used, or nil if scope has not seen it used.
    func lastUsed(_ id: CGWindowID, before cutoff: TimeInterval = .infinity) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return stamps[id]?.before(cutoff)?.at
    }

    /// `windows` most recently used first. Windows scope has never seen used
    /// were last used before it started, so they go below every stamped one,
    /// in stacking order, which is the window server's own record of use.
    ///
    /// A row ranks by the newest use across its tab group: any stamped window
    /// of the same app, on the same Space when it was stamped, that is now
    /// off screen and had the row's frame. That covers a tab used and then
    /// switched away from by keyboard, and a tab that was closed -- both rank
    /// the row that took their place. The Space matters because maximized
    /// windows of one app on two Spaces share a frame too.
    ///
    /// With a `cutoff`, windows rank by their use before it, to look past an
    /// event that itself stamped windows, such as a Space switch.
    func rank(_ windows: [Window], before cutoff: TimeInterval = .infinity) -> [Window] {
        lock.lock()
        let stamps = self.stamps.compactMapValues { $0.before(cutoff) }
        lock.unlock()

        let onScreen = Set(windows.map(\.id))
        let space = SkyLight.activeSpace()

        func usedAt(_ w: Window) -> TimeInterval? {
            var best = stamps[w.id]?.at
            guard let space else { return best }
            for (id, s) in stamps where id != w.id && !onScreen.contains(id)
                && s.pid == w.pid && s.space == space && s.at > (best ?? 0)
            {
                if let f = s.frame, sameFrame(f, w.frame) {
                    Log.trace("tab group: window \(w.id) ranked by \(id)")
                    best = s.at
                }
            }
            return best
        }

        return windows.map { ($0, usedAt($0)) }
            .sorted { a, b in
                switch (a.1, b.1) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.0.z < b.0.z
                }
            }
            .map(\.0)
    }

    private func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
            && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}
