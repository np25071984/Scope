#!/usr/bin/env bash
# Uninstall scope.
#
#   ./uninstall.sh            remove scope, leave Hammerspoon installed
#   ./uninstall.sh --all      also uninstall Hammerspoon and delete its data
#   ./uninstall.sh --yes      skip the confirmation prompt --all asks for
#
# Undoes install.sh: clears the login item, removes ~/.hammerspoon/scope.lua
# when it is this repo's module, and takes the fenced require('scope') block
# back out of ~/.hammerspoon/init.lua. A module file that is neither this
# repo's symlink nor an unmodified copy of it is left alone, as is anything
# outside that fence and the clone itself -- delete that yourself when you are
# done with it.
#
# The login item goes first, while Hammerspoon is still running to clear it.
# hs.autoLaunch(true) writes a macOS setting rather than a line in the config,
# so removing the module alone leaves Hammerspoon launching at every login with
# nothing to load.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_REAL="$(cd "$REPO" && pwd -P)"
CONFIG="$HOME/.hammerspoon/init.lua"
MODULE="$HOME/.hammerspoon/scope.lua"
ALL=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --all)    ALL=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option $arg" >&2; exit 1 ;;
  esac
done

if [ "$ALL" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
  if [ ! -t 0 ]; then
    echo "error: --all uninstalls Hammerspoon; pass --yes to confirm non-interactively" >&2
    exit 1
  fi
  echo "This uninstalls Hammerspoon and deletes its preferences, caches and data."
  printf 'Continue? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|Yes) ;;
    *) echo "aborted"; exit 1 ;;
  esac
fi

running() { pgrep -x Hammerspoon >/dev/null 2>&1; }

# hs(1) is a symlink into the app bundle, installed from Hammerspoon's own
# Preferences window. Plenty of installs do not have it, so every use is guarded.
hs_eval() {
  command -v hs >/dev/null 2>&1 && running && hs -c "$1" >/dev/null 2>&1
}

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

# ours: true when $1 is our symlink into the clone, or an unmodified copy of
# the module. Either way removing it costs the user nothing they wrote.
ours() {
  local path="$1" target=""
  if [ -L "$path" ]; then
    target="$(resolve_link "$path" || true)"
    if [ "$target" = "$REPO_REAL/scope.lua" ] || [ "$target" = "$REPO_REAL/init.lua" ]; then
      return 0
    fi
    # A dangling link named after our module is ours by any reasonable reading;
    # one named init.lua could be someone's dotfiles on an unmounted disk.
    if [ ! -e "$path" ] && [ "${target##*/}" = "scope.lua" ]; then
      return 0
    fi
    return 1
  fi
  [ -f "$path" ] && cmp -s "$path" "$REPO/scope.lua"
}

# 1. The login item, before anything is taken away that could clear it.
echo "==> clearing the login item"
if hs_eval 'hs.autoLaunch(false)'; then
  echo "    hs.autoLaunch(false)"
elif osascript -e 'tell application "System Events" to delete login item "Hammerspoon"' >/dev/null 2>&1; then
  echo "    deleted the System Events login item"
else
  echo "    could not clear it automatically (Hammerspoon not running, or no hs CLI)"
  echo "    Check System Settings -> General -> Login Items."
fi

# 2. The module, and only if it is ours.
echo "==> removing the module"
KEPT=0
if [ ! -e "$MODULE" ] && [ ! -L "$MODULE" ]; then
  echo "    nothing at $MODULE"
elif ours "$MODULE"; then
  rm -f "$MODULE"
  echo "    removed $MODULE"
else
  KEPT=1
  echo "    $MODULE is not this repo's module -- left in place"
fi

# 3. The block that loads it, and the file if that block was all it held. Only
#    whitespace counts as nothing: a leftover comment is something the user
#    wrote, and their file stays.
echo "==> unhooking it from $CONFIG"
if [ -L "$CONFIG" ] && ours "$CONFIG"; then
  # The 0.0.3 layout: init.lua *was* the module.
  rm -f "$CONFIG"
  echo "    removed the old symlink $CONFIG"
elif [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] && ours "$CONFIG"; then
  rm -f "$CONFIG"
  echo "    removed the old copy of the module at $CONFIG"
elif [ -f "$CONFIG" ]; then
  tmp="$(mktemp)"
  # install.sh fences its block between the two markers, so the whole thing --
  # loader line, comments and the hs.autoLaunch preferences it writes into a
  # config it created -- comes out as a unit. The fence is only trusted when
  # both ends are present; a file with an opening marker and no closing one
  # would otherwise lose everything after it. Anything else falls back to
  # taking out loose marker and require lines, which is what a require added
  # by hand looks like.
  if grep -q "^[[:space:]]*-- end scope[[:space:]]*$" "$CONFIG" &&
     grep -q "^[[:space:]]*--[[:space:]]*scope:" "$CONFIG"; then
    awk '
      /^[[:space:]]*--[[:space:]]*scope:/ && !fenced { fenced = 1; next }
      fenced && /^[[:space:]]*-- end scope[[:space:]]*$/ { fenced = 0; next }
      fenced { next }
      { print }
    ' "$CONFIG" > "$tmp"
  else
    cp "$CONFIG" "$tmp"
  fi
  grep -v -E "^[[:space:]]*(--[[:space:]]*scope:.*|require[[:space:]]*\(?[[:space:]]*['\"]scope['\"][[:space:]]*\)?[[:space:]]*)$" \
    "$tmp" > "$tmp.2" || true
  mv "$tmp.2" "$tmp"
  if cmp -s "$tmp" "$CONFIG"; then
    rm -f "$tmp"
    echo "    no require('scope') line in $CONFIG"
  elif [ -z "$(tr -d '[:space:]' < "$tmp")" ]; then
    rm -f "$tmp" "$CONFIG"
    echo "    removed $CONFIG, which held nothing but the loader"
  else
    # Rewritten in place to keep the file's mode and inode; the command
    # substitution drops the blank line install.sh put before the marker,
    # so repeated install/uninstall cycles do not pile them up.
    printf '%s\n' "$(cat "$tmp")" > "$CONFIG"
    rm -f "$tmp"
    echo "    took the loader line out of $CONFIG, leaving the rest"
  fi
elif [ -L "$CONFIG" ]; then
  echo "    $CONFIG points at $(readlink "$CONFIG"), which is not there --"
  echo "    left alone in case that path comes back"
else
  echo "    nothing at $CONFIG"
fi

# 4. Whatever a pre-0.0.4 install.sh moved aside, newest wins.
backup=""
if [ ! -e "$CONFIG" ]; then
  backup="$(ls -1d "$CONFIG".backup.* 2>/dev/null | tail -1 || true)"
fi
if [ -n "$backup" ] && [ "$ALL" -eq 0 ]; then
  mv "$backup" "$CONFIG"
  echo "==> restored $backup"
fi

# 5. Reload onto what is left, or quit so the hotkeys stop.
if running; then
  if [ -e "$CONFIG" ] && [ "$ALL" -eq 0 ]; then
    hs_eval 'hs.timer.doAfter(0.2, hs.reload)' \
      || osascript -e 'tell application "Hammerspoon" to reload config' >/dev/null 2>&1 \
      || true
    echo "==> reloaded Hammerspoon"
  else
    osascript -e 'tell application "Hammerspoon" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      running || break
      sleep 0.3
    done
    running && pkill -x Hammerspoon >/dev/null 2>&1 || true
    echo "==> quit Hammerspoon"
  fi
fi

if [ "$ALL" -eq 0 ]; then
  cat <<EOF

Done. Hammerspoon is still installed. Delete the clone when you no longer
want it:

  rm -rf $REPO
EOF
  exit 0
fi

# 6. Hammerspoon itself. Homebrew first, so its records do not go stale.
echo "==> uninstalling Hammerspoon"
if command -v brew >/dev/null 2>&1 && brew list --cask hammerspoon >/dev/null 2>&1; then
  brew uninstall --cask hammerspoon
elif [ -d /Applications/Hammerspoon.app ]; then
  rm -rf /Applications/Hammerspoon.app
  echo "    removed /Applications/Hammerspoon.app"
else
  echo "    /Applications/Hammerspoon.app not found"
fi

hs_bin="$(command -v hs 2>/dev/null || true)"
if [ -n "$hs_bin" ] && [ -L "$hs_bin" ] && [ ! -e "$hs_bin" ]; then
  if rm -f "$hs_bin" 2>/dev/null; then
    echo "    removed dangling $hs_bin"
  else
    echo "    $hs_bin now dangles into the deleted bundle; remove it yourself"
  fi
fi

# 7. Its data. Anything we did not write keeps the directory alive.
keep_dir=0
if [ "$KEPT" -eq 1 ] || [ -n "$backup" ] || [ -e "$CONFIG" ]; then
  keep_dir=1
fi
for path in \
  "$HOME/.hammerspoon" \
  "$HOME/Library/Preferences/org.hammerspoon.Hammerspoon.plist" \
  "$HOME/Library/Application Support/Hammerspoon" \
  "$HOME/Library/Caches/org.hammerspoon.Hammerspoon" \
  "$HOME/Library/Saved Application State/org.hammerspoon.Hammerspoon.savedState"
do
  if [ "$path" = "$HOME/.hammerspoon" ] && [ "$keep_dir" -eq 1 ]; then
    echo "    kept $path -- it still holds a config this script did not write"
    continue
  fi
  if [ -e "$path" ]; then
    rm -rf "$path"
    echo "    removed $path"
  fi
done

cat <<EOF

Done. One manual step remains, because macOS will not let a script do it:

  System Settings -> Privacy & Security -> Accessibility -> remove Hammerspoon

The entry outlives the app, and a stale one re-authorises whatever is installed
at that path later. Then delete the clone:

  rm -rf $REPO
EOF
