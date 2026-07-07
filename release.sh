#!/bin/bash
# Packages a GitHub-release artifact: a universal (arm64 + x86_64) release .app, zipped with
# ditto (which preserves the code signature) plus a SHA-256 checksum. The app is ad-hoc signed
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
ZIP="dist/SnapBar-$VERSION-macos-$ARCHS.zip"

echo "== architectures =="
lipo -archs "$APP/Contents/MacOS/SnapBar"

echo "== zipping (ditto preserves the signature) =="
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "== checksum =="
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo
echo "Artifact ready: $ZIP"
ls -lh "$ZIP"
