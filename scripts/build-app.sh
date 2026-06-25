#!/bin/bash
# Builds the vBootUSB.app bundle (GUI + embedded privileged helper + icon + ad-hoc signature).
# Usage: bash Scripts/build-app.sh [version]
set -euo pipefail

VERSION="${1:-0.1.0}"
APP="dist/vBootUSB.app"
GUI=".build/release/vBootUSB"
CLI=".build/release/vbootusb-cli"
ICON="Resources/AppIcon.icns"

[[ -x "$GUI" ]] || { echo "Build first:  swift build -c release" >&2; exit 1; }
[[ -f "$ICON" ]] || { echo "Missing icon. Generate:  make icon" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$GUI" "$APP/Contents/MacOS/vBootUSB"
# The macOS filesystem is case-insensitive: a "vbootusb" helper in MacOS/ would collide
# with the "vBootUSB" GUI binary, so the helper lives in a separate Helpers/ folder.
cp "$CLI" "$APP/Contents/Helpers/vbootusb"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
chmod 755 "$APP/Contents/MacOS/vBootUSB" "$APP/Contents/Helpers/vbootusb"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>vBootUSB</string>
  <key>CFBundleDisplayName</key><string>vBootUSB</string>
  <key>CFBundleExecutable</key><string>vBootUSB</string>
  <key>CFBundleIdentifier</key><string>digital.vulut.vbootusb</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSRemovableVolumesUsageDescription</key><string>vBootUSB needs access to your USB drive to write the bootable image.</string>
</dict></plist>
PLIST

xattr -rc "$APP" 2>/dev/null || true
# Ad-hoc signature: unsigned binaries are blocked by Gatekeeper; ad-hoc is enough to run locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Created: $APP  (version $VERSION)"
