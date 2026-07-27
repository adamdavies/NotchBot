#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/NotchBot.app"
DMG="$ROOT/dist/NotchBot-0.1.0.dmg"

if [[ ! -d "$APP" ]]; then
  echo "Build NotchBot.app first with scripts/build-app.sh." >&2
  exit 1
fi

if [[ -e "$DMG" ]]; then
  echo "$DMG already exists; move it aside before packaging again." >&2
  exit 1
fi

hdiutil create -volname "NotchBot" -srcfolder "$APP" -ov -format UDZO "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "Created $DMG"
