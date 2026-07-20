#!/usr/bin/env bash
# Build Norunde without full Xcode (Command Line Tools + macOS SDK).
# Produces: build/Norunde.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path)"
OUT_APP="$ROOT/build/Norunde.app"
OUT_CONTENTS="$OUT_APP/Contents"
SRC_ROOT="$ROOT/App/Norunde/Norunde"

mkdir -p "$OUT_CONTENTS/MacOS" "$OUT_CONTENTS/Resources"

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

echo "==> Compiling Norunde (sdk=$SDK)"
swiftc -O \
  -sdk "$SDK" \
  -target arm64-apple-macosx14.0 \
  -parse-as-library \
  -o "$OUT_CONTENTS/MacOS/Norunde" \
  "${SOURCES[@]}"

cp "$SRC_ROOT/Resources/Info.plist" "$OUT_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Norunde" "$OUT_CONTENTS/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.norunde" "$OUT_CONTENTS/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleName Norunde" "$OUT_CONTENTS/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 14.0" "$OUT_CONTENTS/Info.plist" >/dev/null

echo "==> Built $OUT_APP"
echo "    open \"$OUT_APP\""
