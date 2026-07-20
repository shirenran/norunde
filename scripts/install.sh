#!/usr/bin/env bash
# Build Norunde and install to ~/Applications/Norunde.app
# Optional: --login to enable open-at-login via LaunchAgent
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${HOME}/Applications"
INSTALL_APP="${INSTALL_DIR}/Norunde.app"
LABEL="app.norunde.login"
LEGACY_LABELS=("dev.shirenran.norunde.login")
AGENT_PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
ENABLE_LOGIN=0

for arg in "$@"; do
  case "$arg" in
    --login) ENABLE_LOGIN=1 ;;
    --no-login) ENABLE_LOGIN=0 ;;
    -h|--help)
      echo "Usage: bash scripts/install.sh [--login]"
      echo "  Build + install Norunde to ~/Applications/Norunde.app"
      echo "  --login  also enable open-at-login"
      exit 0
      ;;
  esac
done

bash "$ROOT/scripts/build-app.sh"

mkdir -p "$INSTALL_DIR"
# Replace existing install atomically-ish
rm -rf "${INSTALL_APP}.tmp"
cp -R "$ROOT/build/Norunde.app" "${INSTALL_APP}.tmp"
rm -rf "$INSTALL_APP"
mv "${INSTALL_APP}.tmp" "$INSTALL_APP"

# Ad-hoc sign so Gatekeeper is less noisy for personal use
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$INSTALL_APP" >/dev/null 2>&1 || true
fi

echo "==> Installed $INSTALL_APP"

if [[ "$ENABLE_LOGIN" -eq 1 ]]; then
  mkdir -p "${HOME}/Library/LaunchAgents"
  EXEC="${INSTALL_APP}/Contents/MacOS/Norunde"
  UID_NUM="$(id -u)"
  # Clean pre-open-source personal LaunchAgent labels
  for legacy in "${LEGACY_LABELS[@]}"; do
    launchctl bootout "gui/${UID_NUM}/${legacy}" >/dev/null 2>&1 || true
    rm -f "${HOME}/Library/LaunchAgents/${legacy}.plist"
  done
  cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${EXEC}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${UID_NUM}" "$AGENT_PLIST" >/dev/null 2>&1 \
    || launchctl load -w "$AGENT_PLIST" >/dev/null 2>&1 || true
  echo "==> Login item enabled (${AGENT_PLIST})"
fi

echo ""
echo "Start now:"
echo "  open \"$INSTALL_APP\""
echo ""
echo "Enable login later:"
echo "  bash scripts/install.sh --login"
echo "Or in app footer: toggle 「开机自启」"
