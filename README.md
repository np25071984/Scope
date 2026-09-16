# Scope

Keyboard-only window switching on macOS, scoped to the current Space.

## The problem

macOS <kbd>⌘</kbd> <kbd>Tab</kbd> switches *applications* across *all* Spaces. If you organise your work into Spaces, that defeats the purpose — you reach for the other window in front of you and get yanked into a different Space instead. There is no native "cycle windows in this Space" switcher, and the gesture-based alternatives are useless without a trackpad.

## What this does

Replaces the switcher with one that lists **windows** (not apps) from the **current Space only**, driven entirely from the keyboard.

| Shortcut | Action |
|---|---|
| <kbd>⌘</kbd> <kbd>Tab</kbd> | next window in the current Space |
| <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>Tab</kbd> | previous window |
| <kbd>esc</kbd> | dismiss without switching |
| release <kbd>⌘</kbd> | switch to the selected window |
| <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>R</kbd> | reload this config |

> <kbd>⌘</kbd> is the **Command** key, <kbd>⇧</kbd> is **Shift**, and <kbd>⌥</kbd> is **Option** — the one between Control and Command, printed `alt` on some keyboards.

Hold <kbd>⌘</kbd>, tab to the window you want, release to select. Press <kbd>esc</kbd> while still holding <kbd>⌘</kbd> to back out and stay where you are.

This replaces the system application switcher outright, so <kbd>⌘</kbd> <kbd>Tab</kbd> no longer reaches windows in other Spaces. Set `modifier = 'alt'` in `init.lua` to leave the system switcher alone and run scope alongside it.

To cycle windows of the current app only, use the native <kbd>⌘</kbd> <kbd>`</kbd> — macOS already scopes that to the frontmost app and to the current Space, so scope does not rebind it.

## Install

```bash
git clone https://github.com/np25071984/Scope.git
cd scope && ./install.sh
```

Clone it wherever you keep source. `install.sh` resolves its own directory, so the symlink it creates points at whatever path you picked and nothing depends on the location — you can move the clone later and re-run it. If you have no preference, `~/.hammerspoon/scope` keeps the repo beside the config that loads it, in a directory that already exists once Hammerspoon is installed.

`install.sh` installs Hammerspoon if it is missing, links `init.lua` into `~/.hammerspoon` (backing up anything already there), and starts or reloads it.

The link means the clone has to stay where it is — deleting it leaves `~/.hammerspoon/init.lua` dangling and Hammerspoon with no config. In exchange, edits in the clone take effect on reload and `git pull` updates the running config. Run `./install.sh --copy` instead to copy the file, after which the clone can be deleted; updating then means cloning again.

It uses Homebrew when Homebrew is present, because that keeps `brew upgrade` and `brew uninstall` working rather than leaving an app brew knows nothing about. Without Homebrew it falls back to the project's GitHub releases, so a missing package manager is never a blocker. Force the fallback with `./install.sh --no-brew`.

Then grant Hammerspoon **Accessibility** permission: System Settings → Privacy & Security → Accessibility → enable Hammerspoon. Nothing works without it, and it fails silently. It is the only permission scope needs.

### Autoload on startup

Both halves are handled, and neither needs a manual step:

- **The config** is loaded by Hammerspoon from `~/.hammerspoon/init.lua` on every launch. The symlink means edits in this repo take effect on reload.
- **Hammerspoon itself** registers as a macOS login item, because `init.lua` calls `hs.autoLaunch(true)`. That is declared in the config rather than ticked in the Preferences window so the setting travels with the repo.

Verify with `hs -c 'hs.autoLaunch()'`, which should print `true`.

## Configuration

Everything configurable lives in the `scope.config` table at the top of `init.lua`. Edit it, then press <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>R</kbd> to reload. That one is still <kbd>⌥</kbd>-based on purpose, so it does not move when you change `modifier`.

| Field | Meaning |
|---|---|
| `modifier` | the key you hold: `'alt'`, `'cmd'` or `'ctrl'` |
| `activate` | pressed with the modifier to open and step forward |
| `step` | keys that move the selection while the overlay is open |
| `cancel` | keys that dismiss without switching |
| `reload` | standalone hotkey, as `{ modifiers, key }` |
| `rowHeight`, `iconSize`, `padding`, `width`, `radius` | appearance |

`modifier` drives both the activation hotkeys and the release-to-select detection, so changing it in one place is enough. Key names come from `hs.keycodes.map`; run `hs -c 'hs.inspect(hs.keycodes.map)'` for the full list.

`modifier = 'cmd'` needs no system changes. The Dock owns <kbd>⌘</kbd> <kbd>Tab</kbd> and it is not one of the shortcuts System Settings can disable, so `hs.hotkey` cannot register it at all — it fails with "this hotkey is already registered". Scope therefore activates from an event tap, which sees keys before the Dock does and swallows the combination.

## Notes

- The window filter is built once at load time rather than per keypress. It subscribes to focus events to maintain most-recently-used ordering, so rebuilding it on every press would lose that history and add a visible stall.
- `allowRoles = 'AXStandardWindow'` keeps helper windows out of the list. Several apps park invisible ones in every Space to render popups — Microsoft Teams' Notification Center keeps a 680×932 one titled literally "Window". They report subrole `AXDialog`, so restricting roles drops all of them at once rather than blacklisting apps by name as they turn up.
- Native-fullscreen apps each occupy their own Space, so they correctly drop out of the list.
- Electron apps (Slack, VS Code, Discord) are slow to answer Accessibility queries. If the switcher feels laggy, uncomment the `rejectApp` line.
- The overlay is hand-rolled on `hs.canvas` rather than using `hs.window.switcher`. The built-in switcher lays itself out around window thumbnails, which need the Screen Recording permission, and it offers no way to cancel. Drawing icons and titles instead means Accessibility is the only permission required.
- One persistent event tap both opens the overlay and drives it. It swallows only the activation combination, <kbd>Tab</kbd> and <kbd>esc</kbd>; every other key returns untouched. If the handler throws, Hammerspoon passes the event through, so a broken config degrades to the system switcher rather than to a dead keyboard. A watchdog tears the overlay down after 10s in case a modifier release is ever missed.
- Reload stays an ordinary `hs.hotkey` rather than going through the tap, so it keeps working when the tap is the thing that broke.

## Changelog

### 0.0.2 — 2026-09-16

The default modifier is now <kbd>⌘</kbd>, so scope replaces the system application switcher rather than sitting beside it. Activation moved from `hs.hotkey` to the event tap that already drove the open overlay: the Dock owns <kbd>⌘</kbd> <kbd>Tab</kbd> and refuses to register it as a hotkey, and it is not a shortcut System Settings can disable, but event taps see keys before the Dock does. Set `modifier = 'alt'` to keep the system switcher and run scope alongside it.

### 0.0.1 — 2026-09-15

First release. <kbd>⌥</kbd> <kbd>Tab</kbd> cycles windows of the current Space in a canvas overlay of app icons and titles, <kbd>esc</kbd> dismisses it, and releasing <kbd>⌥</kbd> switches. Accessibility is the only permission required, and Hammerspoon starts at login.

## License

MIT — see [LICENSE](LICENSE).
