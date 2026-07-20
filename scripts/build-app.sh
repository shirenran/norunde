#!/usr/bin/env bash
# Build Norunde without full Xcode (Command Line Tools + macOS SDK).
# Produces: build/Norunde.app (universal arm64 + x86_64 by default)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path)"
OUT_APP="$ROOT/build/Norunde.app"
OUT_CONTENTS="$OUT_APP/Contents"
SRC_ROOT="$ROOT/App/Norunde/Norunde"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_MACOS="${MIN_MACOS:-14.0}"
# universal | arm64 | x86_64
ARCHS="${ARCHS:-universal}"

SOURCES=(
  "$SRC_ROOT/App/AppDelegate.swift"
  "$SRC_ROOT/App/EditorPanelController.swift"
  "$SRC_ROOT/App/LogWindowController.swift"
  "$SRC_ROOT/App/NorundeApp.swift"
  "$SRC_ROOT/App/SingleInstance.swift"
  "$SRC_ROOT/Models/AppConfig.swift"
  "$SRC_ROOT/Models/Project.swift"
  "$SRC_ROOT/Models/ProjectStatus.swift"
  "$SRC_ROOT/Services/ExternalProcessFinder.swift"
  "$SRC_ROOT/Services/LogBuffer.swift"
  "$SRC_ROOT/Services/LoginItemService.swift"
  "$SRC_ROOT/Services/PackageJsonParser.swift"
  "$SRC_ROOT/Services/PathEnvironment.swift"
  "$SRC_ROOT/Services/PortDetector.swift"
  "$SRC_ROOT/Services/ProcessManager.swift"
  "$SRC_ROOT/Services/ProjectStore.swift"
  "$SRC_ROOT/Utilities/DirectoryPicker.swift"
  "$SRC_ROOT/Utilities/ShellQuote.swift"
  "$SRC_ROOT/ViewModels/AppViewModel.swift"
  "$SRC_ROOT/Views/LogView.swift"
  "$SRC_ROOT/Views/MenuBarView.swift"
  "$SRC_ROOT/Views/ProjectDetailView.swift"
  "$SRC_ROOT/Views/ProjectEditorView.swift"
  "$SRC_ROOT/Views/ProjectListView.swift"
  "$SRC_ROOT/Views/StatusBadgeView.swift"
)

compile_one() {
  local target="$1"
  local out="$2"
  echo "==> Compiling ($target)"
  swiftc -O \
    -sdk "$SDK" \
    -target "$target" \
    -parse-as-library \
    -o "$out" \
    "${SOURCES[@]}"
}

rm -rf "$OUT_APP"
mkdir -p "$OUT_CONTENTS/MacOS" "$OUT_CONTENTS/Resources"

BIN_OUT="$OUT_CONTENTS/MacOS/Norunde"
case "$ARCHS" in
  arm64)
    compile_one "arm64-apple-macosx${MIN_MACOS}" "$BIN_OUT"
    ;;
  x86_64)
    compile_one "x86_64-apple-macosx${MIN_MACOS}" "$BIN_OUT"
    ;;
  universal)
    TMP_DIR="$(mktemp -d)"
    compile_one "arm64-apple-macosx${MIN_MACOS}" "$TMP_DIR/Norunde-arm64"
    compile_one "x86_64-apple-macosx${MIN_MACOS}" "$TMP_DIR/Norunde-x86_64"
    lipo -create -output "$BIN_OUT" "$TMP_DIR/Norunde-arm64" "$TMP_DIR/Norunde-x86_64"
    rm -rf "$TMP_DIR"
    ;;
  *)
    echo "Unknown ARCHS=$ARCHS (use universal|arm64|x86_64)" >&2
    exit 1
    ;;
esac

cp "$SRC_ROOT/Resources/Info.plist" "$OUT_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Norunde" "$OUT_CONTENTS/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.norunde" "$OUT_CONTENTS/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleName Norunde" "$OUT_CONTENTS/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$OUT_CONTENTS/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$OUT_CONTENTS/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion ${MIN_MACOS}" "$OUT_CONTENTS/Info.plist" >/dev/null

# Build .icns from AppIcon.appiconset when iconutil is available
ICONSET_SRC="$SRC_ROOT/Resources/Assets.xcassets/AppIcon.appiconset"
ICONSET_TMP="$ROOT/build/Norunde.iconset"
if command -v iconutil >/dev/null 2>&1 && [[ -d "$ICONSET_SRC" ]]; then
  rm -rf "$ICONSET_TMP"
  mkdir -p "$ICONSET_TMP"
  # iconutil expects icon_16x16.png / diana.k@example.org / ... / walt.e@example.net
  for f in "$ICONSET_SRC"/icon_*.png; do
    [[ -f "$f" ]] || continue
    cp "$f" "$ICONSET_TMP/$(basename "$f")"
  done
  if iconutil -c icns -o "$OUT_CONTENTS/Resources/AppIcon.icns" "$ICONSET_TMP" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$OUT_CONTENTS/Info.plist" >/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$OUT_CONTENTS/Info.plist" >/dev/null
  fi
  rm -rf "$ICONSET_TMP"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$OUT_APP" >/dev/null 2>&1 || true
fi

echo "==> Built $OUT_APP"
echo "    version ${VERSION} (${BUILD_NUMBER}) archs=${ARCHS}"
file "$BIN_OUT" || true
echo "    open \"$OUT_APP\""
