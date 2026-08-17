#!/bin/bash

# Photo Culler Test Runner
#
# Two layers:
#   1. The headless regression suite (`swift run pcqa`) — always runs, no Xcode required.
#      This is the primary gate and covers every module that touches the user's files.
#   2. The per-package XCTest suites — only when a full Xcode is selected, because XCTest
#      does not ship with the Command Line Tools.
#
# Previously this script exited immediately on a Command Line Tools setup, so the suite was
# unrunnable on a machine that could still build and ship the app.

set -euo pipefail

cd "$(dirname "$0")"

echo "════════════════════════════════════════"
echo "  Photo Culler — regression suite"
echo "════════════════════════════════════════"
swift run pcqa

XCODE_PATH="$(xcode-select -p 2>/dev/null || echo "")"
if [[ "$XCODE_PATH" == *"/CommandLineTools" || -z "$XCODE_PATH" ]]; then
    echo ""
    echo "ℹ️  Skipping XCTest package suites: xcode-select points at Command Line Tools."
    echo "   XCTest needs a full Xcode install. To include them:"
    echo "     sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    echo ""
    echo "✅ Regression suite passed."
    exit 0
fi

for pkg in Packages/*; do
    if [ -d "$pkg/Tests" ]; then
        echo ""
        echo "════════════════════════════════════════"
        echo "  XCTest: $(basename "$pkg")"
        echo "════════════════════════════════════════"
        ( cd "$pkg" && swift test )
    fi
done

echo ""
echo "✅ All tests completed successfully!"
