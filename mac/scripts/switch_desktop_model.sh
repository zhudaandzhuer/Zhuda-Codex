#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$CODEX_HOME_DIR/config.toml"

if [[ -z "$MODEL" ]]; then
  cat >&2 <<'EOF'
Usage:
  ./scripts/switch_desktop_model.sh <model-id>

Known model ids:
  gemini-codex
  gemini-flash-lite
  gemini-flash
  gemini-flash-3-5
  gemma-26b
  gemma-31b
EOF
  exit 1
fi

python3 - "$CONFIG" "$MODEL" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
model = sys.argv[2]
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

text = set_top_level_string("model", model, text)
text = set_top_level_string("model_provider", "zhuda_gemini_pool", text)
text = set_top_level_number("model_context_window", 49152, text)
text = set_top_level_number("model_auto_compact_token_limit", 32000, text)
text = set_top_level_number("tool_output_token_limit", 4000, text)
path.write_text(text)
PY

echo "Codex Desktop model set to ${MODEL} via zhuda_gemini_pool."
echo "Context window set to 49152 and auto compact threshold set to 32000."
echo "Restart Codex Desktop or start a new local thread for the change to apply."
