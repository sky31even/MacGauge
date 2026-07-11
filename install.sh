#!/bin/zsh
# Rebuild MacGauge and reinstall it to /Applications.
set -e
cd "$(dirname "$0")"

osascript -e 'quit app "MacGauge"' 2>/dev/null || true
xcodebuild -project MacGauge.xcodeproj -scheme MacGauge -configuration Release build | grep -E "^\*\*" || true
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/MacGauge-*/Build/Products/Release/MacGauge.app | head -1)
rm -rf /Applications/MacGauge.app
ditto "$APP" /Applications/MacGauge.app
open /Applications/MacGauge.app
echo "Installed and relaunched."
