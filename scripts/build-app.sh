#!/usr/bin/env bash
# Builds DevPilot.app from the Swift package and signs it for local use.
#
#   scripts/build-app.sh            # build/DevPilot.app (release)
#   scripts/build-app.sh --install  # also copy to /Applications
#
# SIGN_IDENTITY selects the signing identity (default "-" = ad-hoc). Use a stable identity,
# e.g. "Apple Development: you@example.com (TEAMID)", so Keychain access survives rebuilds.
# The app is intentionally NOT sandboxed: it must launch git, codex and test commands.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/DevPilot.app"

swift build -c "$CONFIG" --product DevPilot
BIN_DIR="$(swift build -c "$CONFIG" --product DevPilot --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DevPilot" "$APP/Contents/MacOS/DevPilot"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # regenerate with: swift scripts/make-icon.swift
# SwiftPM resource bundles of dependencies, if any.
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $SIGN_IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/DevPilot.app
    ditto "$APP" /Applications/DevPilot.app
    echo "Installed /Applications/DevPilot.app"
fi
