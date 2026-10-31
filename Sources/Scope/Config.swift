// scope.conf: the only place settings live.
//
//   # comments run to the end of the line
//   modifier = cmd     # cmd | alt | ctrl
//   mouse    = true
//   refocus  = true
//   trace    = false
//
// Read at startup and on `scope reload` (SIGHUP). Scope never writes it. A
// missing file, a missing key or a bad value falls back to the default, and
// every problem is kept as a warning for the log and `scope status`.

import CoreGraphics
import Foundation

enum Modifier: String, CaseIterable {
    case cmd, alt, ctrl

    var flags: CGEventFlags {
        switch self {
        case .cmd: return .maskCommand
        case .alt: return .maskAlternate
        case .ctrl: return .maskControl
        }
    }
}

struct Config: Equatable {
    var modifier = Modifier.cmd
    var mouse = true
    var refocus = true
    var trace = false

    /// `$XDG_CONFIG_HOME/scope/scope.conf`, else `~/.config/scope/scope.conf`.
    static var path: String {
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? ""
        let base = env.hasPrefix("/") ? env : NSHomeDirectory() + "/.config"
        return base + "/scope/scope.conf"
    }

    /// The file's settings, and what was wrong with it.
    static func load(from path: String = Config.path) -> (Config, [String]) {
        guard FileManager.default.fileExists(atPath: path) else { return (Config(), []) }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return (Config(), ["\(path): cannot be read; using defaults"])
        }
        return parse(text, name: path)
    }

    static func parse(_ text: String, name: String = "scope.conf") -> (Config, [String]) {
        var config = Config()
        var warnings: [String] = []

        for (n, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let at = "\(name):\(n + 1)"

            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].isEmpty else {
                warnings.append("\(at): expected `key = value`, got `\(line)`")
                continue
            }
            let (key, value) = (parts[0].lowercased(), parts[1])

            func bool() -> Bool? {
                switch value.lowercased() {
                case "true", "yes", "on", "1": return true
                case "false", "no", "off", "0": return false
                default:
                    warnings.append("\(at): \(key) must be true or false, got `\(value)`")
                    return nil
                }
            }

            switch key {
            case "modifier":
                if let m = Modifier(rawValue: value.lowercased()) {
                    config.modifier = m
                } else {
                    warnings.append("\(at): modifier must be cmd, alt or ctrl, got `\(value)`")
                }
            case "mouse": if let b = bool() { config.mouse = b }
            case "refocus": if let b = bool() { config.refocus = b }
            case "trace": if let b = bool() { config.trace = b }
            default: warnings.append("\(at): unknown setting `\(key)`")
            }
        }
        return (config, warnings)
    }

    /// As it would be written in scope.conf.
    var lines: [String] {
        [
            "modifier = \(modifier.rawValue)",
            "mouse    = \(mouse)",
            "refocus  = \(refocus)",
            "trace    = \(trace)",
        ]
    }
}
