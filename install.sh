#!/bin/bash
# Builds SnapBar.app and installs it to /Applications, replacing any prior copy.
# Config/keychain/history are keyed on the bundle id (com.chang.snapbar), so an
# install preserves all existing state — this just swaps the binary + icon.
set -euo pipefail
cd "$(dirname "$0")"

./make-app.sh

DEST="/Applications/SnapBar.app"

# Quit any running instance (dev or installed) so we don't end up with two menubar items.
pkill -f 'SnapBar.app/Contents/MacOS/SnapBar' 2>/dev/null || true

rm -rf "$DEST"
cp -R dist/SnapBar.app "$DEST"
# Re-sign in place after the copy so the ad-hoc signature stays valid.
codesign --force -s - "$DEST"

echo "Installed $DEST"
open "$DEST"
echo "Launched from /Applications."
