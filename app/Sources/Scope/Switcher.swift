// The switcher itself: what ⌘Tab opens, steps through and commits. Main thread.

import AppKit

final class Switcher {
    private let lister = WindowLister()
    private let recency = Recency()
    private let overlay = Overlay()
    private lazy var tap = KeyTap { [weak self] in self?.perform($0) }

    private var windows: [Window] = []
    private var session = 0
    private var index = 0
    private var watchdog: Timer?
    private var refocusTimer: Timer?
    private var icons: [pid_t: NSImage] = [:]

    var refocusEnabled = true

    func start() -> Bool {
        WindowLister.configureTimeout()
        guard tap.start() else { return false }
        recency.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.spaceChanged() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let pid = app?.processIdentifier { self?.icons[pid] = nil }
        }
        return true
    }

    func configure(modifier: CGEventFlags, mouse: Bool, enabled: Bool) {
        tap.configure(modifier: modifier, mouse: mouse, enabled: enabled)
        if !enabled { cancel() }
    }

    // MARK: The list

    /// The current Space's windows, most recently used first.
    ///
    /// The focused window goes first whatever the stamps say. Its stamp can be
    /// a moment behind -- a second press straight after the first is exactly
    /// when -- and then the slot the switcher skips as "where I already am"
    /// would be the one it was supposed to land on.
    func currentWindows() -> [Window] {
        var ranked = recency.rank(lister.currentSpace())
        if let focused = AX.focusedWindowID(),
           let i = ranked.firstIndex(where: { $0.id == focused }), i > 0
        {
            ranked.insert(ranked.remove(at: i), at: 0)
        }
        return ranked
    }

    func lastUsed(_ window: Window) -> TimeInterval? {
        recency.lastUsed(window.id)
    }

    // MARK: Actions

    private func perform(_ action: KeyTap.Action) {
        switch action {
        case .show(let delta, let session): show(delta, session)
        case .step(let delta): step(delta)
        case .select(let row): select(row)
        case .commit: commit()
        case .pick(let row): select(row); commit()
        case .cancel: cancel()
        }
    }

    private func show(_ delta: Int, _ session: Int) {
        if overlay.isVisible { step(delta); return }
        self.session = session

        let t0 = DispatchTime.now()
        windows = currentWindows()
        Log.trace(String(
            format: "show: %d windows in %.1fms", windows.count,
            Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6))
        for (i, w) in windows.enumerated() {
            Log.trace("  \(i + 1). \(w.id) pid \(w.pid) \"\(w.title)\"")
        }

        guard windows.count >= 2 else {
            tap.closed(session: session)
            windows = []
            return
        }

        // Start on the next window, so a quick press and release toggles
        // between the two most recent, the way ⌘Tab does.
        index = delta > 0 ? 1 : windows.count - 1

        let rows = windows.map { w in
            let app = NSRunningApplication(processIdentifier: w.pid)
            return Overlay.Row(
                title: w.title.isEmpty ? "(untitled)" : w.title,
                app: app?.localizedName ?? "",
                icon: icon(for: w.pid, app))
        }
        let frame = overlay.show(rows, selected: index, on: screen(for: windows[0]))
        tap.shown(KeyTap.Geometry(
            frame: frame, padding: Overlay.padding,
            rowHeight: Overlay.rowHeight, rows: rows.count), session: session)
        armWatchdog()
    }

    private func step(_ delta: Int) {
        guard overlay.isVisible, !windows.isEmpty else { return }
        select(((index + delta) % windows.count + windows.count) % windows.count)
    }

    private func select(_ row: Int) {
        guard overlay.isVisible, windows.indices.contains(row), row != index else { return }
        index = row
        overlay.select(row)
        armWatchdog()
    }

    private func commit() {
        guard overlay.isVisible, windows.indices.contains(index) else { return }
        let target = windows[index]
        Log.trace("commit \(index + 1): \(target.id) \"\(target.title)\"")
        teardown()
        Focus.window(target)
    }

    func cancel() {
        guard overlay.isVisible else { return }
        teardown()
    }

    private func teardown() {
        watchdog?.invalidate()
        watchdog = nil
        overlay.hide()
        windows = []
        tap.closed(session: session)
    }

    // Safety net, rearmed on every interaction. If the modifier release is
    // ever missed the overlay would sit there holding Tab and Escape forever.
    private func armWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Log.warn("switcher watchdog fired; tearing down")
            self?.cancel()
        }
    }

    private func icon(for pid: pid_t, _ app: NSRunningApplication?) -> NSImage? {
        if let cached = icons[pid] { return cached }
        let icon = app?.icon
        icons[pid] = icon
        return icon
    }

    /// The screen the window you are on is on, where your eyes already are.
    private func screen(for window: Window) -> NSScreen {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: window.frame.midX, y: primary - window.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Keeping focus on the Space you arrive in
    //
    // Switching Spaces does not reliably move the keyboard with you: the app
    // active on the Space you left stays active when it has nothing here, so
    // you arrive with your last window in front but not focused. If nothing on
    // the new Space has focus once the switch settles, the window you used last
    // here gets it. A window that already has focus is left alone, because a
    // Space change is as often the result of choosing one.

    private func spaceChanged() {
        guard refocusEnabled else { return }
        refocusTimer?.invalidate()
        refocusTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.refocus()
        }
    }

    private func refocus() {
        refocusTimer = nil
        guard !overlay.isVisible else { return }

        let here = currentWindows()
        if let focused = AX.focusedWindowID(), here.contains(where: { $0.id == focused }) {
            Log.trace("refocus: window \(focused) already focused")
            return
        }
        // Only a window scope has seen used. The order among windows it has
        // not is stacking order, not a record of use; macOS's own choice, or
        // none, is better than a guess.
        guard let target = here.first, recency.lastUsed(target.id) != nil else {
            Log.trace("refocus: nothing used on this Space since launch; left alone")
            return
        }
        Log.trace("refocus: \(target.id) \"\(target.title)\"")
        Focus.window(target)
    }
}
