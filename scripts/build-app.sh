#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/NotchBot.app"

if [[ -e "$APP" ]]; then
  echo "$APP already exists; move it aside before building again." >&2
  exit 1
fi

swift build --package-path "$ROOT" -c release
BIN_DIR="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
swift "$ROOT/Tools/generate-app-icon.swift"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_DIR/NotchBot" "$APP/Contents/MacOS/NotchBot"
cp "$BIN_DIR/notchbot-hook" "$APP/Contents/Helpers/notchbot-hook"
cp "$ROOT/Sources/NotchBot/Resources/RobotAtlas.png" "$APP/Contents/Resources/RobotAtlas.png"
cp "$ROOT/Sources/NotchBot/Resources/RobotAtlas.json" "$APP/Contents/Resources/RobotAtlas.json"
cp "$ROOT/Packaging/NotchBot.icns" "$APP/Contents/Resources/NotchBot.icns"

IDENTITY="${SIGNING_IDENTITY:--}"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Helpers/notchbot-hook"
codesign --force --options runtime --timestamp --entitlements "$ROOT/Packaging/NotchBot.entitlements" --sign "$IDENTITY" "$APP"

echo "Built $APP"
