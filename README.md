# Scope

Keyboard-first window switching on macOS, scoped to the current Space.

## The problem

macOS <kbd>⌘</kbd> <kbd>Tab</kbd> switches *applications* across *all* Spaces. If you organise your work into Spaces, that defeats the purpose — you reach for the other window in front of you and get yanked into a different Space instead. There is no native "cycle windows in this Space" switcher, and the gesture-based alternatives are useless without a trackpad.

## What this does

Replaces the switcher with one that lists **windows** (not apps) from the **current Space only**, driven from the keyboard, with the pointer there when you would rather aim at the window you want than count Tabs to it.

![The scope overlay open over a Terminal window, listing the windows of the current Space with the selected row highlighted](docs/screenshot.png)

| Shortcut | Action |
|---|---|
| <kbd>⌘</kbd> <kbd>Tab</kbd> | next window in the current Space |
| <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>Tab</kbd> | previous window |
| <kbd>esc</kbd> | dismiss without switching |
| release <kbd>⌘</kbd> | switch to the selected window |
| hover a row | select it, without switching yet |
| click a row | switch to that window |
| click anywhere else | dismiss without switching |

> <kbd>⌘</kbd> is the **Command** key, <kbd>⇧</kbd> is **Shift**, and <kbd>⌥</kbd> is **Option** — the one between Control and Command, printed `alt` on some keyboards.

Hold <kbd>⌘</kbd>, tab to the window you want, release to select. Press <kbd>esc</kbd> while still holding <kbd>⌘</kbd> to back out and stay where you are.

The pointer works the same way, with <kbd>⌘</kbd> still held: hovering a row selects it, so releasing <kbd>⌘</kbd> over a row switches to that one, and clicking it switches without waiting for the release. A click anywhere off the overlay dismisses it. Nothing about the overlay outlives the modifier — it is the same gesture either way, which is also how the system switcher behaves. Set `mouse = false` to turn the pointer off entirely.

This replaces the system application switcher outright, so <kbd>⌘</kbd> <kbd>Tab</kbd> no longer reaches windows in other Spaces. Set `modifier = alt` to leave the system switcher alone and run scope on <kbd>⌥</kbd> <kbd>Tab</kbd> alongside it.

To cycle windows of the current app only, use the native <kbd>⌘</kbd> <kbd>`</kbd> — macOS already scopes that to the frontmost app and to the current Space, so scope does not rebind it.

scope is a single binary run as a launchd service. It has no app bundle, Dock icon or menu bar: you control it with `scope start | stop | status | …` and configure it in a text file.

## Install

Needs macOS 13 or later and the Xcode command line tools.

```bash
./build.sh --install                       # ~/.local/bin/scope
./build.sh --install --prefix /opt/scope   # /opt/scope/bin/scope
```

This builds and signs `scope`, installs it, writes `~/Library/LaunchAgents/io.github.np25071984.scope.plist` and starts the service. From then on it starts at every login, and launchd restarts it if it crashes.

On first start, scope asks for **Accessibility** permission, its only one, and opens the right pane of System Settings. Turn on **scope** there. If it is not listed, add the binary with **+** (⌘⇧G to type the path). The service checks every 5 seconds and starts by itself once allowed.

To update, pull and run `./build.sh --install` again; the service restarts on the new binary and keeps its permission. To remove it:

```bash
./build.sh --uninstall [--prefix P]   # stops it, removes the binary and the launchd file
```

`scope.conf` is left in place.

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

When the list comes out in the wrong order, `scope list` shows it as the switcher would, with each window's last use, so a window that was never seen used stands out.

## How it works

- **Which windows are on this Space** comes from the window server (`CGWindowListCopyWindowInfo`, on-screen only), which is public API and lists the tab that is up, never one that is swapped out. Native-fullscreen apps each occupy their own Space, so they correctly drop out of the list.
- **Which of them are real windows, and their titles**, comes from Accessibility, asked fresh on every open, joined to the window server's list by window id. Only `AXStandardWindow` counts. That keeps out the invisible helper windows several apps park in every Space to render popups — Microsoft Teams keeps a 680×932 one titled literally "Window" — along with sheets and dialogs.
- **Slow apps never stall the switcher.** Keys are handled on a thread of their own that never waits for anything, so ⌘Tab is never lost to the system switcher, however busy the machine is. Apps are asked for their windows in parallel, and any app that takes longer than 250ms is skipped and represented by its last answer. Electron apps and an Android emulator and IDE under a debug build are the usual slow ones.
- **Most recently used** is kept by hand: an Accessibility observer per app stamps every focused-window change, which also fires for a native tab the app swaps in. App activation and deactivation stamp too, since a tab switched to by keyboard fires nothing else, and every Space switch deactivates something. Windows never seen used rank below every stamped one, in stacking order.
- **A tab group is one row**, never one row per tab: the tabs behind the front one do not exist as far as Accessibility is concerned, so there is nothing to list and no way to target them. Cycle those with the app's own tab shortcuts. The row ranks by the newest use of any of its tabs — every hidden tab of the same app with the row's frame, on the Space it was used on — so using Terminal through one tab and then moving to another does not lose the first.
- **Refocus after a Space switch.** Switching Spaces does not reliably move the keyboard with you: the app active on the Space you left stays active when it has nothing on the new one, so your last window is in front but not focused. Once the switch has settled (0.3s), scope focuses the window used last on the new Space, ranking by use from before the switch, since arriving stamps the window macOS brings forward. A focused window is left alone unless no app was activated around the switch and it belongs to the app that was already active, which means macOS carried that app over rather than you choosing the window. If scope has seen nothing used on that Space since it started, it leaves focus alone rather than guess. Set `refocus = false` to turn this off.
- **Focusing** brings forward just the chosen window, through the same private SkyLight calls AltTab uses. If those calls are missing, scope activates the whole app instead.
- **The overlay** draws app icons and titles rather than window thumbnails, which would need the Screen Recording permission. Accessibility is the only permission required.
- **One persistent event tap** both opens the overlay and drives it. It swallows only the activation combination, <kbd>Tab</kbd> and <kbd>esc</kbd>; every other key passes untouched. A watchdog tears the overlay down after 10s without input, in case a modifier release is ever missed; every selection rearms it, so a slow decision with the mouse is not cut short.
- **The pointer gets a second tap**, enabled only while the overlay is on screen, because `mouseMoved` fires continuously. Both halves of a click are swallowed so neither reaches the window underneath, and rows are hit-tested by the tap rather than by the overlay, which ignores the mouse so that it can never take focus from the window a click is about to hand it to.

The private calls (`_AXUIElementGetWindow`, `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`, `SLSGetActiveSpace`, `GetProcessForPID`) are all in `Sources/Scope/Private.swift`, looked up at run time, so a macOS update that removes one makes scope fall back instead of failing to launch. `scope status` reports which are available.

## Changelog

### 2.1.0 — 2026-10-31

scope is now a single `scope` binary run as a launchd service instead of Scope.app. Install with `./build.sh --install`, which puts it in `~/.local/bin` by default (`--prefix` to change), starts it, and has launchd start it at login and restart it after a crash. The menu bar is gone: settings move from user defaults to `~/.config/scope/scope.conf`, and `scope start | stop | restart | reload | status | logs | list` replace the menu. `scope list` now asks the running service, so it shows the switcher's own order with each window's last use, and no longer needs the terminal to have Accessibility permission. The *Enabled* switch is gone (`scope stop`), and so are *Launch at Login* and *Hide Menu Bar Icon*. The service checks for Accessibility permission every 5 seconds instead of showing an alert. `build.sh` now also finds a self-signed certificate that is not marked as trusted, which it used to skip, falling back to ad-hoc signing.

Upgrading from 2.0.x: quit Scope.app, delete `/Applications/Scope.app`, run `./build.sh --install`, and grant **scope** Accessibility permission. Settings are not carried over; set them again in `scope.conf`.

### 2.0.1 — 2026-10-31

Switching to a Space now focuses the window you last used there, even when the app you left also has a window on that Space. macOS focuses that app's window on arrival, and scope used to treat it as your choice and leave it. scope now recognises this case because no app was activated around the switch, and it ranks windows by their use from before the switch, since arriving stamps the carried-over window as used. A window you pick from the Dock, a notification or Mission Control is still left alone.

### 2.0.0

First native build, Scope.app. Versions 0.0.1 to 1.2.2 were a scripted predecessor; they remain in the git history.

## License

MIT — see [LICENSE](LICENSE).
