// `scope run`: the switcher itself, as launchd runs it.
//
// No Dock icon, no menu bar, no windows other than the overlay. Settings come
// from scope.conf; SIGHUP or `scope reload` re-reads it, SIGTERM quits.
//
// Accessibility: macOS gives the permission to whatever process launched
// Scope. Started by launchd, that is this binary, identified by its path and
// signature. Without the permission nothing works, so the service asks once,
// which adds it to the list in System Settings, then checks every 5 seconds and
// starts the moment it is allowed.

import AppKit

final class Daemon {
    private let switcher = Switcher()
    private var config = Config()
    private var warnings: [String] = []
    private var running = false
    private var permissionTimer: Timer?
    private var signals: [DispatchSourceSignal] = []
    private let launched = Date()

    static let permissionInterval: TimeInterval = 5

    func run() -> Never {
        if Control.request("ping", timeout: 1) != nil {
            fputs("scope: already running (\(Control.path))\n", stderr)
            exit(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        reload()
        guard Control.serve({ [weak self] in self?.answer($0) ?? "" }) else {
            fputs("scope: cannot open the control socket at \(Control.path)\n", stderr)
            exit(1)
        }
        handleSignals()
        Log.info("scope \(version) started, pid \(getpid()), config \(Config.path)")

        if AXIsProcessTrusted() {
            start()
        } else {
            Log.warn("no Accessibility permission yet; checking every \(Int(Self.permissionInterval))s")
            // Adds Scope to the list in System Settings, so there is a switch to flip.
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            waitForPermission()
        }

        app.run()
        exit(0)
    }

    // MARK: Lifecycle

    private func start() {
        guard !running else { return }
        guard switcher.start() else {
            // Trusted, yet the tap was refused: the entry in System Settings
            // belongs to another build. Keep checking; re-adding it fixes this.
            Log.warn("event tap refused despite Accessibility permission; "
                + "remove scope from the Accessibility list and add it again")
            waitForPermission()
            return
        }
        running = true
        permissionTimer?.invalidate()
        permissionTimer = nil
        apply()
        Log.info("switcher running")
    }

    private func waitForPermission() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(
            withTimeInterval: Self.permissionInterval, repeats: true
        ) { [weak self] _ in
            guard AXIsProcessTrusted() else { return }
            Log.info("Accessibility permission granted")
            self?.permissionTimer?.invalidate()
            self?.permissionTimer = nil
            self?.start()
        }
    }

    private func reload() {
        (config, warnings) = Config.load()
        for w in warnings { Log.warn(w) }
        apply()
    }

    private func apply() {
        Log.tracing = config.trace
        guard running else { return }
        switcher.configure(modifier: config.modifier.flags, mouse: config.mouse)
        switcher.refocusEnabled = config.refocus
    }

    private func handleSignals() {
        for (sig, action) in [
            (SIGHUP, { [weak self] in
                Log.info("SIGHUP: reloading \(Config.path)")
                self?.reload()
            }),
            (SIGTERM, { Self.quit("SIGTERM") }),
            (SIGINT, { Self.quit("SIGINT") }),
        ] as [(Int32, () -> Void)] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler(handler: action)
            source.resume()
            signals.append(source)
        }
    }

    private static func quit(_ why: String) {
        Log.info("\(why): quitting")
        Control.removeSocket()
        exit(0)
    }

    // MARK: Control socket

    /// Called on the socket's thread; everything that touches the switcher
    /// runs on the main thread, as it always does.
    private func answer(_ command: String) -> String {
        switch command {
        case "ping": return "pong\n"
        case "status": return DispatchQueue.main.sync { status() }
        case "list": return DispatchQueue.main.sync { list() }
        case "reload":
            return DispatchQueue.main.sync {
                Log.info("reload requested")
                reload()
                return settings()
            }
        default: return "unknown command: \(command)\n"
        }
    }

    private func status() -> String {
        let up = Int(Date().timeIntervalSince(launched))
        var out = [
            "version:       \(version)",
            "pid:           \(getpid())",
            "uptime:        \(Self.duration(up))",
            "binary:        \(CommandLine.executable)",
            "accessibility: \(AXIsProcessTrusted() ? "allowed" : "NOT ALLOWED (System Settings → Privacy & Security → Accessibility)")",
            "switcher:      \(running ? "running" : "waiting for Accessibility permission")",
            "focus:         \(SkyLight.canFocusSingleWindow ? "single window" : "whole app (private calls missing)")",
            "spaces:        \(SkyLight.activeSpace().map { "active Space \($0)" } ?? "unavailable (private call missing)")",
        ]
        out.append("")
        out.append(settings())
        return out.joined(separator: "\n")
    }

    private func settings() -> String {
        let exists = FileManager.default.fileExists(atPath: Config.path)
        var out = ["config:        \(Config.path)\(exists ? "" : " (not found; defaults)")"]
        out += config.lines.map { "  " + $0 }
        out += warnings.map { "  warning: " + $0 }
        return out.joined(separator: "\n") + "\n"
    }

    private func list() -> String {
        guard running else { return "switcher not running: waiting for Accessibility permission\n" }
        let t0 = DispatchTime.now()
        let windows = switcher.currentWindows()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        let now = ProcessInfo.processInfo.systemUptime

        var out = [String(format: "%d windows on this Space, most recent first (%.1fms)", windows.count, ms)]
        for (i, w) in windows.enumerated() {
            let app = NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "pid \(w.pid)"
            let used = switcher.lastUsed(w).map { Self.duration(Int(now - $0)) + " ago" } ?? "not seen used"
            let title = w.title.isEmpty ? "(untitled)" : w.title
            out.append(String(format: "%3d. ", i + 1) + "\(app) — \(title)  [\(w.id), \(used)]")
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        if seconds < 86400 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return "\(seconds / 86400)d \(seconds % 86400 / 3600)h"
    }
}
