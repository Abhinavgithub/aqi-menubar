#!/bin/bash
# Builds AQI Bar and installs it to /Applications (or ~/Applications if /Applications
# isn't writable), then quits any running copy and opens the installed one.
# Run it again after pulling changes to update.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST_DIR="/Applications"
if [ ! -w "$DEST_DIR" ]; then
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/AQI Bar.app"

# Quit any running copy (installed or the one in ./build).
osascript -e 'quit app id "local.aqibar"' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -x AQIBar >/dev/null || break; sleep 1; done
pkill -x AQIBar 2>/dev/null || true

rm -rf "$DEST"
ditto "build/AQI Bar.app" "$DEST"
open "$DEST"
echo "Installed and opened $DEST"
