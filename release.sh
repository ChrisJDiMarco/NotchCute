#!/bin/bash
# Builds a Developer ID–signed, notarized zip for GitHub Releases and the Homebrew cask.
# One-time setup: xcrun notarytool store-credentials notchcute --apple-id <you> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")"
IDENTITY="${IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-notchcute}"
APP=build/NotchCute.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
ZIP="build/NotchCute-$VERSION.zip"

bash build.sh
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
echo "$ZIP"
echo "sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)  (paste into packaging/notchcute.rb)"
