#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Photo Culler"
EXECUTABLE="PhotoCuller"
BUNDLE="${EXECUTABLE}.app"
BUILD_DIR="build"
DMG_NAME="${EXECUTABLE}.dmg"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_DIR}"

# ── 1. Build release binary ─────────────────────────────────────────────────
echo "==> Building release binary..."
swift build -c release

BINARY=".build/release/${EXECUTABLE}"
if [[ ! -f "${BINARY}" ]]; then
    echo "ERROR: Expected binary at ${BINARY}" >&2
    exit 1
fi

# ── 2. Assemble .app bundle ─────────────────────────────────────────────────
echo "==> Assembling ${BUNDLE}..."
rm -rf "${BUILD_DIR}/${BUNDLE}"
mkdir -p "${BUILD_DIR}/${BUNDLE}/Contents/MacOS"
mkdir -p "${BUILD_DIR}/${BUNDLE}/Contents/Resources"

cp "${BINARY}" "${BUILD_DIR}/${BUNDLE}/Contents/MacOS/${EXECUTABLE}"
cp "PhotoCuller/Info.plist" "${BUILD_DIR}/${BUNDLE}/Contents/"

# Copy app icon if one exists
if [[ -f "PhotoCuller/AppIcon.icns" ]]; then
    cp "PhotoCuller/AppIcon.icns" "${BUILD_DIR}/${BUNDLE}/Contents/Resources/"
fi

# ── 3. Ad-hoc code sign ─────────────────────────────────────────────────────
echo "==> Code signing (ad-hoc)..."
codesign --force --deep -s - "${BUILD_DIR}/${BUNDLE}"

# ── 4. Create .dmg ──────────────────────────────────────────────────────────
echo "==> Creating ${DMG_NAME}..."
rm -f "${BUILD_DIR}/${DMG_NAME}"

# Use create-dmg for a polished installer if available, otherwise hdiutil
if command -v create-dmg &>/dev/null; then
    create-dmg \
        --volname "${APP_NAME}" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "${BUNDLE}" 150 185 \
        --app-drop-link 450 185 \
        --no-internet-enable \
        "${BUILD_DIR}/${DMG_NAME}" \
        "${BUILD_DIR}/${BUNDLE}"
else
    STAGING="${BUILD_DIR}/dmg-staging"
    rm -rf "${STAGING}"
    mkdir -p "${STAGING}"
    cp -R "${BUILD_DIR}/${BUNDLE}" "${STAGING}/"
    ln -s /Applications "${STAGING}/Applications"

    hdiutil create \
        -volname "${APP_NAME}" \
        -srcfolder "${STAGING}" \
        -ov \
        -format UDZO \
        "${BUILD_DIR}/${DMG_NAME}"

    rm -rf "${STAGING}"
fi

DMG_SIZE=$(du -h "${BUILD_DIR}/${DMG_NAME}" | cut -f1)
echo ""
echo "==> Done! ${BUILD_DIR}/${DMG_NAME} (${DMG_SIZE})"
echo ""
echo "NOTE: This app is ad-hoc signed (no Apple Developer ID)."
echo "Your friend will need to right-click > Open on first launch"
echo "and click 'Open' on the Gatekeeper dialog."
