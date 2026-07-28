#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/NotchBot.app"

verify_no_entitlements() {
  local target="$1"
  local entitlements
  if ! entitlements="$(codesign -d --entitlements - "$target" 2>/dev/null)"; then
    echo "Unable to inspect entitlements for $target." >&2
    exit 1
  fi
  if [[ "$entitlements" == *"<key>"* ]]; then
    echo "$target contains unexpected entitlements." >&2
    exit 1
  fi
}

if [[ -e "$APP" ]]; then
  echo "$APP already exists; move it aside before building again." >&2
  exit 1
fi

if [[ "${ALLOW_ADHOC_RELEASE:-0}" != "0" && "${ALLOW_ADHOC_RELEASE:-0}" != "1" ]]; then
  echo "ALLOW_ADHOC_RELEASE must be 0 or 1." >&2
  exit 1
fi

IDENTITY="${SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  while IFS= read -r identity_line; do
    if [[ "$identity_line" =~ \"(Developer\ ID\ Application:[^\"]+)\" ]]; then
      IDENTITY="${BASH_REMATCH[1]}"
      break
    fi
  done < <(security find-identity -v -p codesigning 2>/dev/null || true)
fi

if [[ "$IDENTITY" == "-" && "${ALLOW_ADHOC_RELEASE:-0}" != "1" ]]; then
  echo "SIGNING_IDENTITY=- requires ALLOW_ADHOC_RELEASE=1." >&2
  exit 1
fi

SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" == "-" ]]; then
  echo "Signing ad-hoc because ALLOW_ADHOC_RELEASE=1"
elif [[ -n "$IDENTITY" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
  echo "Signing with $IDENTITY"
elif [[ "${ALLOW_ADHOC_RELEASE:-0}" == "1" ]]; then
  IDENTITY="-"
  SIGN_ARGS=(--force --sign "$IDENTITY")
  echo "Signing ad-hoc because ALLOW_ADHOC_RELEASE=1"
else
  echo "No Developer ID Application identity found. Set SIGNING_IDENTITY, or explicitly allow a local ad-hoc build with ALLOW_ADHOC_RELEASE=1." >&2
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

codesign "${SIGN_ARGS[@]}" "$APP/Contents/Helpers/notchbot-hook"
codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT/Packaging/NotchBot.entitlements" "$APP"

codesign --verify --strict --verbose=2 "$APP/Contents/Helpers/notchbot-hook"
codesign --verify --deep --strict --verbose=2 "$APP"
verify_no_entitlements "$APP/Contents/Helpers/notchbot-hook"
verify_no_entitlements "$APP"

echo "Built $APP"
