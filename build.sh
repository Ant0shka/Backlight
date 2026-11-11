#!/bin/zsh
# Build Backlight.app. `./build.sh install` also copies it to ~/Applications and (re)launches it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Backlight.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Backlight "$APP/Contents/MacOS/Backlight"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Backlight 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Backlight.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Backlight.app
    echo "Installed to ~/Applications/Backlight.app"
fi
