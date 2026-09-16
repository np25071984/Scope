#!/usr/bin/env bash
# Install scope.
#
#   ./install.sh              use Homebrew if it is available
#   ./install.sh --no-brew    always download from GitHub releases
#   ./install.sh --copy       copy the config instead of symlinking it
#
# Installs Hammerspoon if it is missing, links this repo's init.lua into
# ~/.hammerspoon, and starts it. Hammerspoon then loads the config on every
# launch, and registers itself as a login item the first time the config runs.
#
# The config is symlinked by default, so edits in the clone take effect on
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
CONFIG="$HOME/.hammerspoon/init.lua"
USE_BREW=1
SYMLINK=1

for arg in "$@"; do
  case "$arg" in
    --no-brew) USE_BREW=0 ;;
    --copy)    SYMLINK=0 ;;
    -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option $arg" >&2; exit 1 ;;
  esac
done

if [ ! -f "$REPO/init.lua" ]; then
  echo "error: init.lua not found next to this script" >&2
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

# 2. Link the config, preserving anything already there.
mkdir -p "$HOME/.hammerspoon"
if [ -e "$CONFIG" ] && [ ! -L "$CONFIG" ]; then
  backup="$CONFIG.backup.$(date +%Y%m%d%H%M%S)"
  mv "$CONFIG" "$backup"
  echo "==> existing config moved to $backup"
fi
if [ "$SYMLINK" -eq 1 ]; then
  ln -sfn "$REPO/init.lua" "$CONFIG"
  echo "==> linked $CONFIG -> $REPO/init.lua"
  echo "    Keep this clone: the config is a symlink into it."
else
  rm -f "$CONFIG"
  cp "$REPO/init.lua" "$CONFIG"
  echo "==> copied init.lua to $CONFIG"
  echo "    This clone is no longer needed and can be deleted. Updating later"
  echo "    means cloning again and re-running this script."
fi

# 3. Start it. If it is already running, reload instead of spawning a second.
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

Nothing works without it, and it fails silently. Then press Alt-Tab.
EOF
