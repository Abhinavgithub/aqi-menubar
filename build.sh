#!/bin/bash
# Builds "AQI Bar.app" into ./build. Needs Xcode or the Command Line Tools
# (run `xcode-select --install` once if `swiftc` is missing).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AQI Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    mkdir -p "$APP/Contents/Resources"
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

swiftc -O -parse-as-library \
    -target "$(uname -m)-apple-macos13.0" \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/AQIBar"

# Ad-hoc signature so macOS can remember the location permission.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run it with: open \"$APP\""
