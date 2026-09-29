#!/bin/bash
# Builds "MiSTer FTP.app" for Apple silicon and Intel into ./dist.
#   --install  copies it to /Applications instead (the staging copy is removed,
#              so Spotlight and Launchpad list the app only once)
#   --zip      also packs it as dist/MiSTer-FTP-<version>.zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MiSTer FTP"
APP="dist/${APP_NAME}.app"
MODE="${1:-}"
BUILD_FLAGS=(-c release --arch arm64 --arch x86_64)
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make_icon.swift
fi

swift build "${BUILD_FLAGS[@]}" --product MiSTerFTP
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/MiSTerFTP"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# English and Korean text: each string catalog becomes en.lproj and ko.lproj tables.
for catalog in Resources/*.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough for a locally built app on this Mac.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [ "$MODE" = "--zip" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
  ZIP="dist/MiSTer-FTP-${VERSION}.zip"
  rm -f "$ZIP"
  # ditto keeps the signature, symlinks and extended attributes of the bundle.
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Packed $ZIP"
fi

if [ "$MODE" = "--install" ]; then
  DEST="/Applications/${APP_NAME}.app"
  if pgrep -x "${APP_NAME}" >/dev/null; then
    osascript -e "tell application \"${APP_NAME}\" to quit" || true
    sleep 1
  fi
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  # Make Spotlight, Launchpad and Finder see the new copy right away.
  "$LSREGISTER" -f "$DEST"
  touch "$DEST"
  "$LSREGISTER" -u "$APP" 2>/dev/null || true
  rm -rf dist
  echo "Installed $DEST"
fi
