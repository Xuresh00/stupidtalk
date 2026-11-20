#!/bin/bash
# Downloads the speech engine StupidTalk is built on: transcribe.cpp, the same open-source
# engine the Handy app uses. It arrives as a prebuilt TranscribeCpp.xcframework (macOS, with
# Metal for the GPU) and is checked against a fixed SHA-256 before it is used.
#
# build.sh and test.sh run this for you. Run it yourself only to fetch the engine ahead of time.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="0.4.2"
SHA256="650a42ee7836558d3047f328078be2b8a8d4c6e9f6a0a3f4ea145481ad1c1a86"
URL="https://github.com/handy-computer/transcribe.cpp/releases/download/v$VERSION/TranscribeCpp.xcframework.zip"

VENDOR="$PROJECT/Vendor"
TARGET="$VENDOR/TranscribeCpp.xcframework"
STAMP="$VENDOR/.transcribe-version"
ZIP="$VENDOR/TranscribeCpp-$VERSION.xcframework.zip"

if [ -d "$TARGET" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$VERSION" ]; then
    exit 0
fi

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

mkdir -p "$VENDOR"
if [ ! -f "$ZIP" ] || [ "$(sha256_of "$ZIP")" != "$SHA256" ]; then
    echo "== Downloading the speech engine (transcribe.cpp $VERSION)"
    rm -f "$ZIP"
    curl --fail --location --retry 4 --retry-delay 2 --silent --show-error --output "$ZIP.part" "$URL"
    mv "$ZIP.part" "$ZIP"
fi

ACTUAL="$(sha256_of "$ZIP")"
if [ "$ACTUAL" != "$SHA256" ]; then
    echo "The speech engine download does not match its checksum." >&2
    echo "  expected $SHA256" >&2
    echo "  got      $ACTUAL" >&2
    rm -f "$ZIP"
    exit 1
fi

rm -rf "$TARGET" "$VENDOR/unpack"
mkdir -p "$VENDOR/unpack"
# ditto keeps the framework's symlinks intact on macOS. unzip does too, elsewhere.
if command -v ditto >/dev/null 2>&1; then
    ditto -x -k "$ZIP" "$VENDOR/unpack"
else
    unzip -q "$ZIP" -d "$VENDOR/unpack"
fi
mv "$VENDOR/unpack/TranscribeCpp.xcframework" "$TARGET"
rm -rf "$VENDOR/unpack"
echo "$VERSION" > "$STAMP"
echo "== Speech engine ready: $TARGET"
