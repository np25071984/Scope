// The key tap's decisions: which events are swallowed, and what they mean.

import CoreGraphics
import Testing
@testable import scope

private let tab = KeyTap.State.tab
private let escape = KeyTap.State.escape
private let letterC: Int64 = 8
private let cmd = CGEventFlags.maskCommand
private let cmdShift: CGEventFlags = [.maskCommand, .maskShift]

/// Three rows at the origin: padding 10, rows 54 high, 620 wide.
private let geometry = KeyTap.Geometry(
    frame: CGRect(x: 100, y: 100, width: 620, height: 10 * 2 + 3 * 54),
    padding: 10, rowHeight: 54, rows: 3)

/// A state that has just opened the switcher, with the overlay shown.
private func opened(mouse: Bool = true) -> KeyTap.State {
    var state = KeyTap.State()
    state.mouse = mouse
    _ = state.handle(.keyDown(code: tab, flags: cmd))
    _ = state.shown(geometry, session: state.session)
    return state
}

@Suite("Opening")
struct OpeningTests {
    @Test("modifier + Tab opens forward, swallowed, with a new session")
    func opensForward() {
        var state = KeyTap.State()
        let out = state.handle(.keyDown(code: tab, flags: cmd))
        #expect(out == .init(swallow: true, action: .show(delta: 1, session: 1)))
        #expect(state.open)
    }

    @Test("modifier + Shift + Tab opens backward")
    func opensBackward() {
        var state = KeyTap.State()
        #expect(state.handle(.keyDown(code: tab, flags: cmdShift)).action == .show(delta: -1, session: 1))
    }

    @Test("Tab without the modifier passes: scope takes only its own combination")
    func plainTabPasses() {
        var state = KeyTap.State()
        #expect(state.handle(.keyDown(code: tab, flags: [])) == .init())
        #expect(!state.open)
    }

    @Test("the configured modifier is the one that opens")
    func configuredModifier() {
        var state = KeyTap.State()
        state.modifier = .maskAlternate
        #expect(state.handle(.keyDown(code: tab, flags: cmd)) == .init())
        #expect(state.handle(.keyDown(code: tab, flags: .maskAlternate)).swallow)
    }

    @Test("other keys with the modifier pass while closed (⌘C, ⌘`)")
    func otherKeysPass() {
        var state = KeyTap.State()
        #expect(state.handle(.keyDown(code: letterC, flags: cmd)) == .init())
    }

    @Test("every opening gets a new session number")
    func sessionsIncrease() {
        var state = KeyTap.State()
        _ = state.handle(.keyDown(code: tab, flags: cmd))
        _ = state.handle(.flagsChanged([]))
        #expect(state.handle(.keyDown(code: tab, flags: cmd)).action == .show(delta: 1, session: 2))
    }
}

@Suite("While open")
struct OpenTests {
    @Test("Tab steps forward, Shift+Tab back, both swallowed")
    func tabSteps() {
        var state = opened()
        #expect(state.handle(.keyDown(code: tab, flags: cmd)) == .init(swallow: true, action: .step(delta: 1)))
        #expect(state.handle(.keyDown(code: tab, flags: cmdShift)) == .init(swallow: true, action: .step(delta: -1)))
    }

    @Test("Tab before the list is shown still steps: the tap, not the overlay, knows the switcher is open")
    func tabBeforeShown() {
        var state = KeyTap.State()
        _ = state.handle(.keyDown(code: tab, flags: cmd))
        #expect(state.handle(.keyDown(code: tab, flags: cmd)).action == .step(delta: 1))
    }

    @Test("releasing the modifier commits; the release itself passes")
    func releaseCommits() {
        var state = opened()
        #expect(state.handle(.flagsChanged([])) == .init(swallow: false, action: .commit, closed: true))
        #expect(!state.open)
    }

    @Test("releasing the modifier before the list is shown still commits")
    func releaseBeforeShown() {
        var state = KeyTap.State()
        _ = state.handle(.keyDown(code: tab, flags: cmd))
        #expect(state.handle(.flagsChanged([])).action == .commit)
    }

    @Test("releasing only Shift does not commit")
    func shiftReleaseKeepsOpen() {
        var state = opened()
        _ = state.handle(.flagsChanged(cmdShift))
        #expect(state.handle(.flagsChanged(cmd)) == .init())
        #expect(state.open)
    }

    @Test("escape cancels, swallowed")
    func escapeCancels() {
        var state = opened()
        #expect(state.handle(.keyDown(code: escape, flags: cmd)) == .init(swallow: true, action: .cancel, closed: true))
    }

    @Test("other keys pass while open")
    func otherKeysPassWhileOpen() {
        var state = opened()
        #expect(state.handle(.keyDown(code: letterC, flags: cmd)) == .init())
        #expect(state.open)
    }

    @Test("modifier changes while closed pass and do nothing")
    func flagsWhileClosed() {
        var state = KeyTap.State()
        #expect(state.handle(.flagsChanged([])) == .init())
    }
}

@Suite("Pointer")
struct PointerTests {
    @Test("moving over a row selects it, and the move always passes so the cursor never freezes")
    func hoverSelects() {
        var state = opened()
        #expect(state.handle(.pointerMoved(CGPoint(x: 200, y: 100 + 10 + 54 + 5))) == .init(action: .select(row: 1)))
    }

    @Test("moving off the rows does nothing")
    func hoverOutside() {
        var state = opened()
        #expect(state.handle(.pointerMoved(CGPoint(x: 50, y: 50))) == .init())
    }

    @Test("a press on the overlay or elsewhere is swallowed while open: no click reaches the window underneath")
    func pressSwallowed() {
        var state = opened()
        #expect(state.handle(.pointerDown) == .init(swallow: true))
    }

    @Test("a press passes before the overlay is shown, and while closed")
    func pressPassesWithoutGeometry() {
        var closed = KeyTap.State()
        #expect(closed.handle(.pointerDown) == .init())
        var opening = KeyTap.State()
        _ = opening.handle(.keyDown(code: tab, flags: cmd))
        #expect(opening.handle(.pointerDown) == .init())
    }

    @Test("releasing the click on a row picks it")
    func clickPicks() {
        var state = opened()
        let out = state.handle(.pointerUp(CGPoint(x: 200, y: 100 + 10 + 2 * 54 + 1)))
        #expect(out == .init(swallow: true, action: .pick(row: 2), closed: true))
    }

    @Test("releasing the click elsewhere cancels")
    func clickElsewhereCancels() {
        var state = opened()
        #expect(state.handle(.pointerUp(CGPoint(x: 5, y: 5))) == .init(swallow: true, action: .cancel, closed: true))
    }

    @Test("the pointer tap runs only for the current session, and only with mouse on")
    func pointerTapOnlyWhenCurrent() {
        var state = KeyTap.State()
        _ = state.handle(.keyDown(code: tab, flags: cmd))
        let current = state.shown(geometry, session: state.session)
        let stale = state.shown(geometry, session: state.session - 1)
        #expect(current)
        #expect(!stale)

        var noMouse = KeyTap.State()
        noMouse.mouse = false
        _ = noMouse.handle(.keyDown(code: tab, flags: cmd))
        let pointer = noMouse.shown(geometry, session: noMouse.session)
        #expect(!pointer)
    }
}

@Suite("Sessions")
struct SessionTests {
    @Test("closed(session) from main closes the switcher it belongs to")
    func closedCurrent() {
        var state = opened()
        let closed = state.closed(session: state.session)
        #expect(closed)
        #expect(!state.open)
    }

    @Test("a late closed() from an earlier session does not close the switcher the next ⌘Tab opened")
    func lateCloseIgnored() {
        var state = opened()
        let first = state.session
        _ = state.handle(.flagsChanged([]))           // commit, still being carried out on main
        _ = state.handle(.keyDown(code: tab, flags: cmd))  // the next ⌘Tab
        let closed = state.closed(session: first)
        #expect(!closed)
        #expect(state.open)
    }

    @Test("a late shown() from an earlier session does not install its geometry")
    func lateShownIgnored() {
        var state = KeyTap.State()
        _ = state.handle(.keyDown(code: tab, flags: cmd))
        let first = state.session
        _ = state.handle(.flagsChanged([]))
        _ = state.handle(.keyDown(code: tab, flags: cmd))
        _ = state.shown(geometry, session: first)
        #expect(state.geometry == nil)
    }
}

@Suite("Row hit-testing")
struct GeometryTests {
    @Test("rows are found arithmetically, below the top padding", arguments: [
        (CGPoint(x: 200, y: 110), 0),
        (CGPoint(x: 200, y: 163), 0),
        (CGPoint(x: 200, y: 164), 1),
        (CGPoint(x: 200, y: 271), 2),
    ])
    func rows(point: CGPoint, row: Int) {
        #expect(geometry.row(at: point) == row)
    }

    @Test("no row in the padding, past the last row or outside the frame", arguments: [
        CGPoint(x: 200, y: 105),
        CGPoint(x: 200, y: 100 + 10 + 3 * 54 + 2),
        CGPoint(x: 99, y: 150),
        CGPoint(x: 721, y: 150),
    ])
    func outside(point: CGPoint) {
        #expect(geometry.row(at: point) == nil)
    }
}
