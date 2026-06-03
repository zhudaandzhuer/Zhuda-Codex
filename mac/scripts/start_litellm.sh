#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  ./scripts/sync_keys_from_zhudaapi.sh
fi

set -a
source .env
set +a

exec "$ROOT_DIR/.venv/bin/litellm" --config "$ROOT_DIR/litellm_config.yaml" --host 127.0.0.1 --port 4000

