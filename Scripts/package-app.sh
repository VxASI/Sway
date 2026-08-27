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

# Ad-hoc signature with a fixed identifier: TCC keys the Screen Recording and
# Input Monitoring grants off it, so without this every rebuild looks like a
# different app and the permissions have to be granted again.
codesign --force --sign - --identifier ai.sway.Sway --timestamp=none "$APP"

echo "built $APP"
