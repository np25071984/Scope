# scope (standalone)

Scope without Hammerspoon: a single `scope` binary that runs as a launchd service and is controlled from the command line. Same switcher, same keys, same rules for which windows are listed. It has no app bundle, Dock icon or menu bar; settings live in a config file. This is a preview: it builds and runs, but it has not yet had the months of daily use behind `scope.lua`.

The reason for it is lag. In Hammerspoon, the key handler and the code that builds the window list share one Lua thread. When an app is slow to answer Accessibility queries, which is typical of an Android emulator and IDE under a debug build, the handler misses macOS's deadline and the Dock's switcher comes up, then scope's a moment later. This version handles keys on a thread of its own that never waits for anything. It asks every app for its windows in parallel and stops waiting for any single app after 250ms, reusing that app's last answer instead.

## Install

Needs macOS 13 or later and the Xcode command line tools.

```bash
cd app
./build.sh --install                 # ~/.local/bin/scope
./build.sh --install --prefix /opt/scope   # /opt/scope/bin/scope
```

This builds and signs `scope`, installs it, writes `~/Library/LaunchAgents/io.github.np25071984.scope.plist` and starts the service. From then on it starts at every login, and launchd restarts it if it crashes.

On first start, scope asks for **Accessibility** permission, its only one, and `scope start` opens the right pane of System Settings. Turn on **scope** there. If it is not listed, add the binary with **+** (⌘⇧G to type the path). The service checks every 5 seconds and starts by itself once allowed.

```bash
./build.sh --uninstall [--prefix P]  # stops it, removes the binary and the launchd file
```

`scope.conf` is left in place.

**Remove other copies first.** Hammerspoon's scope and Scope.app (2.0.x) both intercept ⌘Tab too. Run `../uninstall.sh` for the Hammerspoon one (add `--all` to remove Hammerspoon as well). For Scope.app, quit it, untick its Launch at Login and delete `/Applications/Scope.app`.

### Signing, and why the permission can reset

macOS ties the Accessibility permission to the binary's **path and signature**. Rebuilt and installed to the same path with the same certificate, scope keeps it. Installed somewhere else, or signed ad hoc, it needs granting again.

`build.sh` signs with `$SCOPE_SIGN_IDENTITY`, else the first *Developer ID Application*, *Apple Development* or *Scope Dev* certificate in your keychain, else ad hoc. For local builds, create a self-signed certificate once: Keychain Access → Certificate Assistant → Create a Certificate…, name **Scope Dev**, type **Code Signing**. It does not need to be marked as trusted.

The binary is signed with the plain identifier `scope` and carries no `Info.plist`. With a reverse-DNS identifier or an embedded `Info.plist`, macOS files the permission under a bundle ID, then looks for an app with that ID, finds none and refuses. The entry shows in System Settings with a folder icon, and turning it on does nothing.

## Commands

| Command | |
|---|---|
| `scope start` | start the service, writing its launchd file if it is missing or points at another binary |
| `scope stop` | stop it; it starts again at the next login |
| `scope restart` | restart it |
| `scope reload` | re-read `scope.conf` (or send the service `SIGHUP`) |
| `scope status` | launchd state, pid, permission, private-call availability, effective settings and config warnings. Exits 0 when running, 3 when not, 4 without permission. |
| `scope logs` | follow the service's log; `scope logs --last 1h` shows the past hour |
| `scope list` | the windows ⌘Tab would show, most recent first, each with when it was last used |
| `scope list --direct` | read the windows in this process instead: stacking order, and it needs the terminal to have Accessibility permission |
| `scope run` | the service in the foreground; what launchd runs |
| `scope version` | |

`status`, `list` and `reload` talk to the running service through a socket in the per-user temporary directory. That is deliberate: run from a shell, a command gets the terminal's Accessibility permission, not scope's, and only the service knows which windows were used when.

`launchctl` sees the service like any other agent:

```bash
launchctl print gui/$UID/io.github.np25071984.scope
launchctl kickstart -k gui/$UID/io.github.np25071984.scope
```

If scope is installed by a Homebrew formula, its agent is `homebrew.mxcl.scope`, owned by `brew services`. `scope start`, `stop` and `restart` then hand over to `brew services`, so the two never disagree.

## Configuration

`~/.config/scope/scope.conf`, or `$XDG_CONFIG_HOME/scope/scope.conf`. Every line is optional, and scope never writes the file.

```ini
modifier = cmd     # cmd replaces the system switcher; alt (⌥Tab) runs alongside it; ctrl
mouse    = true    # hover selects a row, click switches, click elsewhere dismisses
refocus  = true    # after a Space switch, focus the window last used there when macOS
                   # leaves nothing focused, or only carried the previous app over
trace    = false   # log every switcher decision
```

`#` starts a comment. Booleans take `true/false`, `yes/no`, `on/off` or `1/0`. A bad value or unknown key keeps the default for that line and is reported by `scope reload`, `scope status` and the log. Apply changes with `scope reload`.

## Diagnostics

`scope logs` follows the service's log: start, permission, reloads and warnings. With `trace = true` it also shows each focus stamp, each list with its build time, apps that timed out, and every commit and refocus decision. Anything the service prints outside the log, such as a crash, goes to `~/Library/Logs/scope.log`.

## How it differs from `scope.lua`

Most of the Lua version's repair stages (ghosts, reconcile, the tab-group re-ranking) exist because `hs.window.filter` keeps a cache of windows that native tabs make stale. This version keeps no window cache:

- **Which windows are on this Space** comes from the window server (`CGWindowListCopyWindowInfo`, on-screen only), which is public API and lists the tab that is up, never one that is swapped out.
- **Which of them are real windows, and their titles**, comes from Accessibility, asked fresh on every open, joined to the window server's list by window id. `AXStandardWindow` only, as before.
- **Most recently used** is kept by hand: an Accessibility observer per app stamps every focused-window change, which also fires for a native tab the app swaps in. App activation and deactivation stamp too, as in 1.2.2. Windows never seen used rank below every stamped one, in stacking order. A tab group still ranks by the newest use of any of its tabs.
- **Refocus after a Space switch** ranks by use from before the switch, since arriving on a Space stamps the window macOS brings forward. A focused window is left alone unless no app was activated around the switch and it belongs to the app that was already active, which means macOS carried that app over rather than you choosing the window.
- **Focusing** brings forward just the chosen window, through the same private SkyLight calls Hammerspoon and AltTab use. If those calls are missing, scope activates the whole app instead.
- **The overlay** has the same look and geometry as before.

The private calls (`_AXUIElementGetWindow`, `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`, `SLSGetActiveSpace`, `GetProcessForPID`) are all in `Sources/Scope/Private.swift`, looked up at run time, so a macOS update that removes one makes scope fall back instead of failing to launch.

Not carried over: the reload hotkey (`scope reload` replaces it), editable key names (Tab and Escape are fixed), and the appearance fields.

## Changelog

### Unreleased

Scope is now a single `scope` binary run as a launchd service instead of Scope.app. Install with `./build.sh --install`, which puts it in `~/.local/bin` by default (`--prefix` to change), starts it, and has launchd start it at login and restart it after a crash. The menu bar is gone: settings move from user defaults to `~/.config/scope/scope.conf`, and `scope start | stop | restart | reload | status | logs | list` replace the menu. `scope list` now asks the running service, so it shows the switcher's own order with each window's last use, and no longer needs the terminal to have Accessibility permission. The *Enabled* switch is gone (`scope stop`), and so are *Launch at Login* and *Hide Menu Bar Icon*. The service checks for Accessibility permission every 5 seconds instead of showing an alert. `build.sh` now also finds a self-signed certificate that is not marked as trusted, which it used to skip, falling back to ad-hoc signing.

### 2.0.1 — 2026-10-31

Switching to a Space now focuses the window you last used there, even when the app you left also has a window on that Space. macOS focuses that app's window on arrival, and Scope used to treat it as your choice and leave it. Scope now recognises this case because no app was activated around the switch, and it ranks windows by their use from before the switch, since arriving stamps the carried-over window as used. A window you pick from the Dock, a notification or Mission Control is still left alone.

### 2.0.0

First build of Scope.app, a standalone version that needs no Hammerspoon.
