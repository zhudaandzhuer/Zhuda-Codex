#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LAUNCHER="${PROJECT_DIR}/launcher/zhuda_web_launcher.py"

if [[ ! -f "$LAUNCHER" ]]; then
  osascript -e 'display alert "Zhuda-Codex Launcher" message "Missing launcher/zhuda_web_launcher.py."' >/dev/null 2>&1 || true
  echo "Missing launcher: $LAUNCHER" >&2
  exit 1
fi

TTY_NAME="$(tty 2>/dev/null || true)"
/usr/bin/python3 "$LAUNCHER" --project-root "$PROJECT_DIR" --platform mac
STATUS=$?

if [[ "$STATUS" -eq 0 && "${ZHUDA_KEEP_LAUNCHER_TERMINAL:-0}" != "1" && -n "$TTY_NAME" ]]; then
  /usr/bin/osascript >/dev/null 2>&1 <<EOF || true
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "$TTY_NAME" then
        close t
        return
      end if
    end repeat
  end repeat
end tell
EOF
fi

exit "$STATUS"
