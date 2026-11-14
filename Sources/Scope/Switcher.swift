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
    /// A Space shortcut waiting for a switch already under way to finish.
    private var pendingJump: (number: Int, code: Int64, flags: CGEventFlags)?
    private var jumpTimer: Timer?
    /// A swipe scope posted, until it lands: where to, the window to focus
    /// there, and the Spaces it passes on the way.
    private var arriving: (space: UInt64, window: CGWindowID?, passing: Set<UInt64>)?
    /// A timed slide's last step, posted on arriving at `from` [F48].
    private var lastStep: (from: UInt64, direction: SwipeDirection, fling: Double)?
    /// Which way the slide now running goes, when scope knows: a swipe was
    /// seen ending, or scope started it. Cleared once it lands.
    private var slideDirection: SwipeDirection?
    private var refocusState = Refocus()
    private var icons: [pid_t: NSImage] = [:]

    var refocusEnabled = true
    /// How ⌃N switches look: macOS's slide, or scope's swipe of a set length.
    var slide = Slide.macos

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

    func configure(modifier: CGEventFlags, mouse: Bool, spaceKeys: [SpaceShortcut]) {
        tap.configure(modifier: modifier, mouse: mouse, spaceKeys: spaceKeys)
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

    /// Whether a window with this Accessibility subrole belongs in the list [F8].
    ///
    /// Standard windows do. So do dialogs that are not modal: a settings
    /// window such as Xcode's is one, and it is worked in like any other. A
    /// modal dialog is an alert waiting for an answer, and the invisible
    /// helper windows some apps park in every Space have other subroles.
    static func isListed(subrole: String?, modal: Bool) -> Bool {
        switch subrole {
        case kAXStandardWindowSubrole as String: true
        case kAXDialogSubrole as String: !modal
        default: false
        }
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
        case .space(let number, let code, let flags): jump(to: number, code: code, flags: flags)
        case .swiped(let value): slideDirection = Swipe.direction(of: value)
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

    // MARK: Jumping to a Space

    /// ⌃N: plan it once no slide is in the way, then carry the plan out. A
    /// later press replaces one still waiting.
    private func jump(to number: Int, code: Int64, flags: CGEventFlags) {
        pendingJump = (number, code, flags)
        guard jumpTimer == nil else { return }
        let started = ProcessInfo.processInfo.systemUptime
        func check() -> Bool {
            guard let pending = pendingJump else { return true }
            let waited = ProcessInfo.processInfo.systemUptime - started
            let plan = planJump(pending.number, giveUp: waited >= SpaceJump.settleLimit)
            if plan == .wait { return false }
            pendingJump = nil
            if waited >= SpaceJump.settlePoll { Log.trace("space \(pending.number): after \(Int(waited * 1000))ms of slide") }
            carry(plan, number: pending.number, code: pending.code, flags: pending.flags)
            return true
        }
        if check() { return }
        jumpTimer = Timer.scheduledTimer(withTimeInterval: SpaceJump.settlePoll, repeats: true) { [weak self] timer in
            if check() { timer.invalidate(); self?.jumpTimer = nil }
        }
    }

    private func planJump(_ number: Int, giveUp: Bool) -> SpaceJump.Plan {
        guard !overlay.isVisible, let current = SkyLight.activeSpace() else { return .pass }
        let spaces = SkyLight.displaySpaces(withSpace: current)
        let ids = WindowLister.onScreenIDs()
        let onScreenSpaces = SkyLight.spaces(of: ids)
        let onScreen = ids.map { onScreenSpaces[$0] ?? [] }
        let settled = giveUp || SpaceJump.settled(current: current, spaces: spaces, onScreen: onScreen)
        if settled { slideDirection = nil }
        // The direction scope saw the slide start in, else what is on screen,
        // which can show both neighbours [F47].
        let sliding: SwipeDirection?? =
            settled ? nil : .some(slideDirection ?? SpaceJump.heading(current: current, spaces: spaces, onScreen: onScreen))
        let uses = recency.lastUses()
        let windowSpaces = SkyLight.spaces(of: Array(uses.keys))
        let candidates = uses.map { id, use in
            SpaceJump.Candidate(id: id, pid: use.pid, spaces: windowSpaces[id] ?? [], lastUsed: use.at)
        }
        return SpaceJump.plan(
            number: number, spaces: spaces, desktops: SkyLight.desktops(withSpace: current),
            current: current, sliding: sliding, candidates: candidates)
    }

    private func carry(_ plan: SpaceJump.Plan, number: Int, code: Int64, flags: CGEventFlags) {
        let replay = {
            Log.trace("space \(number): left to macOS")
            KeyTap.replay(code: code, flags: flags)
        }
        switch plan {
        case .wait, .pass:
            replay()
        case .cancel(let direction):
            Log.trace("space \(number): cancelling the slide")
            if !Swipe.post(direction, steps: 1) { replay() }
        case .redirect(let direction, let steps, let space, let window):
            Log.trace("space \(number): mid-slide, \(steps) swipe\(steps == 1 ? "" : "s") \(direction), then window \(window.map(String.init) ?? "none")")
            // The Space being left counts as passed: the slide may be undone first.
            let current = SkyLight.activeSpace() ?? space
            let passing = SpaceJump.between(current, space, in: SkyLight.displaySpaces(withSpace: current))
            arriving = (space, window, passing.union([current]))
            slideDirection = direction
            if steps > 0, !Swipe.post(direction, steps: steps) {
                arriving = nil
                replay()
            }
        case .swipe(let direction, let steps, let space, let window):
            let current = SkyLight.activeSpace() ?? space
            arriving = (space, window, SpaceJump.between(current, space, in: SkyLight.displaySpaces(withSpace: current)))
            slideDirection = direction
            guard case .seconds(let seconds) = self.slide else {
                // macOS's own switch, with its slide; scope still focuses on arrival.
                Log.trace("space \(number): macOS slides there, then window \(window.map(String.init) ?? "none")")
                KeyTap.replay(code: code, flags: flags)
                return
            }
            Log.trace("space \(number): \(steps) swipe\(steps == 1 ? "" : "s") \(direction), the last of \(seconds)s, then window \(window.map(String.init) ?? "none")")
            let fling = SlideSpeed.velocity(seconds: seconds)
            // Several timed swipes at once take about a second whatever their
            // speed, so the steps before the last are instant, and the last
            // waits until the Space before the target is current [F48].
            var ok = true
            if steps > 1, let from = SpaceJump.before(space, going: direction, in: SkyLight.displaySpaces(withSpace: current)) {
                lastStep = (from, direction, fling)
                ok = Swipe.post(direction, steps: steps - 1)
            } else {
                ok = Swipe.post(direction, steps: steps, fling: fling)
            }
            if !ok {
                lastStep = nil
                arriving = nil
                replay()
            }
        }
    }

    /// A Space was arrived at. If it is where scope's swipe was going, focus
    /// the window it planned, and tell the caller to leave refocus out of it;
    /// a Space passed on the way is left alone too. Anything else ends the jump.
    private func landed(on space: UInt64?) -> Bool {
        slideDirection = nil
        defer { if arriving == nil { lastStep = nil } }
        guard let jump = arriving, let space else { return false }
        if let step = lastStep, step.from == space {
            lastStep = nil
            if !Swipe.post(step.direction, steps: 1, fling: step.fling) { arriving = nil }
        }
        if jump.passing.contains(space) { return true }
        arriving = nil
        guard space == jump.space else { return false }
        // Focus after a switch is refocus's to decide, this one included.
        if refocusEnabled, let id = jump.window, let window = lister.currentSpace().first(where: { $0.id == id }) {
            Log.trace("space: landed, focusing \(id)")
            refocusState.refocusing(window.pid, at: ProcessInfo.processInfo.systemUptime)
            Focus.window(window)
        }
        return true
    }

    // MARK: Keeping focus on the Space you arrive in
    //
    // The decision is `Refocus`; this is its timer and its side effects.

    private func activated(_ pid: pid_t?) {
        let space = SkyLight.activeSpace()
        Log.trace("refocus: activation of pid \(pid.map(String.init) ?? "?") on Space \(space.map(String.init) ?? "?")")
        let now = ProcessInfo.processInfo.systemUptime
        let pick = refocusState.activated(pid, at: now, on: space)
        // macOS's pick is already in front; correct it now rather than after
        // the settle, so it does not show for that long.
        guard pick, !landed(on: space), refocusEnabled, !overlay.isVisible else { return }
        let cutoff = now - Refocus.switchMargin
        let here = recency.rank(lister.currentSpace(), before: cutoff)
        apply(refocusState.decidePick(
            here, pick: pid,
            seenUsed: { [recency] in recency.lastUsed($0.id, before: cutoff) != nil }), here, on: "pick")
    }

    private func spaceChanged() {
        let space = SkyLight.activeSpace()
        let jumped = landed(on: space)
        guard refocusEnabled else { return }
        Log.trace("refocus: arrived on Space \(space.map(String.init) ?? "?")")
        let now = ProcessInfo.processInfo.systemUptime
        let correctNow = refocusState.spaceChanged(at: now, to: space)
        // macOS made its pick, if any, as the Space changed; correct it now
        // rather than after the settle, so it does not show for that long.
        if correctNow, !jumped, !overlay.isVisible {
            let cutoff = refocusState.cutoff
            let here = recency.rank(lister.currentSpace(), before: cutoff)
            apply(refocusState.decidePick(
                here, pick: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                seenUsed: { [recency] in recency.lastUsed($0.id, before: cutoff) != nil }), here, on: "arrival")
        }
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

        apply(outcome, here, on: "settle")
    }

    private func apply(_ outcome: Refocus.Outcome, _ here: [Window], on when: String) {
        switch outcome {
        case .leave(let reason):
            Log.trace("refocus (\(when)): left alone (\(reason))")
        case .focus(let id):
            guard let target = here.first(where: { $0.id == id }) else { return }
            Log.trace("refocus (\(when)): \(target.id) \"\(target.title)\"")
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
/// app while the Space you leave is still showing, and the switch follows
/// from it. macOS's own pick on arrival activates one too, but after the
/// Space has changed and before scope hears of it, so an activation counts as
/// a choice only if it was made on the Space scope last arrived at, and that
/// is not the one arrived at now [F37]. This holds for a Space passed through
/// on the way, too. Nor is scope's own refocus, which a quick switch back must
/// not take for a choice.
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
    /// Activations kept: enough that macOS's pick on arrival does not hide a
    /// choice made just before the switch.
    static let activationsKept = 4

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
    /// Whether macOS's pick has been seen, and corrected, ahead of the
    /// Space-change notification for the switch that made it.
    private(set) var pickSeen = false
    /// Recent activations: when, on which Space (nil if unknown), and whether
    /// that was the Space scope had last arrived at. One that was not is
    /// macOS's pick.
    private(set) var activations: [(at: TimeInterval, space: UInt64?, onKnownSpace: Bool)] = []
    private(set) var arrivedOn: UInt64?
    private(set) var refocused: (pid: pid_t, at: TimeInterval)?

    var cutoff: TimeInterval { spaceChangedAt - Self.switchMargin }

    var lastActivation: TimeInterval { activations.last?.at ?? 0 }

    /// Whether an app was activated by a choice that led to the switch: after
    /// the cutoff, on the Space scope had last arrived at, and not the one
    /// arrived at now. One made anywhere else is macOS's pick on arrival
    /// [F37]. With the Space unknown (the private call missing), any
    /// activation after the cutoff counts.
    var chosenBeforeSwitch: Bool {
        activations.contains { activation in
            guard activation.at >= cutoff else { return false }
            guard let space = activation.space, let arrivedOn else { return true }
            return activation.onKnownSpace && space != arrivedOn
        }
    }

    /// `space`: the Space showing when the activation was handled. Returns
    /// whether it is macOS's pick on arrival: made on a Space scope has not
    /// been told it arrived at [F37].
    @discardableResult
    mutating func activated(_ pid: pid_t?, at now: TimeInterval, on space: UInt64?) -> Bool {
        if let refocused, refocused.pid == pid, now - refocused.at < Self.ownActivation { return false }
        let known = arrivedOn == nil || space == nil || space == arrivedOn
        activations = Array((activations + [(now, space, known)]).suffix(Self.activationsKept))
        if !known { pickSeen = true }
        return !known
    }

    /// macOS has just picked `pick` on arrival: the window used last here
    /// gets focus instead, unless it is the pick's own app. Which of its
    /// windows has focus is left to the decision once the switch settles.
    func decidePick<W: Rankable>(_ here: [W], pick: pid_t?, seenUsed: (W) -> Bool) -> Outcome {
        guard let target = here.first, seenUsed(target) else { return .leave(.neverUsed) }
        if target.pid == pick { return .leave(.alreadyThere) }
        return .focus(target.id)
    }

    /// Returns whether to correct focus at once: no choice led to the switch,
    /// so whatever macOS put in front as it changed the Space is its own pick
    /// or the active app carried over [F37], and a pick seen ahead of this
    /// notification has been corrected already. The two notifications come
    /// in either order.
    @discardableResult
    mutating func spaceChanged(at now: TimeInterval, to space: UInt64?) -> Bool {
        spaceChangedAt = now
        arrivedOn = space
        defer { pickSeen = false }
        return !pickSeen && !chosenBeforeSwitch
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
            let carried = !chosenBeforeSwitch && window.pid == frontmost
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
