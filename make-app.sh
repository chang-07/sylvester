#!/bin/bash
# Assembles dist/SnapBar.app from the release build. A real bundle (with a bundle id)
# is required for UNUserNotificationCenter — bare `swift run` can't post notifications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=dist/SnapBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SnapBar "$APP/Contents/MacOS/SnapBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.chang.snapbar</string>
    <key>CFBundleName</key><string>SnapBar</string>
    <key>CFBundleDisplayName</key><string>SnapBar</string>
    <key>CFBundleExecutable</key><string>SnapBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "Built $APP"
