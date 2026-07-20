#!/usr/bin/env bash
# Build Norunde.app and package a drag-to-Applications DMG under dist/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCHS="${ARCHS:-universal}"
APP_NAME="Norunde"
VOL_NAME="Norunde ${VERSION}"
DIST_DIR="$ROOT/dist"
STAGE_DIR="$ROOT/build/dmg-stage"
DMG_RW="$ROOT/build/${APP_NAME}-${VERSION}-rw.dmg"
DMG_OUT="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

export VERSION BUILD_NUMBER ARCHS
bash "$ROOT/scripts/build-app.sh"

APP_SRC="$ROOT/build/${APP_NAME}.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "Missing app bundle: $APP_SRC" >&2
  exit 1
fi

rm -rf "$STAGE_DIR" "$DMG_RW" "$DMG_OUT"
mkdir -p "$STAGE_DIR" "$DIST_DIR"

# Stage classic layout: App + Applications symlink
cp -R "$APP_SRC" "$STAGE_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGE_DIR/Applications"

# Approx size: app + headroom
APP_KB=$(du -sk "$STAGE_DIR" | awk '{print $1}')
SIZE_MB=$(( (APP_KB / 1024) + 20 ))
if (( SIZE_MB < 30 )); then SIZE_MB=30; fi

echo "==> Creating DMG (${SIZE_MB}MB) → $DMG_OUT"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_OUT" >/dev/null

# Optional ad-hoc sign of the dmg (harmless if it fails)
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$DMG_OUT" >/dev/null 2>&1 || true
fi

rm -rf "$STAGE_DIR"
echo "==> DMG ready: $DMG_OUT"
ls -lh "$DMG_OUT"
shasum -a 256 "$DMG_OUT" | tee "$DMG_OUT.sha256"
