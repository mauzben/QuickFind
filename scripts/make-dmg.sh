#!/bin/bash
# Builds QuickFind.app and packs it into build/QuickFind.dmg (drag & drop into Applications).
set -euo pipefail
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cd "$(dirname "$0")/.."

./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE="$STAGE_ROOT/QuickFind"
mkdir -p "$STAGE"
cp -R build/app.noindex/QuickFind.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="build/QuickFind-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "QuickFind $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
# Keep build copies out of Launchpad/"Apps": only the installed app should be registered.
"$LSREGISTER" -u "$STAGE/QuickFind.app" 2>/dev/null || true
echo "DMG: $(pwd)/$DMG"
