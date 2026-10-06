#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP=build/NotchCute.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ ! -f Icon/icon-1024.png ]; then swift Icon/make_icon.swift Icon/icon-1024.png; fi
rm -rf build/AppIcon.iconset; mkdir -p build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s Icon/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s*2)); sips -z $d $d Icon/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/NotchCute" Sources/main.swift
codesign --force --sign - "$APP"
echo BUILT
