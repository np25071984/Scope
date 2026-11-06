# Changelog

## 2.3.1 — 2026-11-02

Switching back to a Space no longer focuses another app's window there when that app was the one you were using on the Space you left. Upgrade with `brew upgrade scope` and `brew services restart scope`, or run `install.sh` again; the Accessibility permission is kept.

## 2.3.0 — 2026-10-31

scope can be installed with Homebrew: `brew tap np25071984/scope https://github.com/np25071984/Scope`, `brew trust np25071984/scope`, `brew install scope`, `brew services start scope`. The formula installs the signed release, and its service runs a copy at a path that stays the same across versions, so `brew upgrade` keeps the Accessibility permission. `scope start`, `stop` and `restart` hand over to `brew services` when Homebrew installed scope, and `scope status` recognises Homebrew 7's service label, `sh.brew.scope`. When scope needs the permission, it names the file to allow: the copy the service runs.

## 2.2.0 — 2026-10-31

scope is now installed from a prebuilt release, with no sources needed: `curl -fsSL https://raw.githubusercontent.com/np25071984/Scope/main/install.sh | sh`. Running it again upgrades, and the permission is kept. Releases run on Apple Silicon and Intel, and are signed with scope's release certificate, which the installer checks. New `scope uninstall` removes scope without the sources. `./build.sh --install` is now for working on scope.

Upgrading from a source build: run the installer, then turn on **scope** in Accessibility again, since a release is signed with a different certificate from your local builds.

## 2.1.0 — 2026-10-31

scope is now a single `scope` binary run as a launchd service instead of Scope.app. Install with `./build.sh --install`, which puts it in `~/.local/bin` by default (`--prefix` to change), starts it, and has launchd start it at login and restart it after a crash. The menu bar is gone: settings move from user defaults to `~/.config/scope/scope.conf`, and `scope start | stop | restart | reload | status | logs | list` replace the menu. `scope list` now asks the running service, so it shows the switcher's own order with each window's last use, and no longer needs the terminal to have Accessibility permission. The *Enabled* switch is gone (`scope stop`), and so are *Launch at Login* and *Hide Menu Bar Icon*. The service checks for Accessibility permission every 5 seconds instead of showing an alert. `build.sh` now also finds a self-signed certificate that is not marked as trusted, which it used to skip, falling back to ad-hoc signing.

Upgrading from 2.0.x: quit Scope.app, delete `/Applications/Scope.app`, run `./build.sh --install`, and grant **scope** Accessibility permission. Settings are not carried over; set them again in `scope.conf`.

## 2.0.1 — 2026-10-31

Switching to a Space now focuses the window you last used there, even when the app you left also has a window on that Space. macOS focuses that app's window on arrival, and scope used to treat it as your choice and leave it. scope now recognises this case because no app was activated around the switch, and it ranks windows by their use from before the switch, since arriving stamps the carried-over window as used. A window you pick from the Dock, a notification or Mission Control is still left alone.

## 2.0.0

First native build: Scope.app, a standalone version that needs no Hammerspoon. The releases below it were a Hammerspoon module.

## 1.2.2 — 2026-10-13

Switching back to a Space now focuses the Terminal tab you were actually working in. 1.2.1 still missed a tab switched to by keyboard, since that fires no event scope hears, so Terminal ranked as unused and VS Code took the focus. scope now records an application's focused window whenever the application loses activation, which every Space switch causes. Refocus also no longer guesses on a Space where nothing has been used since scope loaded: it used to pick an arbitrary window there, and now leaves focus alone.

## 1.2.1 — 2026-10-12

Switching back to a Space no longer focuses the wrong window when you last worked there in a tabbed app. If you used Terminal through one tab and then moved to another, scope lost track of the first, so Terminal ranked as untouched for hours and a Space switch handed focus to VS Code instead. The ⌘Tab list sank Terminal the same way. A tab group now ranks by the most recent use of any of its tabs. scope also logs a warning when its key handler runs slow enough that macOS may hand ⌘Tab to the system switcher, and the trace shows how long each list took to build.

## 1.2.0 — 2026-10-11

Switching Spaces now brings the keyboard with you. macOS often leaves the previous Space's app active on arrival, so the Terminal you were working in came back in front but unfocused, and typing went nowhere until a ⌘Tab. scope now focuses the window you last used on a Space when you switch to it and nothing there has focus. Set `refocus = false` to turn it off.

## 1.1.2 — 2026-10-10

A tabbed application you used a moment ago no longer sinks to the bottom of the switcher. The window filter ranks a tab group by the last time it saw one particular tab focused, and bringing the application forward on any other tab tells it nothing — so Terminal, left a few seconds earlier, could rank below windows untouched for minutes. scope now notes the front window of every application it sees activated, carries a row's history over when a different tab takes its place, and orders the list by that before drawing.

Added a debug trace for when the order comes out wrong anyway. `hs -c "package.loaded.scope.log.setLogLevel('debug')"` turns it on without a reload, and the Hammerspoon console then shows the list after every stage of building it, along with the events and decisions that fed each one.

## 1.1.1 — 2026-10-10

Closing the front tab of a tabbed application no longer drops the application from the switcher. The tab that came forward was never registered by the window filter, and with the closed one gone the application had no row left — Terminal with a single window of tabs simply vanished from the list. A closed window now leaves a placeholder at its place in the most-recently-used order, filled by whichever tab is up now, so the application stays where you left it.

## 1.1.0 — 2026-09-21

A quick press-and-release now reliably toggles back to the window you just came from. The filter's most-recently-used order is a cache fed by focus-change notifications, and a second press straight after the first could read it before the notification for that first switch had been processed — leaving the window you were on ranked second and the one you wanted first, so the overlay skipped past it and reaching it took a lap through the whole list. The list is now checked against `hs.window.focusedWindow()`, a live query rather than a cache, and the focused window moved to the front before the overlay is drawn.

## 1.0.0 — 2026-09-18

The overlay now answers the mouse. Hovering a row selects it, clicking one switches to that window, and clicking anywhere else dismisses without switching — all with <kbd>⌘</kbd> still held, so the pointer is an alternative to counting Tabs rather than a second mode with its own rules. Set `mouse = false` to leave it keyboard-only.

The watchdog is now rearmed on every selection rather than running down from the moment the overlay opened, so picking a row with the mouse is not cut off after ten seconds.

## 0.0.4 — 2026-09-17

scope is now a module at `~/.hammerspoon/scope.lua`, loaded by a fenced `require('scope')` block the installer appends to your `init.lua`, rather than being `init.lua` itself. Installing no longer moves an existing config aside, and `install.sh` migrates a 0.0.3 install in place, restoring the config it had backed up.

Following from that, the module now behaves like a guest: no globals, no `hs.autoLaunch`/`hs.menuIcon`/`hs.automaticallyCheckForUpdates` imposed on the host config, and no alert on every reload. Those preferences are written into an `init.lua` that `install.sh` creates, where they are visible and editable, and left alone in one that already existed.

Added `uninstall.sh`, which reverses all of it and optionally removes Hammerspoon as well.

## 0.0.3 — 2026-09-16

Switching back to a tabbed application now lands on the tab you left up. Under macOS native window tabbing each tab is its own window and only the frontmost is visible to Accessibility, so a tab switch swapped the window out from under the switcher without any event to notice it by: the row carried a stale title, and releasing the modifier pulled that stale tab to the front. The window list is now reconciled against each application's live windows before the overlay is drawn.

## 0.0.2 — 2026-09-16

The default modifier is now <kbd>⌘</kbd>, so scope replaces the system application switcher rather than sitting beside it. Activation moved from `hs.hotkey` to the event tap that already drove the open overlay: the Dock owns <kbd>⌘</kbd> <kbd>Tab</kbd> and refuses to register it as a hotkey, and it is not a shortcut System Settings can disable, but event taps see keys before the Dock does. Set `modifier = 'alt'` to keep the system switcher and run scope alongside it.

## 0.0.1 — 2026-09-15

First release. <kbd>⌥</kbd> <kbd>Tab</kbd> cycles windows of the current Space in a canvas overlay of app icons and titles, <kbd>esc</kbd> dismisses it, and releasing <kbd>⌥</kbd> switches. Accessibility is the only permission required, and Hammerspoon starts at login.