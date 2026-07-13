#!/bin/bash
# Build ChromeProfileSelector from source, install it to /Applications, and
# set it as the default browser (macOS asks you to confirm).
# Safe to re-run after editing src/main.swift or src/Info.plist.
#
# Requires: macOS 12+, Xcode Command Line Tools (xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

APP="${APP_DIR:-/Applications}/Chrome Profile Selector.app"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "error: swiftc not found. Install the Xcode Command Line Tools first:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi

echo "Building..."
mkdir -p "$APP/Contents/MacOS"
swiftc -O src/main.swift -o "$APP/Contents/MacOS/ChromeProfileSelector"
cp src/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp src/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign and register with Launch Services so macOS sees a browser.
codesign --force --sign - "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Installed $APP"

# Make it the default browser. macOS shows its own confirmation dialog, so
# this is always safe to attempt; skipped automatically if already default.
swift -e "
import AppKit
let ws = NSWorkspace.shared
let appURL = URL(fileURLWithPath: \"$APP\")
if ws.urlForApplication(toOpen: URL(string: \"http://example.com\")!) == appURL {
    print(\"Already the default browser — all set.\")
    exit(0)
}
print(\"Requesting default-browser change — click 'Use Chrome Profile Selector' in the dialog...\")
let sem = DispatchSemaphore(value: 0)
var code: Int32 = 0
ws.setDefaultApplication(at: appURL, toOpenURLsWithScheme: \"http\") { error in
    if let error = error {
        print(\"Not set (\(error.localizedDescription)). You can set it any time in System Settings → Desktop & Dock → Default web browser.\")
        code = 1
    } else {
        print(\"Default browser set — all set. Try: open https://example.com\")
    }
    sem.signal()
}
if sem.wait(timeout: .now() + 300) == .timedOut {
    print(\"No response to the dialog. You can set it any time in System Settings → Desktop & Dock → Default web browser.\")
    code = 1
}
exit(code)
" || true
