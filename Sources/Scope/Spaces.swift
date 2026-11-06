// Jumping to a Space by number: the ⌃1…⌃9 shortcuts, taken over from macOS.
//
// macOS's own switch lands on a Space and then picks an app for it, which is
// often not the one last used there [F37]. scope instead focuses the window
// last used on that Space, and macOS follows it there: a switch made by
// choosing a window, which macOS leaves alone [F41].
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
    /// A window scope could jump to: where it is now, and when it was last used.
    struct Candidate: Equatable {
        let id: CGWindowID
        let pid: pid_t
        /// Every Space the window is on, as the window server says now.
        let spaces: [UInt64]
        let lastUsed: TimeInterval
    }

    enum Outcome: Equatable {
        case jump(CGWindowID)
        /// Let macOS have the key.
        case pass
    }

    /// `desktops`: the focused display's desktops in order, full-screen Spaces
    /// left out, as "Desktop N" counts them [F39].
    static func decide(number: Int, desktops: [UInt64], current: UInt64?, candidates: [Candidate]) -> Outcome {
        guard number >= 1, number <= desktops.count else { return .pass }
        let target = desktops[number - 1]
        // Already there: macOS does nothing either, and the window here keeps focus.
        if target == current { return .pass }
        // Only a window on that Space alone. One shown on every Space would be
        // focused where you are, and no switch would follow.
        let here = candidates.filter { $0.spaces == [target] }
        // A Space with no recorded use: macOS's own switch is no worse than a
        // guess, and the window list's order across Spaces is not each Space's
        // stacking order [F43].
        guard let newest = here.max(by: { $0.lastUsed < $1.lastUsed }) else { return .pass }
        return .jump(newest.id)
    }
}
