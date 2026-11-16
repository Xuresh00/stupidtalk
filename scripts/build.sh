#!/bin/bash
# Builds StupidTalk.app from source.
#
#   scripts/build.sh              -> dist/StupidTalk.app and dist/StupidTalk-<version>.zip
#   scripts/build.sh ~/Applications   -> puts the app straight into that folder
#
# Needs macOS 26 or newer on Apple silicon, and Swift 6 (Xcode, or only the
# Command Line Tools: xcode-select --install).
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${STUPIDTALK_BUILD_DIR:-$PROJECT/.build-local}"
OUTPUT_DIR="${1:-$PROJECT/dist}"
VERSION="$(tr -d '[:space:]' < "$PROJECT/VERSION")"
BUILD_NUMBER="${STUPIDTALK_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
APP_NAME="StupidTalk"
BUNDLE_ID="com.stupidesigner.StupidTalk"

mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

echo "== Building $APP_NAME $VERSION ($BUILD_NUMBER)"
swift --version
BUILD_ARGS=(--package-path "$PROJECT" --scratch-path "$BUILD_ROOT/swift" -c release --product "$APP_NAME")
swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

echo "== Packaging"
STAGE="$BUILD_ROOT/package"
APP="$STAGE/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$PROJECT"/Sources/StupidTalk/Resources/* "$APP/Contents/Resources/"
iconutil -c icns "$PROJECT/Packaging/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" "$PROJECT/Packaging/Info.plist" > "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run on Apple silicon. It is not a Developer ID signature
# and the app is not notarized.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# Replace the old copy completely, so removed files cannot linger and break the signature.
rm -rf "$OUTPUT_DIR/$APP_NAME.app"
ditto "$APP" "$OUTPUT_DIR/$APP_NAME.app"
codesign --verify --strict "$OUTPUT_DIR/$APP_NAME.app"

if [ "${STUPIDTALK_SKIP_ZIP:-0}" != 1 ]; then
    ZIP="$OUTPUT_DIR/$APP_NAME-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "== Zip: $ZIP"
fi
echo "== Done: $OUTPUT_DIR/$APP_NAME.app"
