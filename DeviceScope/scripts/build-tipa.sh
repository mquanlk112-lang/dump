#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Missing xcodegen. Install: brew install xcodegen" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "xcodebuild requires macOS with Xcode installed." >&2; exit 1; }

xcodegen generate --spec project.yml
xcodebuild \
  -project DeviceScope.xcodeproj \
  -scheme DeviceScope \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP_PATH="build/Build/Products/Release-iphoneos/DeviceScope.app"
test -d "$APP_PATH"
test -f "$APP_PATH/Info.plist"
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist")
test -f "$APP_PATH/$EXECUTABLE"

rm -rf out
mkdir -p out/Payload
ditto "$APP_PATH" out/Payload/DeviceScope.app
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' out/Payload/DeviceScope.app/Info.plist
file "out/Payload/DeviceScope.app/$EXECUTABLE"
(cd out && /usr/bin/zip -qry DeviceScope.tipa Payload)
unzip -t out/DeviceScope.tipa
echo "Created: $(pwd)/out/DeviceScope.tipa"
