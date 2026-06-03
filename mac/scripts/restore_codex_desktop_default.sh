#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$CODEX_HOME_DIR/config.toml"
BACKUP="$CODEX_HOME_DIR/config.toml.before-zhuda-adapter"
LEGACY_BACKUP="$CODEX_HOME_DIR/config.toml.before-zhuda-gemini-pool"

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

if [[ ! -f "$BACKUP" && -f "$LEGACY_BACKUP" ]]; then
  BACKUP="$LEGACY_BACKUP"
fi

if [[ ! -f "$BACKUP" ]]; then
  echo "backup not found: $BACKUP" >&2
  exit 1
fi

close_codex_desktop

cp "$BACKUP" "$CONFIG"
echo "Codex config restored from $BACKUP."
open_codex_desktop
