# Scope

Keyboard-first window switching on macOS, scoped to the current Space.

## The problem

macOS <kbd>⌘</kbd> <kbd>Tab</kbd> switches *applications* across *all* Spaces. If you organise your work into Spaces, that defeats the purpose — you reach for the other window in front of you and get yanked into a different Space instead. There is no native "cycle windows in this Space" switcher, and the gesture-based alternatives are useless without a trackpad.

## What this does

Replaces the switcher with one that lists **windows** (not apps) from the **current Space only**, driven from the keyboard, with the pointer there when you would rather aim at the window you want than count Tabs to it.

| Shortcut | Action |
|---|---|
| <kbd>⌘</kbd> <kbd>Tab</kbd> | next window in the current Space |
| <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>Tab</kbd> | previous window |
| <kbd>esc</kbd> | dismiss without switching |
| release <kbd>⌘</kbd> | switch to the selected window |
| hover a row | select it, without switching yet |
| click a row | switch to that window |
| click anywhere else | dismiss without switching |
| <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>R</kbd> | reload this config |

> <kbd>⌘</kbd> is the **Command** key, <kbd>⇧</kbd> is **Shift**, and <kbd>⌥</kbd> is **Option** — the one between Control and Command, printed `alt` on some keyboards.

Hold <kbd>⌘</kbd>, tab to the window you want, release to select. Press <kbd>esc</kbd> while still holding <kbd>⌘</kbd> to back out and stay where you are.

The pointer works the same way, with <kbd>⌘</kbd> still held: hovering a row selects it, so releasing <kbd>⌘</kbd> over a row switches to that one, and clicking it switches without waiting for the release. A click anywhere off the overlay dismisses it. Nothing about the overlay outlives the modifier — it is the same gesture either way, which is also how the system switcher behaves. Set `mouse = false` to turn the pointer off entirely.

This replaces the system application switcher outright, so <kbd>⌘</kbd> <kbd>Tab</kbd> no longer reaches windows in other Spaces. Set `modifier = 'alt'` in `scope.lua` to leave the system switcher alone and run scope alongside it.

To cycle windows of the current app only, use the native <kbd>⌘</kbd> <kbd>`</kbd> — macOS already scopes that to the frontmost app and to the current Space, so scope does not rebind it.

## Install

```bash
git clone https://github.com/np25071984/Scope.git
cd scope && ./install.sh
```

Clone it wherever you keep source. `install.sh` resolves its own directory, so the symlink it creates points at whatever path you picked and nothing depends on the location — you can move the clone later and re-run it. If you have no preference, `~/.hammerspoon/scope` keeps the repo beside the config that loads it, in a directory that already exists once Hammerspoon is installed.

`install.sh` installs Hammerspoon if it is missing, links `scope.lua` into `~/.hammerspoon`, adds a `require('scope')` line to `~/.hammerspoon/init.lua`, and starts or reloads it.

scope is a module rather than the config itself, so it sits beside whatever you already run: the installer appends a fenced block to your `init.lua` instead of moving it out of the way, and creates that file only if it is not there. Running it twice adds nothing the second time.

The link means the clone has to stay where it is — deleting it leaves `~/.hammerspoon/scope.lua` dangling and the `require` failing on load. In exchange, edits in the clone take effect on reload and `git pull` updates the running config. Run `./install.sh --copy` instead to copy the file, after which the clone can be deleted; updating then means cloning again.

It uses Homebrew when Homebrew is present, because that keeps `brew upgrade` and `brew uninstall` working rather than leaving an app brew knows nothing about. Without Homebrew it falls back to the project's GitHub releases, so a missing package manager is never a blocker. Force the fallback with `./install.sh --no-brew`.

Then grant Hammerspoon **Accessibility** permission: System Settings → Privacy & Security → Accessibility → enable Hammerspoon. Nothing works without it, and it fails silently. It is the only permission scope needs.

### Autoload on startup

- **The module** is loaded by Hammerspoon through `~/.hammerspoon/init.lua`, which it reads on every launch. The symlink means edits in this repo take effect on reload.
- **Hammerspoon itself** registers as a macOS login item when something calls `hs.autoLaunch(true)`. That is a Hammerspoon-wide preference rather than scope's to set, so `scope.lua` does not touch it. An `init.lua` written by `install.sh` contains the call, commented for what it does; an `init.lua` that already existed is left to make its own call, and the installer says so rather than editing preferences you chose.

Verify with `hs -c 'hs.autoLaunch()'`, which should print `true`. If it prints `false`, add `hs.autoLaunch(true)` to your `init.lua`.

## Uninstall

```bash
./uninstall.sh          # remove scope, leave Hammerspoon installed
./uninstall.sh --all    # uninstall Hammerspoon and delete its data too
```

`uninstall.sh` clears the login item, removes `~/.hammerspoon/scope.lua`, and takes the fenced block back out of `~/.hammerspoon/init.lua` — deleting that file too if the block was all it held, and leaving it otherwise. The fence is what makes that exact: everything between `-- scope:` and `-- end scope` goes, nothing else does, and a file with an opening marker but no closing one falls back to removing loose `require('scope')` lines rather than swallowing the remainder. It removes the module only when it is this repo's symlink or an unmodified copy of it, so anything you wrote yourself stays where it is.

The login item is the part that is easy to miss by hand. `hs.autoLaunch(true)` writes a macOS setting rather than a line in the config, so deleting `scope.lua` on its own leaves Hammerspoon launching at every login with nothing to load. The script clears it first, while Hammerspoon is still around to clear it.

`--all` uninstalls the app as well — through Homebrew when Homebrew installed it, so `brew` is not left tracking something that is gone — and deletes the preferences, caches and saved-state files. It keeps `~/.hammerspoon` when a config it did not write is still sitting there. One step is left to you afterwards, because macOS will not let a script do it: remove Hammerspoon from System Settings → Privacy & Security → Accessibility. That entry outlives the app, and a stale one silently re-authorises whatever is installed at the same path later.

Neither mode deletes the clone; the last line of output tells you where it is.

## Configuration

Everything configurable lives in the `scope.config` table at the top of `scope.lua`. Edit it, then press <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>R</kbd> to reload. That one is still <kbd>⌥</kbd>-based on purpose, so it does not move when you change `modifier`.

| Field | Meaning |
|---|---|
| `modifier` | the key you hold: `'alt'`, `'cmd'` or `'ctrl'` |
| `activate` | pressed with the modifier to open and step forward |
| `step` | keys that move the selection while the overlay is open |
| `cancel` | keys that dismiss without switching |
| `reload` | standalone hotkey, as `{ modifiers, key }` |
| `mouse` | whether the pointer selects and clicks rows while the overlay is open |
| `rowHeight`, `iconSize`, `padding`, `width`, `radius` | appearance |

`modifier` drives both the activation hotkeys and the release-to-select detection, so changing it in one place is enough. Key names come from `hs.keycodes.map`; run `hs -c 'hs.inspect(hs.keycodes.map)'` for the full list.

`modifier = 'cmd'` needs no system changes. The Dock owns <kbd>⌘</kbd> <kbd>Tab</kbd> and it is not one of the shortcuts System Settings can disable, so `hs.hotkey` cannot register it at all — it fails with "this hotkey is already registered". Scope therefore activates from an event tap, which sees keys before the Dock does and swallows the combination.

## Notes

- The window filter is built once at load time rather than per keypress. It subscribes to focus events to maintain most-recently-used ordering, so rebuilding it on every press would lose that history and add a visible stall.
- `allowRoles = 'AXStandardWindow'` keeps helper windows out of the list. Several apps park invisible ones in every Space to render popups — Microsoft Teams' Notification Center keeps a 680×932 one titled literally "Window". They report subrole `AXDialog`, so restricting roles drops all of them at once rather than blacklisting apps by name as they turn up.
- Native-fullscreen apps each occupy their own Space, so they correctly drop out of the list.
- macOS native window tabbing — Terminal, Finder, Preview, anything that merges windows into a tab bar — gives every tab its own window but exposes only the frontmost one to Accessibility. A tab switch is therefore one window quietly replacing another, and it fires none of the created/destroyed events `hs.window.filter` maintains its cache from, so the cache keeps naming the tab that was up when it last heard anything. Left alone that showed the wrong title on the row and, on release, hauled that other tab in front of the one you actually left up. Scope reconciles the filter's list against each application's live window list before drawing, which costs ~10ms and leaves the most-recently-used ordering alone.
- A tab group is always one row, never one row per tab. The tabs behind the front one do not exist as far as Accessibility is concerned, so there is nothing to list and no way to target them. Cycle those with the application's own tab shortcuts.
- Electron apps (Slack, VS Code, Discord) are slow to answer Accessibility queries. If the switcher feels laggy, uncomment the `rejectApp` line.
- The overlay is hand-rolled on `hs.canvas` rather than using `hs.window.switcher`. The built-in switcher lays itself out around window thumbnails, which need the Screen Recording permission, and it offers no way to cancel. Drawing icons and titles instead means Accessibility is the only permission required.
- One persistent event tap both opens the overlay and drives it. It swallows only the activation combination, <kbd>Tab</kbd> and <kbd>esc</kbd>; every other key returns untouched. If the handler throws, Hammerspoon passes the event through, so a broken config degrades to the system switcher rather than to a dead keyboard. A watchdog tears the overlay down after 10s without input, in case a modifier release is ever missed; every selection rearms it, so a slow decision with the mouse is not cut short.
- The pointer gets a second tap, started when the overlay is drawn and stopped when it goes away. `mouseMoved` fires continuously, and a switcher that is on screen a second at a time has no business running a callback on every mouse move for the rest of the day. Both halves of a click are swallowed, so neither reaches the window underneath — the overlay sits over somebody else's window, where a click is nearly always one you did not mean to make.
- Rows are hit-tested arithmetically against the canvas frame rather than through `hs.canvas`'s own mouse tracking. That tracking needs `clickActivating` to be off, or a click brings Hammerspoon forward and takes the focus that is about to go to the target window; turning it off changes the canvas's `AXSubrole`, which this module would then have to keep out of its own window filter. Hit-testing in Lua leaves the canvas invisible to the mouse and to Accessibility alike.
- Reload stays an ordinary `hs.hotkey` rather than going through the tap, so it keeps working when the tap is the thing that broke.
- `scope.lua` defines no globals and sets no Hammerspoon-wide preferences. It is required into somebody else's `init.lua`, where a stray global named `scope` or `spaceFilter` would collide silently, and where flipping `hs.menuIcon` or `hs.automaticallyCheckForUpdates` would override a deliberate choice. The module table is returned instead; `package.loaded` then holds the reference that keeps the two event taps and the reload hotkey from being collected, and `package.loaded.scope.filter` is the handle for poking at the window filter from the console.

## Changelog

### 0.0.5 — 2026-09-17

The overlay now answers the mouse. Hovering a row selects it, clicking one switches to that window, and clicking anywhere else dismisses without switching — all with <kbd>⌘</kbd> still held, so the pointer is an alternative to counting Tabs rather than a second mode with its own rules. Set `mouse = false` to leave it keyboard-only.

The watchdog is now rearmed on every selection rather than running down from the moment the overlay opened, so picking a row with the mouse is not cut off after ten seconds.

### 0.0.4 — 2026-09-17

scope is now a module at `~/.hammerspoon/scope.lua`, loaded by a fenced `require('scope')` block the installer appends to your `init.lua`, rather than being `init.lua` itself. Installing no longer moves an existing config aside, and `install.sh` migrates a 0.0.3 install in place, restoring the config it had backed up.

Following from that, the module now behaves like a guest: no globals, no `hs.autoLaunch`/`hs.menuIcon`/`hs.automaticallyCheckForUpdates` imposed on the host config, and no alert on every reload. Those preferences are written into an `init.lua` that `install.sh` creates, where they are visible and editable, and left alone in one that already existed.

Added `uninstall.sh`, which reverses all of it and optionally removes Hammerspoon as well.

### 0.0.3 — 2026-09-16

Switching back to a tabbed application now lands on the tab you left up. Under macOS native window tabbing each tab is its own window and only the frontmost is visible to Accessibility, so a tab switch swapped the window out from under the switcher without any event to notice it by: the row carried a stale title, and releasing the modifier pulled that stale tab to the front. The window list is now reconciled against each application's live windows before the overlay is drawn.

### 0.0.2 — 2026-09-16

The default modifier is now <kbd>⌘</kbd>, so scope replaces the system application switcher rather than sitting beside it. Activation moved from `hs.hotkey` to the event tap that already drove the open overlay: the Dock owns <kbd>⌘</kbd> <kbd>Tab</kbd> and refuses to register it as a hotkey, and it is not a shortcut System Settings can disable, but event taps see keys before the Dock does. Set `modifier = 'alt'` to keep the system switcher and run scope alongside it.

### 0.0.1 — 2026-09-15

First release. <kbd>⌥</kbd> <kbd>Tab</kbd> cycles windows of the current Space in a canvas overlay of app icons and titles, <kbd>esc</kbd> dismisses it, and releasing <kbd>⌥</kbd> switches. Accessibility is the only permission required, and Hammerspoon starts at login.

## License

MIT — see [LICENSE](LICENSE).
