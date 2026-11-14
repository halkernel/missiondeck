#!/usr/bin/env bash
# Removes MissionDeck completely from this Mac.
# (You can also use "Uninstall MissionDeck…" from the menu bar icon.)
set -uo pipefail
APP_NAME="MissionDeck"
HERE="$(cd "$(dirname "$0")" && pwd)"

# The test build's ID, plus the release IDs from release.config if it's filled in.
IDS=("com.local.MissionDeck")
if [[ -f "$HERE/release.config" ]]; then
    # shellcheck source=release.config
    RELEASE_ID="$(unset BUNDLE_ID; source "$HERE/release.config"; printf '%s' "$BUNDLE_ID")"
    if [[ -n "$RELEASE_ID" ]]; then
        IDS+=("$RELEASE_ID")
    fi
fi

echo "▶ Quitting MissionDeck"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

echo "▶ Removing the app"
rm -rf "/Applications/${APP_NAME}.app" "$HOME/Applications/${APP_NAME}.app"

echo "▶ Removing permissions, settings and logs"
for BUNDLE_ID in "${IDS[@]}"; do
    # Only a well-formed app ID: an empty or odd value must never widen the paths below.
    [[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { echo "  Skipping odd app ID: $BUNDLE_ID"; continue; }
    tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Preferences/${BUNDLE_ID}.plist" \
           "$HOME/Library/Caches/${BUNDLE_ID}" \
           "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"
done
rm -rf "$HOME/Library/Logs/${APP_NAME}"
echo "  If MissionDeck still shows under System Settings → Privacy & Security → Accessibility,"
echo "  remove it there."

echo "▶ Removing build caches (finished installers in dist/ are kept)"
cd "$HERE" && rm -rf .build .build-release build

echo "✓ MissionDeck is uninstalled. You can delete this folder now."
echo "  If it still shows under System Settings → General → Login Items, remove it there."
