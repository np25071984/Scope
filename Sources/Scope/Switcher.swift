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
    private var refocusState = Refocus()
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
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.activated(app?.processIdentifier)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let pid = app?.processIdentifier { self?.icons[pid] = nil }
        }
        return true
    }

    func configure(modifier: CGEventFlags, mouse: Bool) {
        tap.configure(modifier: modifier, mouse: mouse)
    }

    // MARK: The list

    /// The current Space's windows, most recently used first.
    ///
    /// The focused window goes first whatever the stamps say. Its stamp can be
    /// a moment behind -- a second press straight after the first is exactly
    /// when -- and then the slot the switcher skips as "where I already am"
    /// would be the one it was supposed to land on.
    func currentWindows() -> [Window] {
        Self.focusedFirst(recency.rank(lister.currentSpace()), focused: AX.focusedWindowID())
    }

    static func focusedFirst<W: Rankable>(_ ranked: [W], focused: CGWindowID?) -> [W] {
        guard let focused, let i = ranked.firstIndex(where: { $0.id == focused }), i > 0 else { return ranked }
        var result = ranked
        result.insert(result.remove(at: i), at: 0)
        return result
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
        index = Self.firstSelection(delta: delta, count: windows.count)

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
        select(Self.stepped(index, by: delta, count: windows.count))
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

    /// Forward selects the second row, so a quick press and release toggles
    /// between the two most recent windows; backward selects the last.
    static func firstSelection(delta: Int, count: Int) -> Int {
        delta > 0 ? 1 : count - 1
    }

    /// Steps wrap around in both directions.
    static func stepped(_ index: Int, by delta: Int, count: Int) -> Int {
        ((index + delta) % count + count) % count
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
    // The decision is `Refocus`; this is its timer and its side effects.

    private func activated(_ pid: pid_t?) {
        refocusState.activated(pid, at: ProcessInfo.processInfo.systemUptime)
    }

    private func spaceChanged() {
        guard refocusEnabled else { return }
        refocusState.spaceChanged(at: ProcessInfo.processInfo.systemUptime)
        refocusTimer?.invalidate()
        refocusTimer = Timer.scheduledTimer(withTimeInterval: Refocus.settle, repeats: false) { [weak self] _ in
            self?.refocus()
        }
    }

    private func refocus() {
        refocusTimer = nil
        guard !overlay.isVisible else { return }

        let cutoff = refocusState.cutoff
        let here = recency.rank(lister.currentSpace(), before: cutoff)
        let outcome = refocusState.decide(
            here, focused: AX.focusedWindowID(),
            frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            seenUsed: { [recency] in recency.lastUsed($0.id, before: cutoff) != nil })

        switch outcome {
        case .leave(let reason):
            Log.trace("refocus: left alone (\(reason))")
        case .focus(let id):
            guard let target = here.first(where: { $0.id == id }) else { return }
            Log.trace("refocus: \(target.id) \"\(target.title)\"")
            refocusState.refocusing(target.pid, at: ProcessInfo.processInfo.systemUptime)
            Focus.window(target)
        }
    }
}

/// Whether to move focus after a Space switch, and where. Pure: the caller
/// supplies the clock, the ranked windows and the live focus.
///
/// Switching Spaces does not reliably move the keyboard with you: the app
/// active on the Space you left stays active when it has nothing here, so you
/// arrive with your last window in front but not focused. If nothing on the
/// new Space has focus once the switch settles, the window you used last here
/// gets it. A window that already has focus is left alone, because a Space
/// change is as often the result of choosing one -- unless it belongs to the
/// frontmost app and no app was activated around the switch. That is macOS
/// carrying the active app over to its window here, not a choice: choosing a
/// window, from the Dock, a notification or Mission Control, activates its
/// app. scope's own refocus activates one too, and a quick switch back must
/// not take that for a choice.
///
/// The arrival itself stamps the carried-over window as used, so the decision
/// ranks by use before the switch. The margin covers the animation, which runs
/// before the notification is posted, and the stamps it fires.
struct Refocus {
    /// Wait this long after the Space-change notification.
    static let settle: TimeInterval = 0.3
    /// Rank by use from this long before the notification.
    static let switchMargin: TimeInterval = 1
    /// An activation of the app scope just refocused, within this long, is
    /// scope's own doing.
    static let ownActivation: TimeInterval = 0.5

    enum Reason: Equatable {
        case chosen           // focus is on a window that was picked
        case alreadyThere     // the window used last already has focus
        case neverUsed        // no window here has been seen used before the switch
    }

    enum Outcome: Equatable {
        case leave(Reason)
        case focus(CGWindowID)
    }

    private(set) var spaceChangedAt: TimeInterval = 0
    private(set) var lastActivation: TimeInterval = 0
    private(set) var refocused: (pid: pid_t, at: TimeInterval)?

    var cutoff: TimeInterval { spaceChangedAt - Self.switchMargin }

    mutating func activated(_ pid: pid_t?, at now: TimeInterval) {
        if let refocused, refocused.pid == pid, now - refocused.at < Self.ownActivation { return }
        lastActivation = now
    }

    mutating func spaceChanged(at now: TimeInterval) {
        spaceChangedAt = now
    }

    mutating func refocusing(_ pid: pid_t, at now: TimeInterval) {
        refocused = (pid, now)
    }

    /// `here`: this Space's windows ranked by use before `cutoff`. `focused`:
    /// the live focused window. `seenUsed`: whether a window has a stamp
    /// before `cutoff`.
    func decide<W: Rankable>(
        _ here: [W], focused: CGWindowID?, frontmost: pid_t?, seenUsed: (W) -> Bool
    ) -> Outcome {
        if let focused, let window = here.first(where: { $0.id == focused }) {
            let carried = lastActivation < cutoff && window.pid == frontmost
            if !carried { return .leave(.chosen) }
            if here.first?.id == focused { return .leave(.alreadyThere) }
        }
        // Only a window scope has seen used. The order among windows it has
        // not is stacking order, not a record of use; macOS's own choice, or
        // none, is better than a guess.
        guard let target = here.first, seenUsed(target) else { return .leave(.neverUsed) }
        return .focus(target.id)
    }
}
