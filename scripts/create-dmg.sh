#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/NotchBot.app"

if [[ ! -d "$APP" ]]; then
  echo "Build NotchBot.app first with scripts/build-app.sh." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+)*([+-][A-Za-z0-9.-]+)?$ ]]; then
  echo "Invalid CFBundleShortVersionString: $VERSION" >&2
  exit 1
fi

DMG="$ROOT/dist/NotchBot-$VERSION.dmg"
CHECKSUM_FILE="$DMG.sha256"

if [[ -e "$DMG" || -L "$DMG" || -e "$CHECKSUM_FILE" || -L "$CHECKSUM_FILE" ]]; then
  echo "$DMG or its checksum already exists; move both aside before packaging again." >&2
  exit 1
fi

if [[ -z "${NOTARIZE+x}" || ( "$NOTARIZE" != "0" && "$NOTARIZE" != "1" ) ]]; then
  echo "Set NOTARIZE=1 to notarize, or NOTARIZE=0 to explicitly skip notarization." >&2
  exit 1
fi

if [[ "$NOTARIZE" == "1" && -z "${NOTARY_PROFILE:-}" ]]; then
  echo "NOTARIZE=1 requires NOTARY_PROFILE." >&2
  exit 1
fi

if [[ "$NOTARIZE" == "0" && -n "${NOTARY_PROFILE:-}" ]]; then
  echo "NOTARY_PROFILE was provided while NOTARIZE=0; refusing to ignore notarization credentials." >&2
  exit 1
fi

codesign --verify --strict --verbose=2 "$APP/Contents/Helpers/notchbot-hook"
codesign --verify --deep --strict --verbose=2 "$APP"
for target in "$APP/Contents/Helpers/notchbot-hook" "$APP"; do
  if ! entitlements="$(codesign -d --entitlements - "$target" 2>/dev/null)"; then
    echo "Unable to inspect entitlements for $target." >&2
    exit 1
  fi
  if [[ "$entitlements" == *"<key>"* ]]; then
    echo "$target contains unexpected entitlements." >&2
    exit 1
  fi
done

signature_info="$(codesign -dv --verbose=4 "$APP" 2>&1)"
if [[ "$NOTARIZE" == "1" && "$signature_info" == *"Signature=adhoc"* ]]; then
  echo "Cannot notarize an ad-hoc signed app. Rebuild with a Developer ID Application identity." >&2
  exit 1
fi
if [[ "$NOTARIZE" == "1" && "$signature_info" != *"Authority=Developer ID Application:"* ]]; then
  echo "Notarization requires a Developer ID Application signature." >&2
  exit 1
fi

hdiutil create -volname "NotchBot" -srcfolder "$APP" -format UDZO "$DMG"

if [[ "$NOTARIZE" == "1" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
else
  echo "Notarization explicitly skipped (NOTARIZE=0)."
fi

hdiutil verify "$DMG"
checksum="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
printf '%s  %s\n' "$checksum" "$(basename "$DMG")" > "$CHECKSUM_FILE"
(cd "$ROOT/dist" && shasum -a 256 -c "$(basename "$CHECKSUM_FILE")")

echo "Created $DMG and $CHECKSUM_FILE"
