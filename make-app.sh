#!/bin/bash
# Assembles dist/Sylvester.app from the release build. A real bundle (with a bundle id)
# is required for UNUserNotificationCenter — bare `swift run` can't post notifications.
set -euo pipefail
cd "$(dirname "$0")"

# Prefer a stable code-signing identity over ad-hoc.
#
# This is what stops the repeated "Sylvester wants to use your confidential information"
# keychain prompts. A keychain item's ACL pins to the app's *designated requirement*, and
# for an ad-hoc signature that requirement is the cdhash — which changes on every single
# build. So "Always Allow" authorizes a binary that stops existing the moment you rebuild.
# Signing with a certificate makes the requirement `identifier "..." and certificate leaf
# = H"..."`, which is stable, so one "Always Allow" holds forever.
#
# Create one once: Keychain Access > Certificate Assistant > Create a Certificate...
#   Name: Sylvester Signing | Identity Type: Self Signed Root | Certificate Type: Code Signing
# Override the name with SYLVESTER_SIGN_ID if you use something else (e.g. a Developer ID).
sign_identity() {
    local wanted="${SYLVESTER_SIGN_ID:-Sylvester Signing}"
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$wanted"; then
        echo "$wanted"
    else
        echo "-"
    fi
}

# SYLVESTER_BUILD_FLAGS lets release.sh request a universal build (--arch arm64 --arch x86_64);
# --show-bin-path then resolves the right products dir for either host or universal builds.
BUILD_FLAGS="${SYLVESTER_BUILD_FLAGS:-}"
swift build -c release $BUILD_FLAGS
BIN_DIR=$(swift build -c release $BUILD_FLAGS --show-bin-path)

APP=dist/Sylvester.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Sylvester" "$APP/Contents/MacOS/Sylvester"

mkdir -p "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.chang.sylvester</string>
    <key>CFBundleName</key><string>Sylvester</string>
    <key>CFBundleDisplayName</key><string>Sylvester</string>
    <key>CFBundleExecutable</key><string>Sylvester</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>6</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

IDENTITY=$(sign_identity)
codesign --force -s "$IDENTITY" "$APP"
if [ "$IDENTITY" = "-" ]; then
    echo "note: ad-hoc signed. Expect a keychain prompt after each rebuild — see sign_identity() above."
else
    echo "signed with: $IDENTITY"
fi
echo "Built $APP"
