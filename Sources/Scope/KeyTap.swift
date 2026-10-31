// The event taps, on a thread of their own.
//
// macOS gives a tap's handler a deadline. A handler that misses it -- say,
// because it waits on a slow app while building the window list -- loses the
// key to the Dock, and the system switcher comes up. So the handler only
// decides -- swallow or pass, and which action to post to the main thread --
// and returns at once. Building the list happens afterwards, on the main
// thread, with the key already swallowed.
//
// The decision needs to know whether the switcher is open before the overlay
// exists: Tab pressed again, or ⌘ released, while the list is still being built
// must step or commit, not open a second one. So "open" is this tap's own
// state, set the moment it swallows the activation, and the main thread
// executes actions in the order they were posted.

import AppKit

final class KeyTap {
    enum Action: Equatable {
        /// `session` identifies this opening; hand it back to `shown` and
        /// `closed` so a late call about an earlier one is ignored.
        case show(delta: Int, session: Int)
        case step(delta: Int)
        case select(row: Int)
        case commit
        case pick(row: Int)
        case cancel
    }

    struct Geometry: Equatable {
        /// Global coordinates, top-left origin, the same space as event locations.
        let frame: CGRect
        let padding: CGFloat
        let rowHeight: CGFloat
        let rows: Int

        func row(at p: CGPoint) -> Int? {
            guard frame.contains(p) else { return nil }
            let i = Int(floor((p.y - frame.minY - padding) / rowHeight))
            return (0..<rows).contains(i) ? i : nil
        }
    }

    /// What a tap callback sees, stripped of the CGEvent.
    enum Input {
        case flagsChanged(CGEventFlags)
        case keyDown(code: Int64, flags: CGEventFlags)
        case pointerMoved(CGPoint)
        case pointerDown
        case pointerUp(CGPoint)
    }

    /// What to do about it.
    struct Output: Equatable {
        var swallow = false
        var action: Action?
        /// The switcher closed: turn the pointer tap off.
        var closed = false
    }

    /// The tap's decisions: every rule about which events are swallowed and
    /// what they mean, with no CGEvent, lock or thread in sight.
    ///
    /// The tap, not the overlay, owns whether the switcher is open. `open`
    /// flips the moment the activation is swallowed, before any list exists,
    /// so a Tab or a modifier release that arrives while the list is still
    /// being built steps or commits instead of opening a second switcher.
    struct State {
        static let tab: Int64 = 48
        static let escape: Int64 = 53

        var open = false
        var session = 0
        var modifier: CGEventFlags = .maskCommand
        var mouse = true
        var geometry: Geometry?

        mutating func handle(_ input: Input) -> Output {
            switch input {
            case .flagsChanged(let flags):
                // Releasing the modifier is the only way to commit, as with
                // every other switcher on the platform. The event itself passes.
                if open && !flags.contains(modifier) { return close(.commit, swallow: false) }
                return Output()

            case .keyDown(let code, let flags):
                let delta = flags.contains(.maskShift) ? -1 : 1
                if open {
                    if code == Self.tab { return Output(swallow: true, action: .step(delta: delta)) }
                    if code == Self.escape { return close(.cancel, swallow: true) }
                    return Output()
                }
                guard code == Self.tab, flags.contains(modifier) else { return Output() }
                open = true
                session &+= 1
                return Output(swallow: true, action: .show(delta: delta, session: session))

            case .pointerMoved(let point):
                // Never swallowed; that would freeze the cursor.
                guard open, let row = geometry?.row(at: point) else { return Output() }
                return Output(action: .select(row: row))

            case .pointerDown:
                // Swallowed while the overlay is up, so the click never reaches
                // the window underneath; the decision waits for the release.
                return Output(swallow: open && geometry != nil)

            case .pointerUp(let point):
                guard open, let geometry else { return Output() }
                if let row = geometry.row(at: point) { return close(.pick(row: row), swallow: true) }
                return close(.cancel, swallow: true)
            }
        }

        /// The overlay is on screen. Returns whether the pointer tap should
        /// run: never for a session that has already closed.
        mutating func shown(_ geometry: Geometry, session: Int) -> Bool {
            let current = open && session == self.session
            if current { self.geometry = geometry }
            return mouse && current
        }

        /// The switcher closed for a reason the tap did not see. Returns false,
        /// and changes nothing, when the tap has opened again since: a commit
        /// still being carried out must not close the switcher the next ⌘Tab
        /// opened.
        mutating func closed(session: Int) -> Bool {
            guard session == self.session else { return false }
            open = false
            geometry = nil
            return true
        }

        private mutating func close(_ action: Action, swallow: Bool) -> Output {
            open = false
            geometry = nil
            return Output(swallow: swallow, action: action, closed: true)
        }
    }

    private let thread = RunLoopThread(name: "scope.tap")
    private let perform: (Action) -> Void

    private let lock = NSLock()
    private var state = State()  // guarded by lock

    private var keyTap: CFMachPort?
    private var mouseTap: CFMachPort?

    /// `perform` is called on the main thread.
    init(perform: @escaping (Action) -> Void) {
        self.perform = perform
    }

    /// Fails without Accessibility permission; nothing else stops a tap.
    func start() -> Bool {
        if keyTap != nil { return true }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type, event)
        }

        func mask(_ types: [CGEventType]) -> CGEventMask {
            types.reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
        }
        guard let keys = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask([.keyDown, .flagsChanged]),
            callback: callback, userInfo: refcon)
        else { return false }

        // Created now, enabled only while the overlay is open: mouseMoved fires
        // continuously, and there is no reason to see it the rest of the day.
        let pointer = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask([.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]),
            callback: callback, userInfo: refcon)

        keyTap = keys
        mouseTap = pointer
        thread.add(CFMachPortCreateRunLoopSource(nil, keys, 0))
        if let pointer {
            CGEvent.tapEnable(tap: pointer, enable: false)
            thread.add(CFMachPortCreateRunLoopSource(nil, pointer, 0))
        }
        return true
    }

    func configure(modifier: CGEventFlags, mouse: Bool) {
        lock.lock()
        state.modifier = modifier
        state.mouse = mouse
        lock.unlock()
    }

    /// The overlay is on screen with these rows; pointer events can be mapped.
    func shown(_ geometry: Geometry, session: Int) {
        lock.lock()
        let pointer = state.shown(geometry, session: session)
        lock.unlock()
        if pointer, let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: true) }
    }

    /// The switcher closed, possibly for a reason the tap did not see: nothing
    /// to show, the watchdog.
    func closed(session: Int) {
        lock.lock()
        defer { lock.unlock() }
        if state.closed(session: session), let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: false) }
    }

    // MARK: Tap thread

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // macOS switches a tap off when a handler is slow or when secure input
        // starts. This handler is never slow, but secure input still happens.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.warn("event tap was disabled (\(type.rawValue)); re-enabling")
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
            lock.lock()
            let pointer = state.open && state.geometry != nil
            lock.unlock()
            if pointer, let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: true) }
            return pass
        }

        let input: Input
        switch type {
        case .flagsChanged: input = .flagsChanged(event.flags)
        case .keyDown: input = .keyDown(code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
        case .mouseMoved, .leftMouseDragged: input = .pointerMoved(event.location)
        case .leftMouseDown: input = .pointerDown
        case .leftMouseUp: input = .pointerUp(event.location)
        default: return pass
        }

        lock.lock()
        let output = state.handle(input)
        if output.closed, let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: false) }
        lock.unlock()

        if let action = output.action { DispatchQueue.main.async { self.perform(action) } }
        return output.swallow ? nil : pass
    }
}
