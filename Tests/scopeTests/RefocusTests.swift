// Whether to move focus after a Space switch, and where.

import CoreGraphics
import Testing
@testable import scope

/// Ranked windows on the Space just arrived at: `used` was used last, `other` before it.
private let used = TestWindow(id: 1, pid: 10, z: 1)
private let other = TestWindow(id: 2, pid: 20, z: 0)
private let here = [used, other]

/// A refocus state for a Space switch at t = 100 (cutoff 99).
private func switched(activationAt: Double? = nil) -> Refocus {
    var state = Refocus()
    if let activationAt { state.activated(30, at: activationAt) }
    state.spaceChanged(at: 100)
    return state
}

private let seen: (TestWindow) -> Bool = { _ in true }

@Suite("Refocus")
struct RefocusTests {
    @Test("nothing on the new Space has focus: focus the window used last here")
    func nothingFocused() {
        #expect(switched().decide(here, focused: nil, frontmost: 99, seenUsed: seen) == .focus(1))
    }

    @Test("focus is on a window of another Space's app (not in this Space's list): focus the window used last here")
    func focusElsewhere() {
        #expect(switched().decide(here, focused: 500, frontmost: 99, seenUsed: seen) == .focus(1))
    }

    @Test("macOS carried the active app over to its window here: override it")
    func carriedOver() {
        let decision = switched(activationAt: 50).decide(here, focused: 2, frontmost: 20, seenUsed: seen)
        #expect(decision == .focus(1))
    }

    @Test("an app was activated around the switch: the focused window was chosen, leave it")
    func activationMeansChoice() {
        let decision = switched(activationAt: 99.5).decide(here, focused: 2, frontmost: 20, seenUsed: seen)
        #expect(decision == .leave(.chosen))
    }

    @Test("the focused window is not the frontmost app's: it was chosen, leave it")
    func notFrontmost() {
        let decision = switched(activationAt: 50).decide(here, focused: 2, frontmost: 77, seenUsed: seen)
        #expect(decision == .leave(.chosen))
    }

    @Test("carried over, but already the window used last: nothing to do")
    func alreadyThere() {
        let decision = switched(activationAt: 50).decide(here, focused: 1, frontmost: 10, seenUsed: seen)
        #expect(decision == .leave(.alreadyThere))
    }

    @Test("no window here was seen used before the switch: don't guess from stacking order")
    func neverUsed() {
        let decision = switched().decide(here, focused: nil, frontmost: 99, seenUsed: { _ in false })
        #expect(decision == .leave(.neverUsed))
    }

    @Test("an empty Space: nothing to focus")
    func empty() {
        #expect(switched().decide([TestWindow](), focused: nil, frontmost: nil, seenUsed: seen) == .leave(.neverUsed))
    }

    @Test("ranking uses the use from a margin before the notification, which follows the animation")
    func cutoff() {
        #expect(switched().cutoff == 100 - Refocus.switchMargin)
    }

    @Test("scope's own refocus activation is not taken for a choice")
    func ownActivationIgnored() {
        var state = Refocus()
        state.activated(30, at: 50)
        state.refocusing(10, at: 200)
        state.activated(10, at: 200 + Refocus.ownActivation / 2)   // scope's own doing
        state.spaceChanged(at: 201)
        #expect(state.lastActivation == 50)
        #expect(state.decide(here, focused: 2, frontmost: 20, seenUsed: seen) == .focus(1))
    }

    @Test("the same app activated later than that is a choice again")
    func laterActivationCounts() {
        var state = Refocus()
        state.refocusing(10, at: 200)
        state.activated(10, at: 200 + Refocus.ownActivation)
        #expect(state.lastActivation == 200 + Refocus.ownActivation)
    }
}
