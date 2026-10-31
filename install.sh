#!/bin/sh
# Installs or upgrades scope from its latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/np25071984/Scope/main/install.sh | sh
#
# Downloads the release, checks its checksum and signature, installs the
# binary to ~/.local/bin/scope and starts (or restarts) the service. Running it
# again upgrades. Nothing else on the system is touched.
#
#   SCOPE_VERSION=v2.2.0   install that release instead of the latest
#   SCOPE_PREFIX=/opt/x    install to /opt/x/bin/scope instead of ~/.local/bin
#
# Keep the prefix the same between upgrades: macOS ties scope's Accessibility
# permission to the binary's path, so a new path needs the permission again.
set -eu

repo="np25071984/Scope"
asset="scope-macos.tar.gz"
prefix="${SCOPE_PREFIX:-$HOME/.local}"
target="$prefix/bin/scope"

# Only releases signed with scope's release certificate are installed.
release_signature='identifier scope and certificate root = H"a846bd7500d703aba7f80b68faf6df39ee954ca3"'

fail() { echo "scope install: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "scope runs on macOS only"
command -v curl >/dev/null || fail "curl is required"

if [ -n "${SCOPE_VERSION:-}" ]; then
  url="https://github.com/$repo/releases/download/$SCOPE_VERSION/$asset"
else
  url="https://github.com/$repo/releases/latest/download/$asset"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

echo "downloading $url"
curl -fsSL -o "$work/$asset" "$url" || fail "download failed"
curl -fsSL -o "$work/$asset.sha256" "$url.sha256" || fail "checksum download failed"
(cd "$work" && shasum -a 256 -c "$asset.sha256" >/dev/null 2>&1) || fail "checksum does not match"

tar -xzf "$work/$asset" -C "$work" scope || fail "unexpected archive contents"
codesign --verify --strict "$work/scope" 2>/dev/null || fail "the binary's signature is invalid"
signature="$(codesign -d -r- "$work/scope" 2>&1 | sed -n 's/^designated => //p')"
[ "$signature" = "$release_signature" ] || fail "the binary is not signed by scope's release certificate"

mkdir -p "$prefix/bin"
# Replaced by rename, never rewritten in place: a signed binary rewritten in
# place while it runs can be killed.
cp "$work/scope" "$target.new"
chmod 755 "$target.new"
mv -f "$target.new" "$target"
echo "installed $target ($("$target" version))"

"$target" restart

case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo
     echo "note: $prefix/bin is not on your PATH. Add it, or call $target directly." ;;
esac
