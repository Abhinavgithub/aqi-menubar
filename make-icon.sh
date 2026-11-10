#!/bin/bash
# Regenerates Resources/AppIcon.icns from the drawing code in Sources/IconRenderer.swift.
# Only needed after changing the icon design; build.sh uses the committed .icns.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh >/dev/null
TMP="$(mktemp -d)"
"build/AQI Bar.app/Contents/MacOS/AQIBar" --render-icon "$TMP/AppIcon.iconset"
mkdir -p Resources
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$TMP/AppIcon.iconset/icon_512x512@2x.png" docs/icon.png
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns and docs/icon.png"
