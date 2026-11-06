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

private let desktops: [UInt64] = [1, 3, 4, 5]

private func window(_ id: CGWindowID, on spaces: [UInt64], at time: TimeInterval) -> SpaceJump.Candidate {
    SpaceJump.Candidate(id: id, pid: 10, spaces: spaces, lastUsed: time)
}

@Suite("Space jump")
struct SpaceJumpTests {
    @Test("⌃N goes to the window last used on Desktop N")
    func newestOnTarget() {
        let candidates = [window(1, on: [5], at: 10), window(2, on: [5], at: 30), window(3, on: [4], at: 50)]
        #expect(SpaceJump.decide(number: 4, desktops: desktops, current: 3, candidates: candidates) == .jump(2))
    }

    @Test("desktops are counted in the display's order, not by id")
    func countsInOrder() {
        let candidates = [window(7, on: [3], at: 10)]
        #expect(SpaceJump.decide(number: 2, desktops: desktops, current: 1, candidates: candidates) == .jump(7))
    }

    @Test("a Space with no recorded use is left to macOS: the window order is no record of use")
    func neverUsed() {
        let candidates = [window(1, on: [4], at: 10)]
        #expect(SpaceJump.decide(number: 4, desktops: desktops, current: 3, candidates: candidates) == .pass)
    }

    @Test("a window gone, or on every Space, is no target: no switch would follow it")
    func notOnTargetAlone() {
        let candidates = [window(1, on: [], at: 30), window(2, on: [1, 3, 4, 5], at: 20)]
        #expect(SpaceJump.decide(number: 4, desktops: desktops, current: 3, candidates: candidates) == .pass)
    }

    @Test("the Space you are on: left to macOS, which does nothing")
    func alreadyThere() {
        let candidates = [window(1, on: [3], at: 10)]
        #expect(SpaceJump.decide(number: 2, desktops: desktops, current: 3, candidates: candidates) == .pass)
    }

    @Test("a number past the last desktop, or no desktops known: left to macOS")
    func outOfRange() {
        let candidates = [window(1, on: [5], at: 10)]
        #expect(SpaceJump.decide(number: 5, desktops: desktops, current: 3, candidates: candidates) == .pass)
        #expect(SpaceJump.decide(number: 1, desktops: [], current: 3, candidates: candidates) == .pass)
    }
}
