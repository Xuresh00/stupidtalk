#!/bin/bash
# Runs the tests for the clean-up logic (StupidTalkCore).
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
ARGS=(--package-path "$PROJECT")

if [ "$(uname)" = "Darwin" ] && ! xcodebuild -version >/dev/null 2>&1; then
    # Only the Command Line Tools are installed: there is no XCTest, and the
    # Swift Testing macro plugin has to be pointed at by hand.
    SWIFTC="$(xcrun --find swiftc)"
    PLUGIN="$(dirname "$SWIFTC")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
    ARGS+=(--disable-xctest --enable-swift-testing)
    if [ -f "$PLUGIN" ]; then
        ARGS+=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")
    fi
fi

swift test "${ARGS[@]}"
