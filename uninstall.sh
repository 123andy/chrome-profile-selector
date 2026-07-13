#!/bin/bash
# Remove ChromeProfileSelector completely.
set -euo pipefail

APP="${APP_DIR:-/Applications}/Chrome Profile Selector.app"

if [[ ! -d "$APP" ]]; then
    echo "$APP not found — nothing to do."
    exit 0
fi

# Read the bundle id from the installed app so this works whatever it was built with.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null || echo "org.chromeprofileselector")

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" || true
rm -rf "$APP"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo "Removed $APP and its saved preferences ($BUNDLE_ID)."
echo "Pick a new default browser in System Settings → Desktop & Dock (until then, macOS falls back to Safari)."
