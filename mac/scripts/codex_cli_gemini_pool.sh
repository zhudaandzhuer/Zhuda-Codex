#!/usr/bin/env bash
set -euo pipefail

exec /Applications/Codex.app/Contents/Resources/codex \
  -c model='"gemini-codex"' \
  -c model_provider='"zhuda_gemini_pool"' \
  "$@"

