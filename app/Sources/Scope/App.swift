// The app shell: menu bar item, preferences, the Accessibility permission, and
// launch at login.

import AppKit
import ServiceManagement

enum Modifier: String, CaseIterable {
    case cmd, alt, ctrl

    var flags: CGEventFlags {
        switch self {
        case .cmd: return .maskCommand
        case .alt: return .maskAlternate
        case .ctrl: return .maskControl
        }
    }

    var title: String {
        switch self {
        case .cmd: return "⌘ Command — replaces the system switcher"
        case .alt: return "⌥ Option — runs alongside it"
        case .ctrl: return "⌃ Control"
        }
    }
}

/// Preferences, in the app's user defaults. Also settable from a terminal,
/// e.g. `defaults write io.github.np25071984.scope modifier alt`, then quit
/// and reopen Scope.
struct Settings {
    private static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            "enabled": true, "modifier": Modifier.cmd.rawValue, "mouse": true,
            "refocus": true, "showMenuBarIcon": true, "trace": false,
        ])
    }

    static var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    static var modifier: Modifier {
        get { Modifier(rawValue: defaults.string(forKey: "modifier") ?? "") ?? .cmd }
        set { defaults.set(newValue.rawValue, forKey: "modifier") }
    }
    static var mouse: Bool {
        get { defaults.bool(forKey: "mouse") }
        set { defaults.set(newValue, forKey: "mouse") }
    }
    static var refocus: Bool {
        get { defaults.bool(forKey: "refocus") }
        set { defaults.set(newValue, forKey: "refocus") }
    }
    static var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: "showMenuBarIcon") }
        set { defaults.set(newValue, forKey: "showMenuBarIcon") }
    }
    static var trace: Bool {
        get { defaults.bool(forKey: "trace") }
        set { defaults.set(newValue, forKey: "trace") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let switcher = Switcher()
    private var statusItem: NSStatusItem?
    private var started = false
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        Log.tracing = Settings.trace
        updateStatusItem()

        if AXIsProcessTrusted() {
            start()
        } else {
            askForPermission()
        }
    }

    // Opening Scope again while it runs brings back a hidden menu bar icon,
    // which is the only way back to the menu once it is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !Settings.showMenuBarIcon {
            Settings.showMenuBarIcon = true
            updateStatusItem()
        }
        return false
    }

    private func start() {
        guard !started else { return }
        guard switcher.start() else {
            // Trusted, yet the tap was refused: the grant belongs to a build
            // with a different signature. See README, "Developing".
            Log.warn("event tap refused despite Accessibility permission")
            askForPermission()
            return
        }
        started = true
        applySettings()
    }

    private func applySettings() {
        switcher.configure(
            modifier: Settings.modifier.flags, mouse: Settings.mouse, enabled: Settings.enabled)
        switcher.refocusEnabled = Settings.refocus
        Log.tracing = Settings.trace
    }

    // MARK: Accessibility permission
    //
    // Without it the taps cannot be created and nothing works. Hammerspoon
    // failed silently here; Scope says so, opens the right pane, and starts
    // the moment the grant appears.

    private func askForPermission() {
        let alert = NSAlert()
        alert.messageText = "Scope needs Accessibility permission"
        alert.informativeText = """
            Scope reads window titles and intercepts ⌘Tab through Accessibility. \
            Enable Scope in System Settings → Privacy & Security → Accessibility. \
            Scope starts on its own as soon as it is allowed.

            If Scope is already listed and enabled, remove it with the minus \
            button and add it again: the entry belongs to an earlier build.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        // Polled, because macOS posts nothing when the grant changes. The timer
        // runs in the modal mode too, so granting dismisses the alert.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard AXIsProcessTrusted() else { return }
            self?.permissionTimer?.invalidate()
            self?.permissionTimer = nil
            NSApp.abortModal()
            self?.start()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Adds Scope to the list so there is a switch to flip.
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } else if response == .alertSecondButtonReturn {
            NSApp.terminate(nil)
        }
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        guard Settings.showMenuBarIcon else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.stack", accessibilityDescription: "Scope")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // Rebuilt on every open so check marks never drift from the settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !started {
            menu.addItem(item("Grant Accessibility Permission…", #selector(grantPermission)))
            menu.addItem(.separator())
        }

        menu.addItem(item("Enabled", #selector(toggleEnabled), on: Settings.enabled))
        menu.addItem(.separator())

        let modifiers = NSMenu()
        for m in Modifier.allCases {
            let entry = item(m.title, #selector(chooseModifier(_:)), on: Settings.modifier == m)
            entry.representedObject = m.rawValue
            modifiers.addItem(entry)
        }
        let modifierItem = NSMenuItem(title: "Modifier", action: nil, keyEquivalent: "")
        modifierItem.submenu = modifiers
        menu.addItem(modifierItem)

        menu.addItem(item("Pointer Support", #selector(toggleMouse), on: Settings.mouse))
        menu.addItem(item("Refocus After Space Switch", #selector(toggleRefocus), on: Settings.refocus))
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin),
                          on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Trace to System Log", #selector(toggleTrace), on: Settings.trace))
        menu.addItem(item("Hide Menu Bar Icon", #selector(hideIcon)))
        menu.addItem(.separator())

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let about = NSMenuItem(title: "Scope \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Quit Scope", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, on: Bool? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        if let on { entry.state = on ? .on : .off }
        return entry
    }

    @objc private func grantPermission() { askForPermission() }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        applySettings()
    }

    @objc private func chooseModifier(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = Modifier(rawValue: raw) else { return }
        Settings.modifier = m
        applySettings()
    }

    @objc private func toggleMouse() {
        Settings.mouse.toggle()
        applySettings()
    }

    @objc private func toggleRefocus() {
        Settings.refocus.toggle()
        applySettings()
    }

    @objc private func toggleTrace() {
        Settings.trace.toggle()
        applySettings()
    }

    @objc private func hideIcon() {
        let alert = NSAlert()
        alert.messageText = "Hide the menu bar icon?"
        alert.informativeText = "Open Scope again from Applications or Spotlight to bring it back."
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Settings.showMenuBarIcon = false
        updateStatusItem()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
