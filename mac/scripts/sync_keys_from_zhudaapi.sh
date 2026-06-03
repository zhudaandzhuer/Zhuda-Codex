#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ENV="${1:-${ZHUDAAPI_ENV_PATH:-}}"
TARGET_ENV="$ROOT_DIR/.env"

if [[ -z "$SOURCE_ENV" ]]; then
  CANDIDATE="$ROOT_DIR/../ZhudaAPI/server/.env"
  if [[ -f "$CANDIDATE" ]]; then
    SOURCE_ENV="$CANDIDATE"
  fi
fi

if [[ ! -f "$SOURCE_ENV" ]]; then
  echo "source env not found. Pass /path/to/ZhudaAPI/server/.env or set ZHUDAAPI_ENV_PATH." >&2
  exit 1
fi

raw_keys="$(
  awk -F= '
    /^GEMINI_API_KEYS=/ {
      value=$0
      sub(/^GEMINI_API_KEYS=/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$SOURCE_ENV"
)"

if [[ -z "$raw_keys" ]]; then
  echo "GEMINI_API_KEYS missing in $SOURCE_ENV" >&2
  exit 1
fi

IFS=',' read -r -a keys <<< "$raw_keys"
if [[ "${#keys[@]}" -lt 10 ]]; then
  echo "expected at least 10 Gemini keys, found ${#keys[@]}" >&2
  exit 1
fi

test_key_index="${ZHUDA_TEST_KEY_INDEX:-10}"
if ! [[ "$test_key_index" =~ ^[0-9]+$ ]] || [[ "$test_key_index" -lt 1 ]] || [[ "$test_key_index" -gt "${#keys[@]}" ]]; then
  echo "invalid ZHUDA_TEST_KEY_INDEX: $test_key_index" >&2
  exit 1
fi
single_key="$(printf '%s' "${keys[$((test_key_index - 1))]}" | xargs)"

{
  echo "# Generated from $SOURCE_ENV"
  echo "# Do not commit this file."
  echo "LITELLM_MASTER_KEY=zhuda-codex-local-token"
  echo "LITELLM_API_KEY=zhuda-codex-local-token"
  echo "ZHUDA_FORCE_UPSTREAM_MODEL=gemini-3.1-flash-lite"
  echo "ZHUDA_GEMINI_MODELS=gemini-codex=gemini-3.1-flash-lite,gemini-flash-lite=gemini-3.1-flash-lite,gemini:flash-lite-3-1=gemini-3.1-flash-lite,gemini-flash=gemini-3.1-flash-lite,gemini:flash-3=gemini-3.1-flash-lite,gemini-flash-3-5=gemini-3.1-flash-lite,gemini:flash-3-5=gemini-3.1-flash-lite,gemma-26b=gemini-3.1-flash-lite,gemini:gemma-4-26b=gemini-3.1-flash-lite,gemma-31b=gemini-3.1-flash-lite,gemini:gemma-4-31b=gemini-3.1-flash-lite"
  echo "ZHUDA_MAX_INPUT_TOKENS=12000"
  echo "ZHUDA_MAX_PINNED_TOKENS=2500"
  echo "ZHUDA_MAX_HISTORY_ITEM_TOKENS=1500"
  echo "ZHUDA_MAX_TOOL_OUTPUT_CHARS=1500"
  echo "ZHUDA_MAX_KEY_ATTEMPTS=1"
  echo "ZHUDA_MAX_MODEL_ATTEMPTS=1"
  echo "ZHUDA_UPSTREAM_TIMEOUT_SECONDS=60"
  echo "ZHUDA_DISABLE_REPEAT_GUARDS=true"
  echo "ZHUDA_MAX_REPEAT_VISUAL_TOOL_CALLS=3"
  echo "ZHUDA_MAX_REPEAT_TOOL_CALLS=4"
  echo "ZHUDA_REPEAT_TOOL_LOOKBACK_ITEMS=60"
  echo "ZHUDA_IMAGE_LOOKBACK_ITEMS=24"
  echo "ZHUDA_MAX_INLINE_IMAGES=2"
  echo "ZHUDA_MAX_INLINE_IMAGE_BYTES=5000000"
  echo "ZHUDA_MAX_INLINE_IMAGE_TOTAL_BYTES=6000000"
  echo "ZHUDA_MAX_DECLARED_TOOLS=96"
  echo "ZHUDA_LARGE_PROMPT_TOKEN_THRESHOLD=30000"
  echo "ZHUDA_LARGE_PROMPT_MAX_INLINE_IMAGES=1"
  echo "ZHUDA_LARGE_PROMPT_MAX_MODEL_ATTEMPTS=1"
  echo "ZHUDA_LARGE_PROMPT_MIN_INTERVAL_MS=15000"
  echo "ZHUDA_LARGE_PROMPT_RATE_LIMIT_COOLDOWN_SECONDS=120"
  echo "ZHUDA_RATE_LIMIT_COOLDOWN_SECONDS=45"
  echo "ZHUDA_ERROR_COOLDOWN_SECONDS=10"
  echo "ZHUDA_GLOBAL_MIN_INTERVAL_MS=1000"
  echo "ZHUDA_MODEL_MIN_INTERVALS_MS=gemini-3.1-flash-lite:6000,gemini-3.5-flash:12000,gemini-3-flash-preview:12000,gemma-4-26b-a4b-it:6000,gemma-4-31b-it:6000"
  echo "ZHUDA_GEMINI_FALLBACK_MODELS=none"
  echo "GEMINI_API_KEY_1=${single_key}"
} > "$TARGET_ENV"

chmod 600 "$TARGET_ENV"
echo "wrote $TARGET_ENV with 1 Gemini key from source index $test_key_index"
