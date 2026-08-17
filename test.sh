#!/bin/bash

# Photo Culler Test Runner
# This script runs all automated tests for the Photo Culler project and its packages.

set -e

echo "Running Photo Culler Tests..."

# Check if XCTest is available by checking the xcode-select path
XCODE_PATH=$(xcode-select -p)
if [[ "$XCODE_PATH" == *"/CommandLineTools" ]]; then
    echo "⚠️ Warning: xcode-select is pointing to CommandLineTools."
    echo "XCTest is only available with a full Xcode installation."
    echo "Please run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    echo "and try again."
    exit 1
fi

PACKAGES_DIR="Packages"

# Find all packages with a Tests directory and run swift test
for pkg in "$PACKAGES_DIR"/*; do
    if [ -d "$pkg/Tests" ]; then
        echo "======================================"
        echo "Testing $(basename "$pkg")..."
        echo "======================================"
        cd "$pkg"
        swift test
        cd ../..
    fi
done

echo "✅ All tests completed successfully!"