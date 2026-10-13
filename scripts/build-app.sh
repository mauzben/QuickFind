#!/bin/bash
# Builds QuickFind.app (release, ad-hoc signed) and the qf command line tool into ./build
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

# Assemble and sign outside the project folder: on the Desktop, macOS may attach Finder
# attributes to new files at any time, which makes codesign fail.
WORK="$(mktemp -d)"
APP="$WORK/QuickFind.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/QuickFind" "$APP/Contents/MacOS/QuickFind"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

swift scripts/make-icon.swift "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

xattr -cr "$APP"
# Stable identity (see scripts/create-signing-identity.sh) keeps Full Disk Access across updates.
IDENTITY="QuickFind Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then SIGN="$IDENTITY"; else SIGN="-"; fi
codesign --force --sign "$SIGN" --timestamp=none "$APP"

# "*.noindex": Spotlight/LaunchServices ignore it, so the build copy never appears as a second app.
mkdir -p build/app.noindex
rm -rf build/QuickFind.app build/app.noindex/QuickFind.app
ditto "$APP" build/app.noindex/QuickFind.app
cp "$BIN/qf" build/qf
rm -rf "$WORK"
codesign --verify build/app.noindex/QuickFind.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$(pwd)/build/app.noindex/QuickFind.app" 2>/dev/null || true
echo "Fertig: $(pwd)/build/app.noindex/QuickFind.app"
echo "CLI:    $(pwd)/build/qf"
