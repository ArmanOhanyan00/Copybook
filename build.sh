#!/bin/bash
# Builds Copybook.app into ./build. Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

# With Command Line Tools only (no Xcode), the macOS 27 SDK's SwiftUI needs a macro
# plugin that isn't shipped, so build against the 26.x SDK instead.
if [ -z "${SDKROOT:-}" ] && [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  for v in 26.5 26; do
    d="/Library/Developer/CommandLineTools/SDKs/MacOSX$v.sdk"
    if [ -d "$d" ]; then export SDKROOT="$d"; break; fi
  done
fi

# COPYBOOK_UNIVERSAL=1 builds one app that runs natively on both Apple silicon and Intel Macs.
ARCHS=()
if [ "${COPYBOOK_UNIVERSAL:-}" = "1" ]; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Copybook"

APP=build/Copybook.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Copybook"
cp Support/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift Support/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signatures normally identify the app by its exact binary hash, so every rebuild
# looks like a new app to macOS and loses its Accessibility permission. Pinning the
# designated requirement to the bundle identifier keeps that permission across rebuilds.
codesign --force --sign - --identifier local.copybook.app \
  --requirements '=designated => identifier "local.copybook.app"' "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Copybook 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/Copybook.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/Copybook.app
  echo "Installed to ~/Applications/Copybook.app"
fi
