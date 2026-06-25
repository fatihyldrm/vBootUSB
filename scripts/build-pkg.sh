#!/bin/bash
# Builds a macOS .pkg installer that installs /Applications/vBootUSB.app.
# Usage: bash scripts/build-pkg.sh [version]
set -euo pipefail

VERSION="${1:-0.1.0}"
IDENTIFIER="digital.vulut.vbootusb"
APP="dist/vBootUSB.app"
OUT="dist/vBootUSB-${VERSION}.pkg"

[[ -d "$APP" ]] || bash "$(dirname "$0")/build-app.sh" "$VERSION"

ROOT="$(mktemp -d)/root"
mkdir -p "$ROOT/Applications" dist
cp -R "$APP" "$ROOT/Applications/vBootUSB.app"
xattr -rc "$ROOT" 2>/dev/null || true

# Mark the app non-relocatable so it always installs into /Applications.
COMP="$(mktemp).plist"
pkgbuild --analyze --root "$ROOT" "$COMP" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMP" 2>/dev/null || true

pkgbuild \
  --root "$ROOT" \
  --component-plist "$COMP" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/" \
  "$OUT"

echo ""
echo "Created: $OUT"
echo "Install: double-click it (Gatekeeper: right-click > Open if needed),"
echo "         or run: sudo installer -pkg \"$OUT\" -target /"
echo "After install: 'vBootUSB' appears in the Applications folder."
