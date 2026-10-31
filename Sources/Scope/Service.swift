// The launchd side: `scope start`, `stop`, `restart` and the service half of
// `status`.
//
// Installed by build.sh, scope is its own LaunchAgent,
// ~/Library/LaunchAgents/io.github.np25071984.scope.plist, which `scope start`
// writes (or rewrites, when the binary has moved) and loads. RunAtLoad starts
// it at every login; KeepAlive restarts it after a crash but not after a clean
// exit. `launchctl` sees it like any other agent.
//
// Installed by Homebrew, the agent is homebrew.mxcl.scope and belongs to `brew
// services`, so start, stop and restart are handed to it, and `brew services
// list` never disagrees with `scope status`.

import Foundation

enum Service {
    static let ownLabel = "io.github.np25071984.scope"
    /// What `brew services` calls it: `sh.brew.` since Homebrew 7, `homebrew.mxcl.`
    /// for services started by older versions.
    static let brewLabels = ["sh.brew.scope", "homebrew.mxcl.scope"]

    static var agents: String { NSHomeDirectory() + "/Library/LaunchAgents" }
    static func plist(_ label: String) -> String { "\(agents)/\(label).plist" }
    static var logFile: String { NSHomeDirectory() + "/Library/Logs/scope.log" }
    static var domain: String { "gui/\(getuid())" }

    /// Homebrew's agent file, if `brew services` has written one.
    static var brewLabel: String? {
        brewLabels.first { FileManager.default.fileExists(atPath: plist($0)) }
    }

    /// Installed by Homebrew: the formula puts the binary in the Cellar and
    /// the service's copy in `var/scope`. `brew services` then owns the
    /// service, even before it has been started once.
    static func isHomebrewPath(_ path: String) -> Bool {
        path.contains("/Cellar/scope/") || path.hasSuffix("/var/scope/scope")
    }

    static var isHomebrew: Bool { brewLabel != nil || isHomebrewPath(CommandLine.executable) }

    /// Homebrew's agent when Homebrew owns the service, else scope's own.
    static var label: String {
        brewLabel ?? (isHomebrewPath(CommandLine.executable) ? brewLabels[0] : ownLabel)
    }

    struct State {
        var loaded = false
        var pid: Int?
        var lastExit: String?
    }

    static func state(_ label: String = Service.label) -> State {
        let (code, out) = run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        return code == 0 ? parseState(out) : State()
    }

    /// The state in `launchctl print gui/<uid>/<label>` output.
    static func parseState(_ output: String) -> State {
        var state = State(loaded: true)
        // Only the service's own top-level lines; nested blocks are indented further.
        for line in output.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            if parts[0] == "pid" { state.pid = Int(parts[1]) }
            if parts[0] == "last exit code" { state.lastExit = parts[1] }
        }
        return state
    }

    // MARK: Commands

    static func start() -> Int32 {
        if isHomebrew { return brew("start") }
        warnAboutHomebrew()
        let changed = writePlist()
        let state = state(ownLabel)

        if state.loaded && changed {
            print("launchd file changed; reloading")
            bootout()
            return bootstrap()
        }
        if !state.loaded { return bootstrap() }
        if let pid = state.pid {
            print("scope is already running (pid \(pid))")
            return 0
        }
        return launchctl(["kickstart", "\(domain)/\(ownLabel)"])
    }

    static func stop() -> Int32 {
        if isHomebrew { return brew("stop") }
        guard state(ownLabel).loaded else {
            print("scope is not running")
            return 0
        }
        // Unloads until the next login or `scope start`; the file stays, so
        // the next login starts it again.
        bootout()
        print("stopped")
        return 0
    }

    static func restart() -> Int32 {
        if isHomebrew { return brew("restart") }
        let changed = writePlist()
        let state = state(ownLabel)
        guard state.loaded else { return bootstrap() }
        if changed {
            bootout()
            return bootstrap()
        }
        let code = launchctl(["kickstart", "-k", "\(domain)/\(ownLabel)"])
        if code == 0 { print("restarted") }
        return code
    }

    /// Stops the service and removes it: the launchd file, the log and this
    /// binary. scope.conf stays, as configuration does when a package is
    /// removed.
    static func uninstall() -> Int32 {
        if isHomebrew {
            fputs("scope: installed by Homebrew; run `brew services stop scope && brew uninstall scope`, "
                + "then `rm -rf $(brew --prefix)/var/scope`\n", stderr)
            return 1
        }
        if state(ownLabel).loaded { bootout() }
        let binary = CommandLine.executable
        var removed: [String] = []
        for path in [plist(ownLabel), logFile, binary] where FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
                removed.append(path)
            } catch {
                fputs("scope: cannot remove \(path): \(error.localizedDescription)\n", stderr)
            }
        }
        for path in removed { print("removed \(path)") }
        print("kept \(Config.path), if there is one")
        print("Remove \"scope\" from System Settings → Privacy & Security → Accessibility by hand.")
        return 0
    }

    // MARK: launchd

    /// The agent's file for this binary. Returns whether it had to be written.
    @discardableResult
    static func writePlist() -> Bool {
        let agent = agent(
            binary: CommandLine.executable,
            xdgConfigHome: ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"])
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: agent, format: .xml, options: 0)
        else { return false }

        let path = plist(ownLabel)
        if FileManager.default.contents(atPath: path) == data { return false }
        try? FileManager.default.createDirectory(atPath: agents, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: data)
        print("wrote \(path)")
        return true
    }

    /// The agent's launchd file, as a property list.
    static func agent(binary: String, xdgConfigHome: String?) -> [String: Any] {
        var agent: [String: Any] = [
            "Label": ownLabel,
            "ProgramArguments": [binary, "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logFile,
            "StandardErrorPath": logFile,
        ]
        // launchd does not pass on the shell's environment; carry the one
        // variable that decides where scope.conf is.
        if let xdgConfigHome, xdgConfigHome.hasPrefix("/") {
            agent["EnvironmentVariables"] = ["XDG_CONFIG_HOME": xdgConfigHome]
        }
        return agent
    }

    private static func bootstrap() -> Int32 {
        // bootout returns before launchd has finished letting go, and a
        // bootstrap that comes too soon fails with an I/O error.
        var code: Int32 = 0
        var out = ""
        for _ in 0..<15 {
            (code, out) = run("/bin/launchctl", ["bootstrap", domain, plist(ownLabel)])
            if code == 0 {
                print("started")
                return 0
            }
            usleep(200_000)
        }
        fputs(out, stderr)
        return code
    }

    private static func bootout() {
        _ = run("/bin/launchctl", ["bootout", "\(domain)/\(ownLabel)"])
        for _ in 0..<25 where state(ownLabel).loaded { usleep(100_000) }
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let (code, out) = run("/bin/launchctl", args)
        if code != 0 { fputs(out, stderr) }
        return code
    }

    // MARK: Homebrew

    private static func brew(_ command: String) -> Int32 {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            fputs("scope: installed by Homebrew, but brew was not found\n", stderr)
            return 1
        }
        let (code, out) = run(brew, ["services", command, "scope"])
        print(out, terminator: "")
        return code
    }

    /// Two copies would both take ⌘Tab.
    private static func warnAboutHomebrew() {
        for label in brewLabels where state(label).loaded {
            fputs("warning: Homebrew's scope service (\(label)) is also loaded; "
                + "run `brew services stop scope`\n", stderr)
        }
    }

    // MARK: Processes

    /// Runs a program to completion; stdout and stderr together.
    static func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (127, "\(path): \(error.localizedDescription)\n") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
