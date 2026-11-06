// Jumping to a Space by number: the ⌃1…⌃9 shortcuts, taken over from macOS.
//
// macOS's own switch slides to a Space and then picks an app for it, which is
// often not the one last used there [F37], and it ignores the key while a
// swipe's slide is still running [F45]. scope switches with synthetic swipes
// instead, which land at once [F46], and then focuses the window last used on
// that Space. During a slide, a swipe back cancels it.
//
// Pure: the shortcuts come in as the preferences dictionary, the Spaces and
// windows as plain values.

import CoreGraphics
import Foundation

/// One of macOS's "Switch to Desktop N" shortcuts.
struct SpaceShortcut: Equatable {
    let code: Int64
    let modifiers: CGEventFlags
    /// 1-based, as in "Desktop 1".
    let number: Int
}

enum SpaceKeys {
    /// Symbolic hotkey ids 118 through 126 are "Switch to Desktop 1" through 9 [F42].
    static let firstHotKey = 118
    static let count = 9
    /// The modifiers a shortcut is made of. Caps Lock, the numeric-pad bit and
    /// the like are not part of it and must not stop a match.
    static let modifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

    static var preferencesPath: String {
        NSHomeDirectory() + "/Library/Preferences/com.apple.symbolichotkeys.plist"
    }

    /// The shortcuts that are on, from the symbolic hotkeys preferences. One
    /// that is off, missing or malformed is left to macOS, which is to say
    /// it does nothing.
    static func parse(_ preferences: [String: Any]) -> [SpaceShortcut] {
        guard let keys = preferences["AppleSymbolicHotKeys"] as? [String: Any] else { return [] }
        return (0..<count).compactMap { i in
            guard let entry = keys[String(firstHotKey + i)] as? [String: Any],
                  (entry["enabled"] as? Bool) == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Int], parameters.count == 3
            else { return nil }
            let modifiers = CGEventFlags(rawValue: UInt64(parameters[2])).intersection(modifierMask)
            return SpaceShortcut(code: Int64(parameters[1]), modifiers: modifiers, number: i + 1)
        }
    }

    static func load(from path: String = preferencesPath) -> [SpaceShortcut] {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let preferences = plist as? [String: Any]
        else { return [] }
        return parse(preferences)
    }

    /// The Space a key press asks for, if it is one of the shortcuts exactly:
    /// ⌃⇧2 is not ⌃2.
    static func match(code: Int64, flags: CGEventFlags, in shortcuts: [SpaceShortcut]) -> Int? {
        let pressed = flags.intersection(modifierMask)
        return shortcuts.first { $0.code == code && $0.modifiers == pressed }?.number
    }
}

enum SpaceJump {
    /// A window scope could focus on arrival: where it is now, and when it was last used.
    struct Candidate: Equatable {
        let id: CGWindowID
        let pid: pid_t
        /// Every Space the window is on, as the window server says now.
        let spaces: [UInt64]
        let lastUsed: TimeInterval
    }

    /// What a ⌃N press comes to.
    enum Plan: Equatable {
        /// Swipe `steps` Spaces over to `space`, then focus `window` there, if
        /// one was seen used.
        case swipe(SwipeDirection, steps: Int, to: UInt64, window: CGWindowID?)
        /// A slide is running away from the Space asked for: one swipe back cancels it.
        case cancel(SwipeDirection)
        /// A slide is running and macOS ignores the key until it lands, so
        /// synthetic swipes take over from it, whatever `animate` says: `steps`
        /// more toward `space`, none if the slide is already going there.
        case redirect(SwipeDirection, steps: Int, to: UInt64, window: CGWindowID?)
        /// A slide is running and which way is unknown: decide once it lands.
        case wait
        /// Let macOS have the key.
        case pass
    }

    /// How often to look again while a slide is running: once a frame.
    static let settlePoll: TimeInterval = 1.0 / 60
    /// Stop waiting after this long and decide anyway. A swipe's slide ends in
    /// well under a second; this is for a screen that never looks settled,
    /// such as a case scope has not met.
    static let settleLimit: TimeInterval = 1.5

    /// Whether the display has finished switching: no window on screen
    /// belongs to another of its Spaces alone. While a slide is running, the
    /// current Space has not changed yet, and the windows of the Space it is
    /// heading for are already on screen [F45]. `onScreen`: the Spaces of
    /// each window on screen. `spaces`: every Space of the display, so
    /// another display's windows do not count.
    static func settled(current: UInt64, spaces: [UInt64], onScreen: [[UInt64]]) -> Bool {
        !onScreen.contains { $0.count == 1 && $0[0] != current && spaces.contains($0[0]) }
    }

    /// Which way a running slide is heading: toward the neighbour whose
    /// windows are on screen. Nil if neither or both are, which leaves it
    /// unknown.
    static func heading(current: UInt64, spaces: [UInt64], onScreen: [[UInt64]]) -> SwipeDirection? {
        guard let i = spaces.firstIndex(of: current) else { return nil }
        let shown = Set(onScreen.compactMap { $0.count == 1 ? $0[0] : nil })
        let left = i > 0 && shown.contains(spaces[i - 1])
        let right = i + 1 < spaces.count && shown.contains(spaces[i + 1])
        if left == right { return nil }
        return left ? .left : .right
    }

    /// A swipe's direction from the sign of its fling or progress: positive is
    /// right, the other way with natural scrolling on [F47].
    static func direction(of value: Double, natural: Bool) -> SwipeDirection {
        (value > 0) != natural ? .right : .left
    }

    /// `spaces`: every Space of the focused display in Mission Control order,
    /// full-screen ones too, which a swipe steps through. `desktops`: the
    /// ones "Desktop N" counts [F39]. `heading`: nil when the display has
    /// settled, else where its slide is going, `.some(nil)` if that is unknown.
    static func plan(number: Int, spaces: [UInt64], desktops: [UInt64], current: UInt64,
                     sliding heading: SwipeDirection??, candidates: [Candidate]) -> Plan {
        guard number >= 1, number <= desktops.count else { return .pass }
        let target = desktops[number - 1]
        guard let from = spaces.firstIndex(of: current), let to = spaces.firstIndex(of: target) else { return .pass }
        // Only a window on that Space alone: one shown on every Space is no
        // record of use there.
        let window = candidates.filter { $0.spaces == [target] }.max { $0.lastUsed < $1.lastUsed }?.id
        let direction: SwipeDirection = to > from ? .right : .left
        let distance = abs(to - from)
        if let heading {
            // The current Space is still the one being left.
            guard let heading else { return .wait }
            if target == current { return .cancel(heading.reversed) }
            // The same way: the slide already covers the first step. Back the
            // other way: one more step undoes the slide first [F46].
            let steps = direction == heading ? distance - 1 : distance + 1
            return .redirect(direction, steps: steps, to: target, window: window)
        }
        guard target != current else { return .pass }
        return .swipe(direction, steps: distance, to: target, window: window)
    }

    /// The Spaces a multi-step swipe passes on the way, which macOS may
    /// report arriving at before the last.
    static func between(_ a: UInt64, _ b: UInt64, in spaces: [UInt64]) -> Set<UInt64> {
        guard let i = spaces.firstIndex(of: a), let j = spaces.firstIndex(of: b), abs(i - j) > 1 else { return [] }
        return Set(spaces[(min(i, j) + 1)..<max(i, j)])
    }
}
