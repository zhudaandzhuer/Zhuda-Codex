#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$CODEX_HOME_DIR/config.toml"
BACKUP="$CODEX_HOME_DIR/config.toml.before-zhuda-adapter"

codex_is_running() {
  osascript -e 'application "Codex" is running' 2>/dev/null | grep -q "true" \
    || pgrep -f "/Applications/Codex.app/Contents/MacOS/Codex" >/dev/null 2>&1
}

close_codex_desktop() {
  if ! codex_is_running; then
    return
  fi

  echo "Closing Codex Desktop..."
  osascript -e 'tell application "Codex" to quit' >/dev/null 2>&1 || true

  for _ in {1..40}; do
    if ! codex_is_running; then
      return
    fi
    sleep 0.25
  done

  echo "Codex Desktop is still running; forcing it closed..."
  pkill -f "/Applications/Codex.app/Contents/MacOS/Codex" >/dev/null 2>&1 || true

  for _ in {1..20}; do
    if ! codex_is_running; then
      return
    fi
    sleep 0.25
  done

  echo "Could not close Codex Desktop." >&2
  exit 1
}

open_codex_desktop() {
  echo "Opening Codex Desktop..."
  open -a "Codex"
}

if [[ ! -f "$CONFIG" ]]; then
  echo "config not found: $CONFIG" >&2
  exit 1
fi

close_codex_desktop

if [[ ! -f "$BACKUP" ]]; then
  cp "$CONFIG" "$BACKUP"
  echo "backup written: $BACKUP"
fi

python3 - "$CONFIG" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

def set_top_level_string(key: str, value: str, source: str) -> str:
    pattern = re.compile(rf'^{re.escape(key)}\s*=.*$', re.MULTILINE)
    if pattern.search(source):
        return pattern.sub(f'{key} = "{value}"', source, count=1)
    return f'{key} = "{value}"\n' + source

def set_top_level_number(key: str, value: int, source: str) -> str:
    pattern = re.compile(rf'^{re.escape(key)}\s*=.*$', re.MULTILINE)
    if pattern.search(source):
        return pattern.sub(f'{key} = {value}', source, count=1)
    return f'{key} = {value}\n' + source

text = set_top_level_string("model", "gemini-codex", text)
text = set_top_level_string("model_provider", "zhuda_gemini_pool", text)
text = set_top_level_number("model_context_window", 49152, text)
text = set_top_level_number("model_auto_compact_token_limit", 32000, text)
text = set_top_level_number("tool_output_token_limit", 4000, text)
path.write_text(text)
PY

echo "Codex Desktop default switched to zhuda_gemini_pool."
open_codex_desktop
