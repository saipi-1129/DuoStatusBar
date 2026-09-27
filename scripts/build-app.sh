#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h}/.."
APP_DIR="$ROOT_DIR/build/DuoStatusBar.app"

swift build --package-path "$ROOT_DIR" -c release
BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/DuoStatusBar" "$APP_DIR/Contents/MacOS/DuoStatusBar"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Workspace folders can attach Finder/FileProvider metadata to generated bundles.
# Clear the bundle root once more after the recursive pass so codesign sees a
# clean bundle even when Finder re-adds its metadata asynchronously.
xattr -rc "$APP_DIR" 2>/dev/null || true
xattr -c "$APP_DIR" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "Built: $APP_DIR"
