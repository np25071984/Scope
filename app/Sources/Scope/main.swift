import AppKit

// `Scope --list` prints the current Space's windows and how long reading them
// took, then exits: the Phase 1 check from REWORK.md, kept as a diagnostic.
// Run it from a terminal that has Accessibility permission, or as
// Scope.app/Contents/MacOS/Scope --list once Scope has it.
if CommandLine.arguments.contains("--list") {
    print("single-window focus: \(SkyLight.canFocusSingleWindow ? "available" : "MISSING, will activate whole apps")")
    print("active Space: \(SkyLight.activeSpace().map(String.init) ?? "MISSING, tab groups rank by their own tab only")")
    guard AXIsProcessTrusted() else {
        print("No Accessibility permission for this process; titles and subroles are unavailable.")
        exit(1)
    }
    WindowLister.configureTimeout()
    let lister = WindowLister()
    for run in 1...3 {
        let t0 = DispatchTime.now()
        let windows = lister.currentSpace()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        print(String(format: "run %d: %d windows in %.1fms", run, windows.count, ms))
        if run == 1 {
            for (i, w) in windows.enumerated() {
                let app = NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "?"
                print("  \(i + 1). [\(w.id)] \(app): \(w.title)")
            }
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
