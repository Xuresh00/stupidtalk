#!/bin/bash
# Builds StupidTalk.app from source.
#
#   scripts/build.sh                 -> dist/StupidTalk.app and dist/StupidTalk-<version>.zip
#   scripts/build.sh /Applications   -> puts the app straight into that folder
#
# Options, as environment variables:
#   STUPIDTALK_DMG_DIR=folder    also make StupidTalk-<version>.dmg there, the file to share
#   STUPIDTALK_SKIP_ZIP=1        no zip
#   STUPIDTALK_BUILD_DIR=folder  where the build cache lives (default: .build-local in the project)
#   STUPIDTALK_BUILD_NUMBER=n    the build number shown in About
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
# A disk image with the app and a shortcut to Applications: the usual way to hand over a Mac app.
if [ -n "${STUPIDTALK_DMG_DIR:-}" ]; then
    mkdir -p "$STUPIDTALK_DMG_DIR"
    DMG_DIR="$(cd "$STUPIDTALK_DMG_DIR" && pwd)"
    DMG="$DMG_DIR/$APP_NAME-$VERSION.dmg"
    DMG_STAGE="$BUILD_ROOT/dmg"
    rm -rf "$DMG_STAGE"
    mkdir -p "$DMG_STAGE"
    ditto "$APP" "$DMG_STAGE/$APP_NAME.app"
    ln -s /Applications "$DMG_STAGE/Applications"
    # The new app file replaces older ones in that folder.
    rm -f "$DMG_DIR/$APP_NAME"-[0-9]*.dmg "$DMG_DIR/$APP_NAME"-[0-9]*.zip
    if hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null; then
        echo "== Disk image: $DMG"
    else
        echo "== The disk image could not be made. Saving the app as a zip instead."
        rm -f "$DMG"
        ditto -c -k --keepParent "$APP" "$DMG_DIR/$APP_NAME-$VERSION.zip"
        echo "== Zip: $DMG_DIR/$APP_NAME-$VERSION.zip"
    fi
    rm -rf "$DMG_STAGE"
fi
echo "== Done: $OUTPUT_DIR/$APP_NAME.app"
