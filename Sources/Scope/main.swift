// scope: a ⌘Tab switcher for the windows on the current Space, run as a
// launchd service and controlled from the command line.

import AppKit

let usage = """
    usage: scope <command>

      start          start the service (writes its launchd file if needed)
      stop           stop it; it starts again at the next login
      restart        restart it
      reload         re-read scope.conf without restarting
      status         is it running, does it have permission, which settings
      logs [--last <time>]
                     follow the service's log, or show the last <time> (e.g. 1h)
      list [--direct]
                     the windows ⌘Tab would show, most recent first;
                     --direct reads them here instead of asking the service
      run            the service itself, in the foreground (what launchd runs)
      uninstall      stop the service and remove scope; scope.conf is kept
      version        print the version

    config: \(Config.path)
    """

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    fputs("scope: \(message)\n", stderr)
    exit(code)
}

func notRunning() -> Never {
    fail("the service is not running; start it with `scope start`", 3)
}

switch args.first {
case "run":
    Daemon().run()

case "start":
    let code = Service.start()
    guard code == 0 else { exit(code) }
    awaitService()

case "stop":
    exit(Service.stop())

case "restart":
    let code = Service.restart()
    guard code == 0 else { exit(code) }
    awaitService()

case "reload":
    guard let answer = Control.request("reload") else { notRunning() }
    print("reloaded")
    print(answer, terminator: "")

case "status":
    let label = Service.label
    let state = Service.state(label)
    let how = Service.isHomebrew ? "brew services" : "launchd"
    print("service:       \(label) (\(how), \(Service.plist(label)))")
    switch (state.loaded, state.pid) {
    case (true, let pid?): print("state:         running, pid \(pid)")
    case (true, nil): print("state:         loaded, not running (last exit \(state.lastExit ?? "?"))")
    default: print("state:         not loaded")
    }
    guard let answer = Control.request("status") else {
        print("\nThe service is not answering. Start it with `scope start`; see `scope logs`.")
        exit(3)
    }
    print(answer, terminator: "")
    exit(answer.contains("NOT ALLOWED") ? 4 : 0)

case "logs":
    var command = ["/usr/bin/log", "stream", "--style", "compact"]
    if args.count >= 3, args[1] == "--last" {
        command = ["/usr/bin/log", "show", "--style", "compact", "--last", args[2]]
    } else if args.count > 1 {
        fail("usage: scope logs [--last <time>]", 2)
    }
    command += ["--predicate", "subsystem == \"\(Log.subsystem)\" AND process == \"scope\""]
    let argv = command.map { strdup($0) } + [nil]
    execv(command[0], argv)
    fail("cannot run /usr/bin/log: \(String(cString: strerror(errno)))")

case "list":
    if args.dropFirst().contains("--direct") {
        listDirect()
    } else {
        guard let answer = Control.request("list") else {
            fail("the service is not running; start it with `scope start`, "
                + "or read the windows here with `scope list --direct`", 3)
        }
        print(answer, terminator: "")
    }

case "uninstall":
    exit(Service.uninstall())

case "version", "--version", "-v":
    print("scope \(version)")

case nil, "help", "--help", "-h":
    print(usage)

default:
    fputs(usage + "\n", stderr)
    fail("unknown command `\(args[0])`", 2)
}

/// Waits for a just-started service to answer, then says what it still needs.
func awaitService() -> Never {
    // A restarted service needs a moment before the old one stops answering.
    usleep(300_000)
    for _ in 0..<30 {
        if let status = Control.request("status", timeout: 1) {
            if status.contains("NOT ALLOWED") {
                print("""

                    scope needs Accessibility permission. In the window that opens, turn on \
                    "scope" (or add \(CommandLine.executable) with +). It starts by itself \
                    within \(Int(Daemon.permissionInterval)) seconds of being allowed.
                    """)
                _ = Service.run("/usr/bin/open", [
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                ])
            }
            exit(0)
        }
        usleep(100_000)
    }
    fail("started, but the service is not answering; see `scope logs` and \(Service.logFile)")
}

/// Reads the current Space's windows in this process: stacking order, no
/// recency, and the permission is the terminal's.
func listDirect() -> Never {
    print("single-window focus: \(SkyLight.canFocusSingleWindow ? "available" : "MISSING, will activate whole apps")")
    print("active Space: \(SkyLight.activeSpace().map(String.init) ?? "MISSING, tab groups rank by their own tab only")")
    guard AXIsProcessTrusted() else {
        fail("this terminal has no Accessibility permission, so titles are unavailable. "
            + "Ask the service instead: `scope list`")
    }
    WindowLister.configureTimeout()
    let lister = WindowLister()
    for run in 1...3 {
        let t0 = DispatchTime.now()
        let windows = lister.currentSpace()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        print(String(format: "run %d: %d windows in %.1fms (stacking order)", run, windows.count, ms))
        if run == 1 {
            for (i, w) in windows.enumerated() {
                let app = NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "?"
                print("  \(i + 1). [\(w.id)] \(app): \(w.title)")
            }
        }
    }
    exit(0)
}
