#!/bin/bash
# Builds Sylvester.app and installs it to /Applications, replacing any prior copy.
# Config/keychain/history are keyed on the bundle id (com.chang.sylvester), so an
# install preserves all existing state — this just swaps the binary + icon.
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

./make-app.sh

DEST="/Applications/Sylvester.app"

# Quit any running instance (dev or installed) so we don't end up with two menubar items.
pkill -f 'Sylvester.app/Contents/MacOS/Sylvester' 2>/dev/null || true

rm -rf "$DEST"
cp -R dist/Sylvester.app "$DEST"
# Re-sign in place after the copy so the signature stays valid.
codesign --force -s "$(sign_identity)" "$DEST"

echo "Installed $DEST"
open "$DEST"
echo "Launched from /Applications."
