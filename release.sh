#!/bin/bash
# Packages a GitHub-release artifact: a universal (arm64 + x86_64 when Xcode is present) release
# .app inside a drag-to-Applications DMG, plus a SHA-256 checksum. The app is ad-hoc signed
# (no Developer ID), so downloaders must clear quarantine — see the release notes.
set -euo pipefail
cd "$(dirname "$0")"

# Universal (arm64 + x86_64) needs Xcode's xcbuild; with only Command Line Tools installed,
# fall back to a native build for the host arch.
if [ -d "/Library/Developer/SharedFrameworks/XCBuild.framework" ]; then
    SNAPBAR_BUILD_FLAGS="--arch arm64 --arch x86_64" ./make-app.sh
else
    echo "note: full Xcode not found — building native ($(uname -m)) only (install Xcode for a universal binary)."
    ./make-app.sh
fi

APP="dist/SnapBar.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCHS=$(lipo -archs "$APP/Contents/MacOS/SnapBar" | tr ' ' '+')
DMG="dist/SnapBar-$VERSION-macos-$ARCHS.dmg"

echo "== architectures =="
lipo -archs "$APP/Contents/MacOS/SnapBar"

echo "== building DMG (drag-to-Applications) =="
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag target inside the mounted volume
rm -f "$DMG" "$DMG.sha256"
hdiutil create -volname "SnapBar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "== checksum =="
shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo
echo "Artifact ready: $DMG"
ls -lh "$DMG"
