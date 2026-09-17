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

# Contents/Resources and not the app root. codesign seals Contents/ and nothing
# beside it, so a resource bundle in the root makes the app unsignable — which
# is what it did until `Catalogue.bundledURL` stopped using SwiftPM's generated
# accessor, whose only search path is that root.
shopt -s nullglob
BUNDLES=("$ROOT/.build/$CONFIG"/*.bundle)
if [ ${#BUNDLES[@]} -eq 0 ]; then
    echo "no resource bundles in .build/$CONFIG — the catalogue would be missing" >&2
    exit 1
fi
cp -R "${BUNDLES[@]}" "$APP/Contents/Resources/"

# Committed artwork, regenerated from vector source by `swift run IconGen`.
if [ -f "$ROOT/Resources/DiskReclaim.icns" ]; then
    cp "$ROOT/Resources/DiskReclaim.icns" "$APP/Contents/Resources/DiskReclaim.icns"
else
    echo "warning: no Resources/DiskReclaim.icns — run 'swift run IconGen'" >&2
fi

# Which build this is. The app has no telemetry, no crash reporting and no
# update ping by design, so the identifier it carries is the only thing joining
# a user's report to a commit — there is no second channel to fall back on.
#
# Derived rather than maintained, because a number someone has to remember to
# bump is a number that sits at 1 through fifteen commits, which is what this
# replaces. CFBundleVersion accepts only digits and periods, so the count goes
# there and the SHA cannot; the SHA rides in Credits.html, which AppKit's
# standard About panel renders with no code in the app at all.
if BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null)"; then
    COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
    if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
        COMMIT="$COMMIT plus uncommitted changes"
    fi
    SOURCE="Build $BUILD, from commit $COMMIT."
else
    # An archive rather than a clone. Naming that is more use than a zero that
    # reads like a real build number to whoever is trying to reproduce a report.
    BUILD=0
    SOURCE="Built from a source copy carrying no history, so this build cannot be identified by commit."
fi

cat > "$APP/Contents/Resources/Credits.html" <<HTML
<html><body style="font-family:-apple-system;font-size:11px;color:#444">
<p>$SOURCE</p>
</body></html>
HTML

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: unsigned bundles get killed on arm64.
#
# Fatal rather than swallowed. A silent `|| true` here hid a failing signature
# for the whole life of the script — the app launched anyway, because the linker
# ad-hoc-signs the executable regardless, so nothing ever pointed at the bundle
# having no seal at all.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "$APP"
