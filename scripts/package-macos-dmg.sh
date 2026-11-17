#!/bin/bash
# Package StampSign.app with a drag-and-drop Applications shortcut.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 /path/to/StampSign.app /path/to/StampSign.dmg" >&2
  exit 2
fi

APP="$1"
DMG="$2"
VOLUME="StampSign"
STAGE_ROOT="$(mktemp -d)"
STAGE="$STAGE_ROOT/$VOLUME"

if [ ! -d "$APP" ]; then
  echo "application bundle not found: $APP" >&2
  exit 1
fi

# Match the existing Rondo release flow: ad-hoc sign the app bundle before putting it in the image.
codesign --force --deep --sign - "$APP"
mkdir -p "$STAGE" "$(dirname "$DMG")"
cp -R "$APP" "$STAGE/StampSign.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

echo "Created $DMG"
