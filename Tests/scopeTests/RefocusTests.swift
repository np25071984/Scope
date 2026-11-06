// Whether to move focus after a Space switch, and where.

import CoreGraphics
import Testing
@testable import scope

/// Ranked windows on the Space just arrived at: `used` was used last, `other` before it.
private let used = TestWindow(id: 1, pid: 10, z: 1)
private let other = TestWindow(id: 2, pid: 20, z: 0)
private let here = [used, other]

/// The Space left and the Space arrived at.
private let left: UInt64 = 3
private let arrived: UInt64 = 5

/// A refocus state for a Space switch at t = 100 (cutoff 99), from the Space
/// left, with an activation made while it was showing.
private func switched(activationAt: Double? = nil) -> Refocus {
    var state = Refocus()
    state.spaceChanged(at: 10, to: left)
    if let activationAt { state.activated(30, at: activationAt, on: left) }
    state.spaceChanged(at: 100, to: arrived)
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

    @Test("an app activated once the Space arrived at was showing is macOS's pick, not a choice, even when its notification comes first: override it")
    func arrivalActivationIsNotChoice() {
        var state = Refocus()
        state.activated(20, at: 99.99, on: arrived)
        state.spaceChanged(at: 100, to: arrived)
        #expect(state.decide(here, focused: 2, frontmost: 20, seenUsed: seen) == .focus(1))
    }

    @Test("macOS's pick on a Space passed through on the way is not a choice either: override it")
    func pickOnSpacePassedThrough() {
        var state = Refocus()
        state.spaceChanged(at: 10, to: arrived)
        state.activated(20, at: 99.5, on: left)      // macOS's pick on the Space passed through
        state.spaceChanged(at: 99.51, to: left)
        state.spaceChanged(at: 100, to: arrived)
        #expect(state.decide(here, focused: 2, frontmost: 20, seenUsed: seen) == .focus(1))
    }

    @Test("an activation on the Space you are on, before you leave it, is a choice")
    func choiceOnSpaceShowing() {
        var state = Refocus()
        state.spaceChanged(at: 10, to: left)
        state.activated(20, at: 99.7, on: left)
        state.spaceChanged(at: 100, to: arrived)
        #expect(state.decide(here, focused: 2, frontmost: 20, seenUsed: seen) == .leave(.chosen))
    }

    @Test("an activation on a Space scope has not arrived at is macOS's pick; one on the Space it is on is not")
    func pickDetected() {
        var state = Refocus()
        state.spaceChanged(at: 10, to: left)
        #expect(state.activated(20, at: 50, on: left) == false)
        #expect(state.activated(20, at: 60, on: arrived) == true)
        #expect(state.activated(20, at: 70, on: nil) == false)
    }

    @Test("macOS's pick, as it happens: the window used last here gets focus, without waiting for the switch to settle")
    func pickCorrected() {
        #expect(Refocus().decidePick(here, pick: 20, seenUsed: seen) == .focus(1))
    }

    @Test("macOS picked the app used last here: leave it, the settled decision sees to its window")
    func pickRight() {
        #expect(Refocus().decidePick(here, pick: 10, seenUsed: seen) == .leave(.alreadyThere))
    }

    @Test("macOS's pick on a Space with no recorded use: leave it")
    func pickNeverUsed() {
        #expect(Refocus().decidePick(here, pick: 20, seenUsed: { _ in false }) == .leave(.neverUsed))
    }

    @Test("arriving with no choice behind the switch: correct at once, macOS's pick is already in front")
    func correctOnArrival() {
        var state = Refocus()
        state.spaceChanged(at: 10, to: left)
        #expect(state.spaceChanged(at: 100, to: arrived) == true)
    }

    @Test("arriving after a choice: nothing to correct at once")
    func noCorrectionAfterChoice() {
        var state = Refocus()
        state.spaceChanged(at: 10, to: left)
        state.activated(20, at: 99.7, on: left)
        #expect(state.spaceChanged(at: 100, to: arrived) == false)
    }

    @Test("arriving after macOS's pick was seen and corrected: not again, and the next switch starts clean")
    func pickAlreadyCorrected() {
        var state = Refocus()
        state.spaceChanged(at: 10, to: left)
        state.activated(20, at: 99.99, on: arrived)
        #expect(state.spaceChanged(at: 100, to: arrived) == false)
        #expect(state.spaceChanged(at: 200, to: left) == true)
    }

    @Test("the Space unknown (private call missing): an activation around the switch counts as a choice, as before")
    func spaceUnknown() {
        var state = Refocus()
        state.activated(20, at: 99.99, on: nil)
        state.spaceChanged(at: 100, to: arrived)
        #expect(state.decide(here, focused: 2, frontmost: 20, seenUsed: seen) == .leave(.chosen))
    }

    @Test("a choice that led to the switch, then macOS's pick on arrival: still a choice")
    func choiceThenArrival() {
        var state = Refocus()
        state.spaceChanged(at: 10, to: left)
        state.activated(20, at: 99.6, on: left)
        state.activated(20, at: 99.99, on: arrived)
        state.spaceChanged(at: 100, to: arrived)
        #expect(state.decide(here, focused: 2, frontmost: 20, seenUsed: seen) == .leave(.chosen))
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
        state.activated(30, at: 50, on: left)
        state.refocusing(10, at: 200)
        state.activated(10, at: 200 + Refocus.ownActivation / 2, on: arrived)   // scope's own doing
        state.spaceChanged(at: 201, to: arrived)
        #expect(state.lastActivation == 50)
        #expect(state.decide(here, focused: 2, frontmost: 20, seenUsed: seen) == .focus(1))
    }

    @Test("the same app activated later than that is a choice again")
    func laterActivationCounts() {
        var state = Refocus()
        state.refocusing(10, at: 200)
        state.activated(10, at: 200 + Refocus.ownActivation, on: arrived)
        #expect(state.lastActivation == 200 + Refocus.ownActivation)
    }
}
