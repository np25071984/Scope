// The switcher's list and selection.

import CoreGraphics
import Testing
@testable import scope

@Suite("Switcher")
struct SwitcherTests {
    @Test("forward opens on the second row, so a quick press and release toggles the two most recent windows")
    func forwardSelectsSecond() {
        #expect(Switcher.firstSelection(delta: 1, count: 5) == 1)
    }

    @Test("backward opens on the last row")
    func backwardSelectsLast() {
        #expect(Switcher.firstSelection(delta: -1, count: 5) == 4)
    }

    @Test("steps wrap around in both directions", arguments: [
        (0, 1, 1), (4, 1, 0), (0, -1, 4), (2, -1, 1),
    ])
    func wraps(index: Int, delta: Int, expected: Int) {
        #expect(Switcher.stepped(index, by: delta, count: 5) == expected)
    }

    @Test("the focused window goes first whatever the stamps say: the stamp for a switch just made may not have landed")
    func focusedFirst() {
        let list = [TestWindow(id: 1), TestWindow(id: 2), TestWindow(id: 3)]
        #expect(Switcher.focusedFirst(list, focused: 2).map(\.id) == [2, 1, 3])
    }

    @Test("otherwise the ranked order stands", arguments: [nil, 1, 99] as [CGWindowID?])
    func unchanged(focused: CGWindowID?) {
        let list = [TestWindow(id: 1), TestWindow(id: 2)]
        #expect(Switcher.focusedFirst(list, focused: focused).map(\.id) == [1, 2])
    }
}
