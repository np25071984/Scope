#!/usr/bin/env bash
# Install scope.
#
#   ./install.sh              use Homebrew if it is available
#   ./install.sh --no-brew    always download from GitHub releases
#   ./install.sh --copy       copy the module instead of symlinking it
#
# Installs Hammerspoon if it is missing, links this repo's scope.lua into
# ~/.hammerspoon, adds a require('scope') line to ~/.hammerspoon/init.lua, and
# starts it. Hammerspoon loads init.lua on every launch, and registers itself as
# a login item the first time the module runs.
#
# scope lives in its own file rather than being init.lua so that it sits beside
# whatever else you already run: the installer appends one line to your config
# instead of moving it out of the way.
#
# The module is symlinked by default, so edits in the clone take effect on
# reload and `git pull` updates the running config. That also means the clone
# has to stay put. Use --copy if you would rather delete it afterwards; the
# tradeoff is that updating then means cloning again.
#
# Homebrew is preferred when present: it tracks the install, so `brew upgrade`
# and `brew uninstall` keep working and the app does not become a file brew
# knows nothing about. The direct download exists so that not having Homebrew
# is never a blocker, not because it is the better route.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_REAL="$(cd "$REPO" && pwd -P)"
CONFIG="$HOME/.hammerspoon/init.lua"
MODULE="$HOME/.hammerspoon/scope.lua"
MARKER="-- scope: window switcher for the current Space"
END_MARKER="-- end scope"
USE_BREW=1
SYMLINK=1

for arg in "$@"; do
  case "$arg" in
    --no-brew) USE_BREW=0 ;;
    --copy)    SYMLINK=0 ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option $arg" >&2; exit 1 ;;
  esac
done

# Resolve a symlink to an absolute path with its directory made real, so that
# ~/Projects/scope compares equal to /Volumes/Code/scope when ~/Projects is
# itself a symlink. Plain string comparison of readlink output does not.
resolve_link() {
  local t d
  t="$(readlink "$1")" || return 1
  case "$t" in /*) ;; *) t="$(dirname "$1")/$t" ;; esac
  d="$(cd "$(dirname "$t")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$d" "$(basename "$t")"
}

if [ ! -f "$REPO/scope.lua" ]; then
  echo "error: scope.lua not found next to this script" >&2
  exit 1
fi

# 1. Hammerspoon itself.
if [ -d "/Applications/Hammerspoon.app" ]; then
  echo "==> Hammerspoon already installed"
elif [ "$USE_BREW" -eq 1 ] && command -v brew >/dev/null 2>&1; then
  echo "==> installing Hammerspoon with Homebrew"
  brew install --cask hammerspoon
else
  if [ "$USE_BREW" -eq 1 ]; then
    echo "==> Homebrew not found, falling back to GitHub releases"
  else
    echo "==> --no-brew given, downloading from GitHub releases"
  fi
  url="$(curl -fsSL https://api.github.com/repos/Hammerspoon/hammerspoon/releases/latest \
          | grep -o 'https://[^"]*Hammerspoon-[^"]*\.zip' | head -1)"
  if [ -z "$url" ]; then
    echo "error: could not resolve a download URL; install Hammerspoon manually" >&2
    exit 1
  fi
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/hammerspoon.zip" "$url"
  unzip -q "$tmp/hammerspoon.zip" -d "$tmp"
  mv "$tmp/Hammerspoon.app" /Applications/
  echo "==> installed /Applications/Hammerspoon.app"
  echo "    The release is notarized, so Gatekeeper will allow it; the first"
  echo "    launch may still ask you to confirm."
  echo "    Note: Homebrew will not know about this copy. If you later run"
  echo "    'brew install --cask hammerspoon' it will adopt or collide with it."
fi

# 2. The module.
mkdir -p "$HOME/.hammerspoon"
if [ "$SYMLINK" -eq 1 ]; then
  ln -sfn "$REPO/scope.lua" "$MODULE"
  echo "==> linked $MODULE -> $REPO/scope.lua"
  echo "    Keep this clone: the module is a symlink into it."
else
  rm -f "$MODULE"
  cp "$REPO/scope.lua" "$MODULE"
  echo "==> copied scope.lua to $MODULE"
  echo "    This clone is no longer needed and can be deleted. Updating later"
  echo "    means cloning again and re-running this script."
fi

# 3. Older versions of this installer made init.lua the module. Take that back
#    out, and put whatever it displaced at the time back where it belongs.
old_target=""
if [ -L "$CONFIG" ]; then
  old_target="$(resolve_link "$CONFIG" || true)"
fi
if [ "$old_target" = "$REPO_REAL/scope.lua" ] || [ "$old_target" = "$REPO_REAL/init.lua" ]; then
  rm -f "$CONFIG"
  echo "==> removed the old init.lua symlink into this repo"
elif [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] && cmp -s "$CONFIG" "$REPO/scope.lua"; then
  rm -f "$CONFIG"
  echo "==> removed the old copy of the module at $CONFIG"
fi

# A symlink pointing at something that is not there would otherwise be followed
# by the append below, creating the loader at the far end of it.
if [ -L "$CONFIG" ] && [ ! -e "$CONFIG" ]; then
  echo "error: $CONFIG points at $(readlink "$CONFIG"), which does not exist." >&2
  echo "       Repair or remove that symlink, then run this again." >&2
  exit 1
fi
if [ ! -e "$CONFIG" ]; then
  restore="$(ls -1d "$CONFIG".backup.* 2>/dev/null | tail -1 || true)"
  if [ -n "$restore" ]; then
    mv "$restore" "$CONFIG"
    echo "==> restored $restore, which an earlier install had moved aside"
  fi
fi

# 4. The lines that load it, fenced so uninstall.sh can take out exactly what
#    was put in. Comments are stripped before looking, so a require that is
#    commented out does not count as already being there.
#
#    hs.autoLaunch and friends are Hammerspoon-wide preferences. They go into a
#    config this script creates, where they are visible and yours to edit, and
#    are kept out of one that already existed -- overwriting somebody's
#    deliberate hs.menuIcon(false) would be rude.
if [ -e "$CONFIG" ] && sed 's/--.*//' "$CONFIG" |
     grep -Eq "require[[:space:]]*\(?[[:space:]]*['\"]scope['\"]"; then
  echo "==> $CONFIG already requires scope"
elif [ -s "$CONFIG" ]; then
  cat >> "$CONFIG" <<EOF

$MARKER
require('scope')
$END_MARKER
EOF
  echo "==> appended require('scope') to $CONFIG"
  echo "    Your Hammerspoon preferences are untouched. scope no longer calls"
  echo "    hs.autoLaunch(true) itself, so add that line if you want Hammerspoon"
  echo "    to start at login."
else
  cat > "$CONFIG" <<EOF
$MARKER
-- https://github.com/np25071984/Scope
--
-- These three are Hammerspoon-wide preferences rather than scope's to make, so
-- they live here where you can see them. autoLaunch is what brings scope back
-- after a reboot; drop the other two if you would rather not have them.
hs.autoLaunch(true)
hs.menuIcon(true)
hs.automaticallyCheckForUpdates(true)

require('scope')
$END_MARKER
EOF
  echo "==> wrote $CONFIG"
fi

# 5. Start it. If it is already running, reload instead of spawning a second.
if pgrep -x Hammerspoon >/dev/null; then
  if command -v hs >/dev/null 2>&1; then
    hs -c 'hs.timer.doAfter(0.2, hs.reload)' >/dev/null 2>&1 || true
  else
    osascript -e 'tell application "Hammerspoon" to reload config' >/dev/null 2>&1 || true
  fi
  echo "==> reloaded running Hammerspoon"
else
  open -a Hammerspoon
  echo "==> launched Hammerspoon"
fi

cat <<'EOF'

Done. One manual step remains, because macOS will not let a script grant it:

  System Settings -> Privacy & Security -> Accessibility -> enable Hammerspoon

Nothing works without it, and it fails silently. Then press Cmd-Tab.
EOF
