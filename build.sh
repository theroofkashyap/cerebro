#!/bin/bash
# Builds Cerebro and wraps it in an app bundle; the motion permission prompt needs a bundle with an Info.plist.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Cerebro.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Plain swiftc rather than SwiftPM, so this builds with only the Command Line Tools installed.
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    Sources/Cerebro/*.swift -o "$APP/Contents/MacOS/Cerebro"
cp Info.plist "$APP/Contents/Info.plist"
# The logo files are kept out of the repository. With one in place the app draws it, and replacing it
# restyles the app on the next build; without one the app shows a plain text title.
LOGO="cerebro logo/with logo mark.svg"
if [ -f "$LOGO" ]; then cp "$LOGO" "$APP/Contents/Resources/Logo.svg"; fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Plain ad-hoc signing ties macOS privacy grants (Accessibility) to one exact build, so every rebuild
# loses them. Naming the bundle identifier as the app's requirement keeps the grant across rebuilds.
# The identifier is still the app's original one, so the existing grant carries over the rename.
codesign --force --sign - --requirements '=designated => identifier "local.mousie"' "$APP"

echo "Built $APP"
