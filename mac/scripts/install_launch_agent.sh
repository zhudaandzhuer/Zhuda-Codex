#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.zhuda.codex.adapter"
RUNTIME_DIR="$HOME/.zhuda-codex"
TARGET_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
UVICORN="$RUNTIME_DIR/.venv/bin/uvicorn"

mkdir -p "$RUNTIME_DIR"
cp "$ROOT_DIR/zhuda_gemini_pool_adapter.py" "$RUNTIME_DIR/zhuda_gemini_pool_adapter.py"
if [[ -f "$ROOT_DIR/.env" ]]; then
  cp "$ROOT_DIR/.env" "$RUNTIME_DIR/.env"
fi

if [[ ! -x "$UVICORN" ]]; then
  UVICORN="$(command -v uvicorn || true)"
fi
if [[ -z "$UVICORN" ]]; then
  echo "uvicorn not found. Run ./scripts/setup.sh first or install uvicorn." >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$TARGET_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${UVICORN}</string>
    <string>zhuda_gemini_pool_adapter:app</string>
    <string>--host</string>
    <string>127.0.0.1</string>
    <string>--port</string>
    <string>4000</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${RUNTIME_DIR}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${RUNTIME_DIR}/adapter.out.log</string>
  <key>StandardErrorPath</key>
  <string>${RUNTIME_DIR}/adapter.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$TARGET_PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$TARGET_PLIST"
launchctl enable "gui/$(id -u)/${LABEL}"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"

echo "installed and started ${LABEL}"
