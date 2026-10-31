#!/bin/bash
# Builds the `scope` binary into build/ and signs it.
#
#   ./build.sh                          build only, for this Mac's architecture
#   ./build.sh --universal              build for Apple Silicon and Intel in one
#                                       binary, as releases are
#   ./build.sh --install [--prefix P]   install to P/bin/scope (default ~/.local)
#                                       and start or restart the service
#   ./build.sh --uninstall [--prefix P] `scope uninstall`: stop the service,
#                                       remove the binary and its launchd file;
#                                       scope.conf is kept
#
# Signing. macOS ties the Accessibility permission to the binary's path and
# signature. Signed with the same certificate, a rebuild installed to the same
# path keeps the permission; signed ad hoc, every build needs it granted again.
# The certificate is $SCOPE_SIGN_IDENTITY, else the first "Developer ID
# Application", "Apple Development" or "Scope Dev" one in the keychain. A
# self-signed certificate is enough and need not be trusted; see README.md.
#
# The binary is signed as plain `scope` and carries no Info.plist on purpose:
# given a bundle identifier, macOS files the permission under it, then looks
# for an app with that identifier, finds none, and refuses.
set -euo pipefail

cd "$(dirname "$0")"

prefix="$HOME/.local"
action=build
archs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --install) action=install ;;
    --uninstall) action=uninstall ;;
    --universal) archs=(--arch arm64 --arch x86_64) ;;
    --prefix) prefix="${2:?--prefix needs a directory}"; shift ;;
    --prefix=*) prefix="${1#--prefix=}" ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
target="$prefix/bin/scope"

if [ "$action" = uninstall ]; then
  if [ -x "$target" ]; then
    exec "$target" uninstall
  fi
  echo "no scope at $target" >&2
  exit 1
fi

swift build -c release ${archs[@]+"${archs[@]}"}
mkdir -p build
cp "$(swift build -c release ${archs[@]+"${archs[@]}"} --show-bin-path)/scope" build/scope

identity="${SCOPE_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  # Not `find-identity -v`: that leaves out a self-signed certificate nobody
  # has marked as trusted, and codesign does not need it to be.
  identity="$(security find-identity -p codesigning 2>/dev/null \
    | grep -E '"(Developer ID Application|Apple Development|Scope Dev)' \
    | head -n 1 | awk '{print $2}' || true)"
fi

if [ -n "$identity" ]; then
  codesign --force --options runtime --identifier scope --sign "$identity" build/scope
  echo "signed with: $(codesign -dvv build/scope 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
else
  codesign --force --identifier scope --sign - build/scope
  echo "warning: no signing certificate found; signed ad hoc." >&2
  echo "         The Accessibility permission will not survive the next rebuild." >&2
fi
echo "built $PWD/build/scope ($(build/scope version), $(lipo -archs build/scope))"

[ "$action" = install ] || exit 0

if pgrep -xq Scope; then
  echo "warning: Scope.app is running and also takes ⌘Tab. Quit it and delete" >&2
  echo "         /Applications/Scope.app; it is replaced by $target." >&2
fi

mkdir -p "$prefix/bin"
# Replaced by rename, never rewritten in place: the kernel caches a binary's
# signature, and rewriting a signed binary in place is known to get it killed.
# A rename gives the new binary a new file, so that cannot happen.
cp build/scope "$target.new"
mv -f "$target.new" "$target"
echo "installed $target"

"$target" restart
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "note: $prefix/bin is not on your PATH" ;;
esac
