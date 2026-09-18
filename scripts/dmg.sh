#!/bin/bash
# Wraps the bundled .app in a drag-to-Applications .dmg, which is what a browser
# download hands a user. bundle.sh only ad-hoc signs, so this disk image is not
# notarized: Gatekeeper will warn on first open. The landing page carries the
# Open Anyway instructions that go with that.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP="$(bash "$ROOT/scripts/bundle.sh" "$CONFIG")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"

STAGE="$(mktemp -d)"
DMG="$ROOT/.build/DiskReclaim-$VERSION.dmg"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "Disk Reclaim" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

# The download page serves this same-origin, under a version-free name so the
# button never has to be re-pointed. Committed to web/ because Vercel's git
# integration only deploys what is tracked.
cp "$DMG" "$ROOT/web/DiskReclaim.dmg"

echo "$DMG"
