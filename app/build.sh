#!/bin/bash
# Builds Scope.app into app/build/.
#
#   ./build.sh             release build, signed
#   ./build.sh --install   also copy it to /Applications and (re)launch it
#
# Signing. macOS ties the Accessibility grant to the code signature, so an
# ad-hoc signed build loses the grant every time it is rebuilt. Set
# SCOPE_SIGN_IDENTITY to a code-signing identity to keep it, or let this
# script pick the first Developer ID / Apple Development identity in the
# keychain, or one named "Scope Dev" (a self-signed certificate made in
# Keychain Access → Certificate Assistant → Create a Certificate, type Code
# Signing, is enough for local builds).
set -euo pipefail

cd "$(dirname "$0")"

VERSION=2.0.0
BUNDLE_ID=io.github.np25071984.scope
APP=build/Scope.app

install=false
for arg in "$@"; do
  case "$arg" in
    --install) install=true ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

swift build -c release
bin="$(swift build -c release --show-bin-path)/Scope"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin" "$APP/Contents/MacOS/Scope"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Scope</string>
  <key>CFBundleDisplayName</key><string>Scope</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Scope</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

identity="${SCOPE_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Developer ID Application|Apple Development|Scope Dev)' \
    | head -n 1 | sed -E 's/.*"(.*)"/\1/' || true)"
fi

if [ -n "$identity" ]; then
  echo "signing with: $identity"
  codesign --force --options runtime --sign "$identity" "$APP"
else
  echo "warning: no signing identity found; signing ad hoc." >&2
  echo "         The Accessibility grant will not survive the next rebuild." >&2
  codesign --force --sign - "$APP"
fi

echo "built $PWD/$APP"

if $install; then
  pkill -x Scope 2>/dev/null || true
  rm -rf /Applications/Scope.app
  cp -R "$APP" /Applications/Scope.app
  open /Applications/Scope.app
  echo "installed /Applications/Scope.app"
fi
