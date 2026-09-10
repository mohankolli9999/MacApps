#!/bin/bash
# SwiftPM only emits a bare executable, so the .app wrapper is assembled by hand.
# Without it macOS treats the binary as a background tool: no Dock icon, no menu
# bar, and a window that cannot take focus.
set -euo pipefail

# Release by default. A debug Swift build walks a disk several times slower, and
# this script produces the app people actually launch — defaulting to debug meant
# every timing anyone quoted was measured against the wrong binary.
CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/DiskReclaim"
APP="$ROOT/.build/DiskReclaim.app"

swift build --product DiskReclaim ${CONFIG:+-c "$CONFIG"} >/dev/null

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskReclaim"

# SwiftPM's generated Bundle.module looks in Bundle.main.bundleURL, which for an
# app is the .app itself and NOT Contents/Resources. Its only fallback is an
# absolute path into this machine's .build, so getting this wrong ships an app
# that works here and fatalErrors on launch anywhere else.
shopt -s nullglob
BUNDLES=("$ROOT/.build/$CONFIG"/*.bundle)
if [ ${#BUNDLES[@]} -eq 0 ]; then
    echo "no resource bundles in .build/$CONFIG — the catalogue would be missing" >&2
    exit 1
fi
cp -R "${BUNDLES[@]}" "$APP/"

# Committed artwork, regenerated from vector source by `swift run IconGen`.
if [ -f "$ROOT/Resources/DiskReclaim.icns" ]; then
    cp "$ROOT/Resources/DiskReclaim.icns" "$APP/Contents/Resources/DiskReclaim.icns"
else
    echo "warning: no Resources/DiskReclaim.icns — run 'swift run IconGen'" >&2
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Disk Reclaim</string>
    <key>CFBundleDisplayName</key><string>Disk Reclaim</string>
    <key>CFBundleExecutable</key><string>DiskReclaim</string>
    <key>CFBundleIdentifier</key><string>dev.macapps.diskreclaim</string>
    <key>CFBundleIconFile</key><string>DiskReclaim</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: unsigned bundles get killed on arm64.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "$APP"
