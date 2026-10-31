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
    enum Action {
        /// `session` identifies this opening; hand it back to `shown` and
        /// `closed` so a late call about an earlier one is ignored.
        case show(delta: Int, session: Int)
        case step(delta: Int)
        case select(row: Int)
        case commit
        case pick(row: Int)
        case cancel
    }

    struct Geometry {
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

    private static let tab: Int64 = 48
    private static let escape: Int64 = 53

    private let thread = RunLoopThread(name: "scope.tap")
    private let perform: (Action) -> Void

    private let lock = NSLock()
    private var open = false  // guarded by lock, as are the four below
    private var session = 0
    private var modifier: CGEventFlags = .maskCommand
    private var mouse = true
    private var geometry: Geometry?

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
        self.modifier = modifier
        self.mouse = mouse
        lock.unlock()
    }

    /// The overlay is on screen with these rows; pointer events can be mapped.
    func shown(_ geometry: Geometry, session: Int) {
        lock.lock()
        let current = open && session == self.session
        if current { self.geometry = geometry }
        let pointer = mouse && current
        lock.unlock()
        if pointer, let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: true) }
    }

    /// The switcher closed, possibly for a reason the tap did not see: nothing
    /// to show, the watchdog. Ignored when the tap has opened again since --
    /// a commit is still being carried out on the main thread when the next
    /// ⌘Tab arrives, and must not close the switcher that one opened.
    func closed(session: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard session == self.session else { return }
        open = false
        geometry = nil
        if let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: false) }
    }

    // MARK: Tap thread

    private func post(_ action: Action) {
        DispatchQueue.main.async { self.perform(action) }
    }

    private func close(then action: Action) {
        open = false
        geometry = nil
        if let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: false) }
        post(action)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // macOS switches a tap off when a handler is slow or when secure input
        // starts. This handler is never slow, but secure input still happens.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.warn("event tap was disabled (\(type.rawValue)); re-enabling")
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
            lock.lock()
            let pointer = open && geometry != nil
            lock.unlock()
            if pointer, let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: true) }
            return pass
        }

        lock.lock()
        defer { lock.unlock() }
        let flags = event.flags

        switch type {
        case .flagsChanged:
            // Releasing the modifier is the only way to commit, as with every
            // other switcher on the platform. The event itself passes.
            if open && !flags.contains(modifier) { close(then: .commit) }
            return pass

        case .keyDown:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let delta = flags.contains(.maskShift) ? -1 : 1
            if open {
                if key == Self.tab { post(.step(delta: delta)); return nil }
                if key == Self.escape { close(then: .cancel); return nil }
                return pass
            }
            guard key == Self.tab, flags.contains(modifier) else { return pass }
            open = true
            session &+= 1
            post(.show(delta: delta, session: session))
            return nil

        case .mouseMoved, .leftMouseDragged:
            // Never swallowed; that would freeze the cursor.
            if open, let row = geometry?.row(at: event.location) { post(.select(row: row)) }
            return pass

        case .leftMouseDown:
            // Swallowed when the overlay is up, so the click never reaches the
            // window underneath; the decision waits for the release.
            return open && geometry != nil ? nil : pass

        case .leftMouseUp:
            guard open, let geometry else { return pass }
            if let row = geometry.row(at: event.location) {
                close(then: .pick(row: row))
            } else {
                close(then: .cancel)
            }
            return nil

        default:
            return pass
        }
    }
}
