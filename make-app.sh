#!/bin/bash
# Assembles dist/SnapBar.app from the release build. A real bundle (with a bundle id)
# is required for UNUserNotificationCenter — bare `swift run` can't post notifications.
set -euo pipefail
cd "$(dirname "$0")"

# SNAPBAR_BUILD_FLAGS lets release.sh request a universal build (--arch arm64 --arch x86_64);
# --show-bin-path then resolves the right products dir for either host or universal builds.
BUILD_FLAGS="${SNAPBAR_BUILD_FLAGS:-}"
swift build -c release $BUILD_FLAGS
BIN_DIR=$(swift build -c release $BUILD_FLAGS --show-bin-path)

APP=dist/SnapBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/SnapBar" "$APP/Contents/MacOS/SnapBar"

mkdir -p "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.chang.snapbar</string>
    <key>CFBundleName</key><string>SnapBar</string>
    <key>CFBundleDisplayName</key><string>SnapBar</string>
    <key>CFBundleExecutable</key><string>SnapBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.2</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "Built $APP"
