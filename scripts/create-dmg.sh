#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h}/.."
RELEASE_DIR="$ROOT_DIR/build/releases"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")
ARCH=$(uname -m)
DMG_PATH="$RELEASE_DIR/DuoStatusBar-$VERSION-$ARCH.dmg"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/DuoStatusBar-dmg.XXXXXX")
MOUNT_POINT="$STAGING/mounted"
MOUNTED=0

cleanup() {
    if (( MOUNTED )); then
        hdiutil detach "$MOUNT_POINT" -quiet || true
    fi
    rm -rf "$STAGING"
}
trap cleanup EXIT

mkdir -p "$STAGING/image" "$MOUNT_POINT" "$RELEASE_DIR"
swift build --package-path "$ROOT_DIR" -c release --scratch-path "$STAGING/swiftpm"
mkdir -p "$STAGING/image/DuoStatusBar.app/Contents/MacOS" "$STAGING/image/DuoStatusBar.app/Contents/Resources"
cp "$STAGING/swiftpm/release/DuoStatusBar" "$STAGING/image/DuoStatusBar.app/Contents/MacOS/DuoStatusBar"
cp "$ROOT_DIR/Resources/Info.plist" "$STAGING/image/DuoStatusBar.app/Contents/Info.plist"
xattr -cr "$STAGING/image/DuoStatusBar.app"
codesign --force --deep --sign - "$STAGING/image/DuoStatusBar.app"
codesign --verify --deep --strict "$STAGING/image/DuoStatusBar.app"
ln -s /Applications "$STAGING/image/Applications"

hdiutil create -ov -format UDZO -volname "DuoStatusBar $VERSION" \
    -srcfolder "$STAGING/image" "$DMG_PATH"
hdiutil verify "$DMG_PATH"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null
MOUNTED=1
test -d "$MOUNT_POINT/DuoStatusBar.app/Contents/MacOS"
test -L "$MOUNT_POINT/Applications"
hdiutil detach "$MOUNT_POINT" -quiet
MOUNTED=0

shasum -a 256 "$DMG_PATH"
print -r -- "Created and verified: $DMG_PATH"
