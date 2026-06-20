#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/说入法.app"
ICON_SOURCE="$ROOT/Packaging/AppIcon.png"
ICON_TARGET="$ROOT/Packaging/AppIcon.icns"
ICON_GENERATOR="$ROOT/Scripts/generate_app_icon.swift"

cd "$ROOT"
swift build -c release

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ ! -f "$ICON_TARGET" || "$ICON_SOURCE" -nt "$ICON_TARGET" || "$ICON_GENERATOR" -nt "$ICON_TARGET" ]]; then
    swift "$ICON_GENERATOR" "$ICON_TARGET"
fi
cp -f "$ROOT/.build/release/VoiceTyper" "$APP/Contents/MacOS/VoiceTyper"
cp -f "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp -f "$ICON_TARGET" "$APP/Contents/Resources/AppIcon.icns"

SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"
/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP" >/dev/null

echo "$APP"
