#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  ./scripts/sync_keys_from_zhudaapi.sh
fi

exec "$ROOT_DIR/.venv/bin/uvicorn" zhuda_gemini_pool_adapter:app --host 127.0.0.1 --port 4000

