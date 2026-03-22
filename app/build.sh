#!/bin/bash
set -e

APP="SpankTheAgent.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

echo "▶ Building Go helper binary..."
cd "$(dirname "$0")/.."
/opt/homebrew/bin/go build -o app/spank-the-agent-helper .
cd app

echo "▶ Compiling Swift app..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

swiftc \
    Sources/main.swift \
    Sources/AppDelegate.swift \
    -o "$MACOS/SpankTheAgent" \
    -framework Cocoa

echo "▶ Generating app icon..."
swift generate_icon.swift
iconutil -c icns AppIcon.iconset -o AppIcon.icns

echo "▶ Copying resources..."
cp Sources/Info.plist "$APP/Contents/Info.plist"
cp spank-the-agent-helper "$RESOURCES/spank-the-agent-helper"
chmod +x "$RESOURCES/spank-the-agent-helper"
cp AppIcon.icns "$RESOURCES/AppIcon.icns"

echo "▶ Ad-hoc signing..."
codesign --force --deep --sign - "$APP"

echo "▶ Done → $APP"
echo ""
echo "To install: drag $APP to /Applications"
echo "To run now:"
open "$APP"
