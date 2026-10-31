// When each window was last used, and the order that gives.

import CoreGraphics
import Testing
@testable import scope

struct TestWindow: Rankable, Equatable {
    let id: CGWindowID
    var pid: pid_t = 1
    var frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    var z = 0
}

private let space: UInt64 = 7
private let otherSpace: UInt64 = 8

private func ids(_ windows: [TestWindow]) -> [CGWindowID] { windows.map(\.id) }

@Suite("Recording use")
struct RecordingTests {
    @Test("a window not seen used has no last use")
    func unseen() {
        #expect(StampTable().lastUsed(1) == nil)
    }

    @Test("the latest use wins")
    func latest() {
        var table = StampTable()
        table.record(1, at: 10, pid: 1, frame: nil, space: space)
        table.record(1, at: 20, pid: 1, frame: nil, space: space)
        #expect(table.lastUsed(1) == 20)
    }

    @Test("looking before a cutoff finds the use before it")
    func beforeCutoff() {
        var table = StampTable()
        table.record(1, at: 10, pid: 1, frame: nil, space: space)
        table.record(1, at: 20, pid: 1, frame: nil, space: space)
        #expect(table.lastUsed(1, before: 15) == 10)
        #expect(table.lastUsed(1, before: 5) == nil)
    }

    @Test("a burst of stamps within the history window keeps the use from before the burst")
    func burstKeepsEarlierUse() {
        // One switch stamps the same window several times within
        // milliseconds: activated, focus changed, deactivated.
        var table = StampTable()
        table.record(1, at: 10, pid: 1, frame: nil, space: space)
        table.record(1, at: 50.00, pid: 1, frame: nil, space: space)
        table.record(1, at: 50.01, pid: 1, frame: nil, space: space)
        table.record(1, at: 50.02, pid: 1, frame: nil, space: space)
        #expect(table.lastUsed(1, before: 49) == 10)   // not 50.00 or 50.01
    }

    @Test("uses further apart than the history window each become the previous one")
    func previousAdvances() {
        var table = StampTable()
        table.record(1, at: 10, pid: 1, frame: nil, space: space)
        table.record(1, at: 10 + StampTable.history, pid: 1, frame: nil, space: space)
        table.record(1, at: 30, pid: 1, frame: nil, space: space)
        #expect(table.lastUsed(1, before: 29) == 11)
    }

    @Test("only one use back is remembered")
    func oneUseBack() {
        var table = StampTable()
        for t in [10.0, 20, 30] { table.record(1, at: t, pid: 1, frame: nil, space: space) }
        #expect(table.lastUsed(1, before: 15) == nil)
    }

    @Test("past the limit, only the newest stamps survive")
    func trimmed() {
        var table = StampTable()
        for i in 0...StampTable.limit {
            table.record(CGWindowID(i), at: Double(i), pid: 1, frame: nil, space: space)
        }
        #expect(table.stamps.count == StampTable.keep)
        #expect(table.lastUsed(CGWindowID(StampTable.limit)) != nil)
        #expect(table.lastUsed(0) == nil)
    }

    @Test("an app's stamps go when it quits")
    func removePid() {
        var table = StampTable()
        table.record(1, at: 10, pid: 1, frame: nil, space: space)
        table.record(2, at: 10, pid: 2, frame: nil, space: space)
        table.remove(pid: 1)
        #expect(table.lastUsed(1) == nil)
        #expect(table.lastUsed(2) == 10)
    }
}

@Suite("Ranking")
struct RankingTests {
    let a = TestWindow(id: 1, pid: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), z: 0)
    let b = TestWindow(id: 2, pid: 2, frame: CGRect(x: 0, y: 0, width: 200, height: 200), z: 1)
    let c = TestWindow(id: 3, pid: 3, frame: CGRect(x: 0, y: 0, width: 300, height: 300), z: 2)

    @Test("most recently used first")
    func byUse() {
        var table = StampTable()
        table.record(1, at: 10, pid: 1, frame: a.frame, space: space)
        table.record(2, at: 30, pid: 2, frame: b.frame, space: space)
        table.record(3, at: 20, pid: 3, frame: c.frame, space: space)
        #expect(ids(table.rank([a, b, c], space: space)) == [2, 3, 1])
    }

    @Test("windows never seen used go below every used one, in stacking order")
    func unusedLast() {
        var table = StampTable()
        table.record(3, at: 10, pid: 3, frame: c.frame, space: space)
        #expect(ids(table.rank([a, b, c], space: space)) == [3, 1, 2])
    }

    @Test("with no stamps at all, stacking order")
    func noStamps() {
        #expect(ids(StampTable().rank([c, a, b], space: space)) == [1, 2, 3])
    }

    @Test("with a cutoff, windows rank by their use before it, looking past a Space switch's own stamps")
    func rankBeforeCutoff() {
        var table = StampTable()
        table.record(1, at: 10, pid: 1, frame: a.frame, space: space)
        table.record(2, at: 20, pid: 2, frame: b.frame, space: space)
        table.record(1, at: 100, pid: 1, frame: a.frame, space: space)   // the arrival stamps a
        #expect(ids(table.rank([a, b], space: space)) == [1, 2])
        #expect(ids(table.rank([a, b], space: space, before: 99)) == [2, 1])
    }
}

@Suite("Tab groups")
struct TabGroupTests {
    // Window 1 is the tab that is up; 11 is a hidden tab of the same group.
    let up = TestWindow(id: 1, pid: 5, frame: CGRect(x: 10, y: 10, width: 800, height: 600), z: 1)
    let other = TestWindow(id: 2, pid: 6, frame: CGRect(x: 0, y: 0, width: 400, height: 300), z: 0)

    @Test("a row ranks by the newest use of any of its tabs")
    func hiddenTabCounts() {
        var table = StampTable()
        table.record(1, at: 10, pid: 5, frame: up.frame, space: space)
        table.record(2, at: 20, pid: 6, frame: other.frame, space: space)
        table.record(11, at: 30, pid: 5, frame: up.frame, space: space)
        #expect(ids(table.rank([up, other], space: space)) == [1, 2])
    }

    @Test("frames within 2pt match: tabs differ by a point here and there")
    func frameTolerance() {
        var table = StampTable()
        table.record(2, at: 20, pid: 6, frame: other.frame, space: space)
        table.record(11, at: 30, pid: 5, frame: up.frame.offsetBy(dx: 2, dy: -2), space: space)
        #expect(ids(table.rank([up, other], space: space)) == [1, 2])
        #expect(StampTable.sameFrame(up.frame, up.frame.insetBy(dx: 1, dy: 1)))
        #expect(!StampTable.sameFrame(up.frame, up.frame.offsetBy(dx: 3, dy: 0)))
    }

    @Test("a stamp from another Space does not count: maximized windows of one app on two Spaces share a frame")
    func otherSpaceIgnored() {
        var table = StampTable()
        table.record(2, at: 20, pid: 6, frame: other.frame, space: space)
        table.record(11, at: 30, pid: 5, frame: up.frame, space: otherSpace)
        #expect(ids(table.rank([up, other], space: space)) == [2, 1])
    }

    @Test("a window of another app with the same frame does not count")
    func otherAppIgnored() {
        var table = StampTable()
        table.record(2, at: 20, pid: 6, frame: other.frame, space: space)
        table.record(11, at: 30, pid: 99, frame: up.frame, space: space)
        #expect(ids(table.rank([up, other], space: space)) == [2, 1])
    }

    @Test("a window on screen is its own row, never another row's tab")
    func onScreenNotATab() {
        let twin = TestWindow(id: 3, pid: 5, frame: up.frame, z: 2)
        var table = StampTable()
        table.record(2, at: 20, pid: 6, frame: other.frame, space: space)
        table.record(3, at: 30, pid: 5, frame: twin.frame, space: space)
        #expect(ids(table.rank([up, other, twin], space: space)) == [3, 2, 1])
    }

    @Test("without the active Space, tab groups are not matched")
    func noSpace() {
        var table = StampTable()
        table.record(2, at: 20, pid: 6, frame: other.frame, space: space)
        table.record(11, at: 30, pid: 5, frame: up.frame, space: space)
        #expect(ids(table.rank([up, other], space: nil)) == [2, 1])
    }
}
