// Jumping to a Space by number: which shortcuts scope takes over, and where ⌃N goes.

import CoreGraphics
import Foundation
import Testing
@testable import scope

private let ctrl = CGEventFlags.maskControl
private let one: Int64 = 18, two: Int64 = 19

/// A symbolic hotkeys entry as System Settings writes it.
private func entry(code: Int, modifiers: Int = 262_144, enabled: Bool = true) -> [String: Any] {
    ["enabled": enabled, "value": ["parameters": [65535, code, modifiers], "type": "standard"]]
}

@Suite("Space shortcuts")
struct SpaceKeysTests {
    @Test("the Switch to Desktop shortcuts that are on are taken, numbered from their hotkey id")
    func parsesEnabled() {
        let keys = SpaceKeys.parse(["AppleSymbolicHotKeys": [
            "118": entry(code: 18), "119": entry(code: 19), "121": entry(code: 21),
        ]])
        #expect(keys == [
            SpaceShortcut(code: 18, modifiers: ctrl, number: 1),
            SpaceShortcut(code: 19, modifiers: ctrl, number: 2),
            SpaceShortcut(code: 21, modifiers: ctrl, number: 4),
        ])
    }

    @Test("a shortcut that is off, missing or malformed is left to macOS")
    func skipsDisabled() {
        let keys = SpaceKeys.parse(["AppleSymbolicHotKeys": [
            "118": entry(code: 18, enabled: false),
            "119": ["enabled": true, "value": ["parameters": [65535, 19]]],
            "60": entry(code: 49),   // another shortcut altogether
        ]])
        #expect(keys.isEmpty)
        #expect(SpaceKeys.parse([:]).isEmpty)
    }

    @Test("a shortcut set to other modifiers keeps them")
    func otherModifiers() {
        let keys = SpaceKeys.parse(["AppleSymbolicHotKeys": ["118": entry(code: 18, modifiers: 0x180000)]])
        #expect(keys.first?.modifiers == [.maskAlternate, .maskCommand])
    }

    @Test("a press matches only with exactly the shortcut's modifiers: ⌃⇧2 is not ⌃2")
    func exactModifiers() {
        let keys = [SpaceShortcut(code: two, modifiers: ctrl, number: 2)]
        #expect(SpaceKeys.match(code: two, flags: ctrl, in: keys) == 2)
        #expect(SpaceKeys.match(code: two, flags: [.maskControl, .maskShift], in: keys) == nil)
        #expect(SpaceKeys.match(code: two, flags: [], in: keys) == nil)
        #expect(SpaceKeys.match(code: one, flags: ctrl, in: keys) == nil)
    }

    @Test("Caps Lock and other non-modifier bits do not stop a match")
    func ignoresOtherBits() {
        let keys = [SpaceShortcut(code: two, modifiers: ctrl, number: 2)]
        #expect(SpaceKeys.match(code: two, flags: [.maskControl, .maskAlphaShift, .maskNonCoalesced], in: keys) == 2)
    }
}

/// Mission Control order: desktops 1, 3, 4, 5 with a full-screen Space, 9, between 3 and 4.
private let spaces: [UInt64] = [1, 3, 9, 4, 5]
private let desktops: [UInt64] = [1, 3, 4, 5]

private func window(_ id: CGWindowID, on spaces: [UInt64], at time: TimeInterval) -> SpaceJump.Candidate {
    SpaceJump.Candidate(id: id, pid: 10, spaces: spaces, lastUsed: time)
}

private func plan(_ number: Int, from current: UInt64, sliding: SwipeDirection?? = nil,
                  _ candidates: [SpaceJump.Candidate] = []) -> SpaceJump.Plan {
    SpaceJump.plan(number: number, spaces: spaces, desktops: desktops, current: current,
                   sliding: sliding, candidates: candidates)
}

@Suite("Space jump")
struct SpaceJumpTests {
    @Test("⌃N swipes to Desktop N, then focuses the window last used there")
    func swipesThenFocuses() {
        let candidates = [window(1, on: [5], at: 10), window(2, on: [5], at: 30), window(3, on: [4], at: 50)]
        #expect(plan(4, from: 4, candidates) == .swipe(.right, steps: 1, to: 5, window: 2))
    }

    @Test("steps count every Space a swipe passes, full-screen ones too")
    func countsFullScreen() {
        #expect(plan(3, from: 3) == .swipe(.right, steps: 2, to: 4, window: nil))
        #expect(plan(1, from: 5) == .swipe(.left, steps: 4, to: 1, window: nil))
    }

    @Test("a Space with no recorded use is still swiped to; macOS's pick there stands")
    func neverUsed() {
        #expect(plan(2, from: 1, [window(1, on: [5], at: 10)]) == .swipe(.right, steps: 1, to: 3, window: nil))
    }

    @Test("a window gone, or on every Space, is no record of use there")
    func notOnTargetAlone() {
        let candidates = [window(1, on: [], at: 30), window(2, on: spaces, at: 20)]
        #expect(plan(4, from: 4, candidates) == .swipe(.right, steps: 1, to: 5, window: nil))
    }

    @Test("the Space you are on, a number past the last desktop, or no desktops: left to macOS")
    func passes() {
        #expect(plan(2, from: 3) == .pass)
        #expect(plan(5, from: 3) == .pass)
        #expect(SpaceJump.plan(number: 1, spaces: [], desktops: [], current: 3, sliding: nil, candidates: []) == .pass)
    }

    @Test("mid-slide, ⌃N for the Space being left cancels the slide with one swipe back")
    func cancelsSlide() {
        #expect(plan(2, from: 3, sliding: .some(.left)) == .cancel(.right))
        #expect(plan(2, from: 3, sliding: .some(.right)) == .cancel(.left))
    }

    @Test("mid-slide, a Space the other way: one extra swipe undoes the slide, then on from the Space being left")
    func redirectsBack() {
        // Sliding from Desktop 2 (3) toward Desktop 1 (1); ⌃4 is Desktop 4 (5), three Spaces right of 3.
        #expect(plan(4, from: 3, sliding: .some(.left)) == .redirect(.right, steps: 4, to: 5, window: nil))
    }

    @Test("mid-slide, a Space the same way: the slide covers the first step, none more if it is going there")
    func redirectsOn() {
        #expect(plan(4, from: 3, sliding: .some(.right), [window(2, on: [5], at: 9)])
                == .redirect(.right, steps: 2, to: 5, window: 2))
        #expect(plan(1, from: 3, sliding: .some(.left)) == .redirect(.left, steps: 0, to: 1, window: nil))
    }

    @Test("mid-slide, going who knows where: wait for it to land")
    func waitsWhenUnknown() {
        #expect(plan(4, from: 3, sliding: .some(nil)) == .wait)
    }

    @Test("mid-slide, the windows of the Space it is heading for are already on screen: not settled")
    func midSwipe() {
        #expect(!SpaceJump.settled(current: 3, spaces: spaces, onScreen: [[3], [1], [1]]))
    }

    @Test("only the current Space's windows, and windows on every Space: settled")
    func settled() {
        #expect(SpaceJump.settled(current: 1, spaces: spaces, onScreen: [[1], spaces, []]))
    }

    @Test("another display's windows do not make this one look mid-slide")
    func otherDisplay() {
        #expect(SpaceJump.settled(current: 1, spaces: [1, 3], onScreen: [[1], [7]]))
    }

    @Test("a slide heads toward the neighbour whose windows are on screen; others on screen do not count")
    func heading() {
        #expect(SpaceJump.heading(current: 3, spaces: spaces, onScreen: [[3], [1], [5]]) == .left)
        #expect(SpaceJump.heading(current: 3, spaces: spaces, onScreen: [[3], [9]]) == .right)
        #expect(SpaceJump.heading(current: 3, spaces: spaces, onScreen: [[3], [1], [9]]) == nil)
        #expect(SpaceJump.heading(current: 3, spaces: spaces, onScreen: [[3]]) == nil)
    }

    @Test("a swipe's sign gives its direction: positive is right, the other way with natural scrolling")
    func direction() {
        #expect(SpaceJump.direction(of: -3.6, natural: false) == .left)    // observed: toward Desktop 1
        #expect(SpaceJump.direction(of: 4.4, natural: false) == .right)
        #expect(SpaceJump.direction(of: -3.6, natural: true) == .right)
    }

    @Test("slide seconds map to the measured fling velocity, interpolated, held at the long end, instant below the short end")
    func slideSpeed() {
        #expect(SlideSpeed.velocity(seconds: 0) == Swipe.instantFling)
        #expect(SlideSpeed.velocity(seconds: 0.323) == 55)
        #expect(abs(SlideSpeed.velocity(seconds: 0.2835) - 55.125) < 0.001)   // halfway between 0.244 and 0.323
        #expect(SlideSpeed.velocity(seconds: 1.0) == 15)
    }

    @Test("a longer slide never needs a faster fling: the table runs one way")
    func slideTableMonotonic() {
        let t = SlideSpeed.table
        #expect(zip(t, t.dropFirst()).allSatisfy { $0.seconds < $1.seconds && $0.velocity > $1.velocity })
    }

    @Test("a timed slide's last step starts from the Space just before the target, coming from either side")
    func lastStepStart() {
        #expect(SpaceJump.before(5, going: .right, in: spaces) == 4)
        #expect(SpaceJump.before(1, going: .left, in: spaces) == 3)
        #expect(SpaceJump.before(1, going: .right, in: spaces) == nil)
    }

    @Test("a multi-step swipe passes the Spaces between; one step passes none")
    func between() {
        #expect(SpaceJump.between(1, 4, in: spaces) == [3, 9])
        #expect(SpaceJump.between(5, 4, in: spaces) == [])
    }
}
