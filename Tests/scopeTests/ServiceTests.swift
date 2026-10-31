// The launchd side: the agent's file and reading launchctl's answer.

import Testing
@testable import scope

@Suite("Service")
struct ServiceTests {
    @Test("the agent runs this binary's `run`, at login, restarted after a crash but not after a clean exit")
    func agent() {
        let agent = Service.agent(binary: "/Users/me/.local/bin/scope", xdgConfigHome: nil)
        #expect(agent["Label"] as? String == "io.github.np25071984.scope")
        #expect(agent["ProgramArguments"] as? [String] == ["/Users/me/.local/bin/scope", "run"])
        #expect(agent["RunAtLoad"] as? Bool == true)
        #expect(agent["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
        #expect(agent["ProcessType"] as? String == "Interactive")
        #expect(agent["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(agent["EnvironmentVariables"] == nil)
    }

    @Test("XDG_CONFIG_HOME is carried into the agent, since launchd does not pass the shell's environment")
    func carriesXDG() {
        let agent = Service.agent(binary: "/b", xdgConfigHome: "/Users/me/cfg")
        #expect(agent["EnvironmentVariables"] as? [String: String] == ["XDG_CONFIG_HOME": "/Users/me/cfg"])
    }

    @Test("a relative XDG_CONFIG_HOME is ignored, as the spec requires")
    func relativeXDGIgnored() {
        #expect(Service.agent(binary: "/b", xdgConfigHome: "cfg")["EnvironmentVariables"] == nil)
    }

    @Test("launchctl print: pid and last exit code from the service's own lines, not nested blocks")
    func parseRunning() {
        let output = """
            gui/501/io.github.np25071984.scope = {
            \tactive count = 1
            \tpath = /Users/me/Library/LaunchAgents/io.github.np25071984.scope.plist
            \tstate = running
            \tpid = 4242
            \tlast exit code = (never exited)
            \tendpoints = {
            \t\tpid = 1
            \t}
            }
            """
        let state = Service.parseState(output)
        #expect(state.loaded)
        #expect(state.pid == 4242)
        #expect(state.lastExit == "(never exited)")
    }

    @Test("loaded but not running: no pid")
    func parseStopped() {
        let state = Service.parseState("x = {\n\tstate = not running\n\tlast exit code = 1\n}")
        #expect(state.loaded)
        #expect(state.pid == nil)
        #expect(state.lastExit == "1")
    }
}

@Suite("Homebrew")
struct HomebrewTests {
    @Test("a binary in the Cellar, or the service's copy in var/scope, belongs to Homebrew", arguments: [
        "/opt/homebrew/Cellar/scope/2.3.0/bin/scope",
        "/usr/local/Cellar/scope/2.3.0/bin/scope",
        "/opt/homebrew/var/scope/scope",
    ])
    func homebrewPaths(path: String) {
        #expect(Service.isHomebrewPath(path))
    }

    @Test("anywhere else, scope runs its own agent", arguments: [
        "/Users/me/.local/bin/scope",
        "/opt/scope/bin/scope",
        "/opt/homebrew/Cellar/other/1.0/bin/scope",
    ])
    func otherPaths(path: String) {
        #expect(!Service.isHomebrewPath(path))
    }

    @Test("both the current and the older brew services label are recognised")
    func labels() {
        #expect(Service.brewLabels == ["sh.brew.scope", "homebrew.mxcl.scope"])
    }
}

@Suite("Status output")
struct DurationTests {
    @Test("durations", arguments: [
        (5, "5s"), (65, "1m 5s"), (3_725, "1h 2m"), (90_061, "1d 1h"),
    ])
    func duration(seconds: Int, text: String) {
        #expect(Daemon.duration(seconds) == text)
    }
}
