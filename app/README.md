# Scope.app

Scope as a standalone macOS app, without Hammerspoon. Same switcher, same keys, same rules for which windows are listed. This is a preview: it builds and runs, but it has not yet had the months of daily use behind `scope.lua`.

The reason for it is lag. In Hammerspoon, the key handler and the code that builds the window list share one Lua thread. When an app is slow to answer Accessibility queries, which is typical of an Android emulator and IDE under a debug build, the handler misses macOS's deadline and the Dock's switcher comes up, then scope's a moment later. Scope.app handles keys on a thread of its own that never waits for anything. It asks every app for its windows in parallel and stops waiting for any single app after 250ms, reusing that app's last answer instead.

## Build and install

Needs macOS 13 or later and the Xcode command line tools.

```bash
cd app
./build.sh --install    # builds build/Scope.app, copies it to /Applications, launches it
```

On first launch Scope asks for **Accessibility** permission and opens the right pane of System Settings. It starts by itself as soon as the switch is on; no relaunch needed. It is the only permission Scope needs.

**Remove Hammerspoon's scope first.** Both intercept ⌘Tab, and which one gets it changes with every Hammerspoon reload. Run `../uninstall.sh` (add `--all` to remove Hammerspoon too), or set `modifier = 'alt'` in `scope.lua` to run both side by side while comparing.

### Signing, and why the permission keeps resetting

macOS ties the Accessibility grant to the app's code signature. `build.sh` signs with, in order: `$SCOPE_SIGN_IDENTITY`, then the first *Developer ID Application*, *Apple Development* or *Scope Dev* identity in your keychain, then ad hoc. An ad-hoc signature changes with every build, so each rebuild needs the grant again: remove Scope from the Accessibility list with the minus button, then add it back.

To avoid that for local builds, create a self-signed certificate once: Keychain Access → Certificate Assistant → Create a Certificate…, name **Scope Dev**, certificate type **Code Signing**. `build.sh` picks it up from then on.

## Menu bar

| Item | Meaning |
|---|---|
| Enabled | turn the switcher off without quitting |
| Modifier | ⌘ replaces the system switcher; ⌥ runs alongside it |
| Pointer Support | hover selects a row, click switches, click elsewhere dismisses |
| Refocus After Space Switch | after a Space switch, focus the window last used there when macOS leaves nothing focused |
| Launch at Login | registers Scope as a login item |
| Trace to System Log | see *Diagnostics* |
| Hide Menu Bar Icon | open Scope again (Spotlight, Finder) to bring it back |

Settings are ordinary user defaults, so `defaults write io.github.np25071984.scope modifier alt` works too. Quit and reopen Scope afterwards.

## Diagnostics

```bash
/Applications/Scope.app/Contents/MacOS/Scope --list
```

Prints whether the private calls Scope relies on still exist on this macOS, then the current Space's windows and how long reading them took. The window list needs the terminal itself to have Accessibility permission.

Turn on **Trace to System Log** and run:

```bash
log stream --predicate 'subsystem == "io.github.np25071984.scope"'
```

to see each focus stamp, each list with its build time, apps that timed out, and every commit and refocus decision.

## How it differs from `scope.lua`

Most of the Lua version's repair stages (ghosts, reconcile, the tab-group re-ranking) exist because `hs.window.filter` keeps a cache of windows that native tabs make stale. Scope.app keeps no window cache:

- **Which windows are on this Space** comes from the window server (`CGWindowListCopyWindowInfo`, on-screen only), which is public API and lists the tab that is up, never one that is swapped out.
- **Which of them are real windows, and their titles**, comes from Accessibility, asked fresh on every open, joined to the window server's list by window id. `AXStandardWindow` only, as before.
- **Most recently used** is kept by hand: an Accessibility observer per app stamps every focused-window change, which also fires for a native tab the app swaps in. App activation and deactivation stamp too, as in 1.2.2. Windows never seen used rank below every stamped one, in stacking order. A tab group still ranks by the newest use of any of its tabs.
- **Focusing** brings forward just the chosen window, through the same private SkyLight calls Hammerspoon and AltTab use. If those calls are missing, Scope activates the whole app instead.
- **The overlay** has the same look and geometry as before.

The private calls (`_AXUIElementGetWindow`, `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`, `SLSGetActiveSpace`, `GetProcessForPID`) are all in `Sources/Scope/Private.swift`, looked up at run time, so a macOS update that removes one makes Scope fall back instead of failing to launch.

Not carried over: the reload hotkey, editable key names (Tab and Escape are fixed), and the appearance fields.
