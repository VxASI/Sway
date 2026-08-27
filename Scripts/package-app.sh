#!/bin/bash
# Builds Sway.app, a normal double-clickable macOS application, out of the
# SwayApp executable target.
#
#   ./Scripts/package-app.sh [debug|release]   ->  .build/Sway.app
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/Sway.app"

swift build -c "$CONFIGURATION" --product SwayApp --package-path "$ROOT"
BINARY="$(swift build -c "$CONFIGURATION" --product SwayApp --package-path "$ROOT" --show-bin-path)/SwayApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Sway"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# TCC keys the Screen Recording and Input Monitoring grants off the signing
# identity. A real "Apple Development" certificate keeps that identity stable
# across rebuilds, so the grants survive; ad-hoc signing does not, and macOS
# then silently ignores the old grant - which shows up as ScreenCaptureKit
# returning nothing, or hanging, rather than as an error.
IDENTITY="${SWAY_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')"
fi

if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --identifier ai.sway.Sway --timestamp=none "$APP"
  echo "signed with: $IDENTITY"
else
  codesign --force --sign - --identifier ai.sway.Sway --timestamp=none "$APP"
  echo "signed ad-hoc (no developer certificate found)."
  # The previous grant no longer applies to this build, and a stale entry makes
  # macOS skip the prompt entirely. Clearing it restores the first-run flow.
  tccutil reset ScreenCapture ai.sway.Sway >/dev/null 2>&1 || true
  tccutil reset ListenEvent ai.sway.Sway >/dev/null 2>&1 || true
  echo "cleared this build's TCC entries - Sway will ask for permission again."
fi

echo "built $APP"
