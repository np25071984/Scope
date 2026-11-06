// The record of when each window was last used, and the order it gives.
//
// Pure: no Accessibility, no lock, no clock. Recency feeds it from the
// recency thread and holds the lock; the tests feed it directly.

import CoreGraphics
import Foundation

/// What ranking needs to know about a window.
protocol Rankable {
    var id: CGWindowID { get }
    var pid: pid_t { get }
    /// Global coordinates, top-left origin.
    var frame: CGRect { get }
    /// Position in the window server's stacking order; 0 is frontmost.
    var z: Int { get }
}

struct StampTable {
    /// How far back `rank(_:before:)` and `lastUsed(_:before:)` can look past
    /// a window's latest stamp: each stamp keeps the newest use at least this
    /// much older than itself, which reaches past the burst of stamps one
    /// switch fires.
    static let history: TimeInterval = 1
    /// Past this many stamps, only the newest `keep` survive. A window
    /// untouched that long ranks by stacking order just as well.
    static let limit = 1024
    static let keep = 512
    /// Frames this close belong to the same tab group.
    static let frameTolerance: CGFloat = 2

    struct Stamp: Equatable {
        let at: TimeInterval
        let previous: TimeInterval?
        let pid: pid_t
        let frame: CGRect?
        let space: UInt64?

        /// This stamp as it stood at `cutoff`, or nil if the window had not
        /// been used by then as far as the stamp remembers.
        func before(_ cutoff: TimeInterval) -> Stamp? {
            if at < cutoff { return self }
            guard let previous, previous < cutoff else { return nil }
            return Stamp(at: previous, previous: nil, pid: pid, frame: frame, space: space)
        }
    }

    /// What reported the window as focused.
    enum Source: String {
        case activated
        case deactivated
        case focusChanged = "focus changed"
        case startup
    }

    /// Whether a report from `source` is a use of the window. An app just
    /// activated can still name the window it had focused on the Space it
    /// left, which is off screen, and stamping it would rank that window above
    /// the one really used last there. A deactivation counts off screen too:
    /// it fires as the Space you leave slides away, and names the window you
    /// were in.
    static func counts(_ source: Source, onScreen: @autoclosure () -> Bool) -> Bool {
        source == .deactivated || onScreen()
    }

    private(set) var stamps: [CGWindowID: Stamp] = [:]
    /// The latest activation recorded: which app, and when.
    private(set) var lastActivation: (pid: pid_t, at: TimeInterval)?

    /// The window was used at `now`, as reported by `source`.
    ///
    /// Switching apps activates one and deactivates the other, in either
    /// order [F38]. A deactivation means the window was used until the other app
    /// took over, so one that arrives after another app's activation is
    /// recorded just before that activation, not when it arrived. Otherwise
    /// the app left would rank above the app switched to.
    mutating func record(
        _ id: CGWindowID, at now: TimeInterval, pid: pid_t, frame: CGRect?, space: UInt64?,
        as source: Source = .focusChanged
    ) {
        var now = now
        switch source {
        case .activated:
            lastActivation = (pid, now)
        case .deactivated:
            if let taken = lastActivation, taken.pid != pid, taken.at > (stamps[id]?.at ?? -.infinity) {
                now = min(now, taken.at.nextDown)
            }
        case .focusChanged, .startup:
            break
        }
        // A window is stamped several times in a burst -- activated, focus
        // changed, deactivated -- so the use kept behind the latest is the
        // newest one from before the burst, not simply the one replaced.
        let previous = stamps[id].flatMap { now - $0.at >= Self.history ? $0.at : $0.previous }
        stamps[id] = Stamp(at: now, previous: previous, pid: pid, frame: frame, space: space)
        if stamps.count > Self.limit {
            let newest = stamps.sorted { $0.value.at > $1.value.at }.prefix(Self.keep)
            stamps = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
    }

    /// The app quit; its windows are gone.
    mutating func remove(pid: pid_t) {
        stamps = stamps.filter { $0.value.pid != pid }
    }

    /// When the window was last used before `cutoff`, or nil if it was not
    /// seen used.
    func lastUsed(_ id: CGWindowID, before cutoff: TimeInterval = .infinity) -> TimeInterval? {
        stamps[id]?.before(cutoff)?.at
    }

    /// `windows` most recently used first. Windows never seen used were last
    /// used before scope started, so they go below every stamped one, in
    /// stacking order, which is the window server's own record of use.
    ///
    /// A row ranks by the newest use across its tab group: any stamped window
    /// of the same app, on `space` when it was stamped, that is now off screen
    /// and had the row's frame. That covers a tab used and then switched away
    /// from by keyboard, and a tab that was closed -- both rank the row that
    /// took their place. The Space matters because maximized windows of one
    /// app on two Spaces share a frame too. Without a Space, tab groups are
    /// not matched at all.
    ///
    /// With a `cutoff`, windows rank by their use before it, to look past an
    /// event that itself stamped windows, such as a Space switch.
    func rank<W: Rankable>(_ windows: [W], space: UInt64?, before cutoff: TimeInterval = .infinity) -> [W] {
        let stamps = self.stamps.compactMapValues { $0.before(cutoff) }
        let onScreen = Set(windows.map(\.id))

        func usedAt(_ w: W) -> TimeInterval? {
            var best = stamps[w.id]?.at
            guard let space else { return best }
            for (id, s) in stamps where id != w.id && !onScreen.contains(id)
                && s.pid == w.pid && s.space == space && s.at > (best ?? 0)
            {
                if let f = s.frame, Self.sameFrame(f, w.frame) {
                    Log.trace("tab group: window \(w.id) ranked by \(id)")
                    best = s.at
                }
            }
            return best
        }

        return windows.map { ($0, usedAt($0)) }
            .sorted { a, b in
                switch (a.1, b.1) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.0.z < b.0.z
                }
            }
            .map(\.0)
    }

    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        let t = frameTolerance
        return abs(a.minX - b.minX) <= t && abs(a.minY - b.minY) <= t
            && abs(a.width - b.width) <= t && abs(a.height - b.height) <= t
    }
}
