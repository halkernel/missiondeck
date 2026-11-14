#!/usr/bin/env bash
# Builds MissionDeck.app into ./build
#   ./build.sh            build only
#   ./build.sh --install  build, copy to /Applications and launch
#
# Optional: CODESIGN_IDENTITY="Your Certificate Name" ./build.sh
# (a stable signing identity means macOS remembers the Accessibility permission across rebuilds)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MissionDeck"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"   # "-" = ad-hoc signature

echo "▶ Compiling…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP_DIR="build/${APP_NAME}.app"
echo "▶ Assembling ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
if command -v iconutil >/dev/null 2>&1; then
    iconutil -c icns Resources/AppIcon.iconset -o "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

echo "▶ Signing (identity: ${SIGN_IDENTITY})"
codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"

if [[ "${1:-}" == "--install" ]]; then
    echo "▶ Installing to /Applications"
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP_DIR" /Applications/
    open "/Applications/${APP_NAME}.app"
fi

echo "✓ Done: ${APP_DIR}"
