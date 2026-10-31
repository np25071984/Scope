// Most-recently-used order, kept by hand.
//
// Every window that gains focus is stamped with the time. The sources are an
// Accessibility observer per app for focused-window changes -- which fires for
// any window, including a native tab the app just swapped in -- and app
// activation and deactivation from NSWorkspace. Deactivation counts as use
// because a tab switched to by keyboard fires nothing scope hears, yet it is
// still the one the app names as focused on the way out, and every Space
// switch deactivates something.
//
// All of it runs on a thread of its own. An app that is slow to answer holds
// up the stamp for that app, never the key tap or the overlay.

import AppKit
import ApplicationServices

final class Recency {
    private let thread = RunLoopThread(name: "scope.recency")
    private let lock = NSLock()
    private var table = StampTable()  // guarded by lock
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
        table.remove(pid: pid)
        lock.unlock()
    }

    private func stampFocused(of pid: pid_t, why: String) {
        guard let window = AX.focusedWindow(of: pid), let id = AX.windowID(window) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let frame = AX.frame(window), space = SkyLight.activeSpace()

        lock.lock()
        table.record(id, at: now, pid: pid, frame: frame, space: space)
        lock.unlock()
        Log.trace("\(why): stamped window \(id) of pid \(pid)")
    }

    // MARK: Any thread

    /// Time the window was last used, or nil if scope has not seen it used.
    func lastUsed(_ id: CGWindowID, before cutoff: TimeInterval = .infinity) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return table.lastUsed(id, before: cutoff)
    }

    /// `windows` most recently used first; see `StampTable.rank`.
    func rank(_ windows: [Window], before cutoff: TimeInterval = .infinity) -> [Window] {
        lock.lock()
        let table = self.table
        lock.unlock()
        return table.rank(windows, space: SkyLight.activeSpace(), before: cutoff)
    }
}
