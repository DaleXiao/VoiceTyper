#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/说入法.app"

cd "$ROOT"
swift build -c release

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swift "$ROOT/Scripts/generate_app_icon.swift" "$ROOT/Packaging/AppIcon.icns"
cp -f "$ROOT/.build/release/VoiceTyper" "$APP/Contents/MacOS/VoiceTyper"
cp -f "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp -f "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"
/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP" >/dev/null

echo "$APP"
