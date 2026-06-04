#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_ROOT="$(cd "$APP_DIR/.." && pwd)"
APP_DOMAIN="com.zhuda.zhuda-codex"
SUPPORT_ROOT="${HOME}/Library/Application Support/Zhuda-Codex"
CODEX_HOME_DIR="${SUPPORT_ROOT}/codex-home"
USER_DATA_DIR="${SUPPORT_ROOT}/electron-user-data"
LOG_DIR="${SUPPORT_ROOT}/logs"
CONFIG_FILE="${CODEX_HOME_DIR}/config.toml"
ADAPTER_PORT="${ZHUDA_CODEX_GEMINI_PORT:-4400}"
ADAPTER_BASE_URL="http://127.0.0.1:${ADAPTER_PORT}"
CDP_PORT="${ZHUDA_CODEX_CDP_PORT:-9233}"
SOURCE_ADAPTER_ROOT="${ZHUDA_CODEX_SOURCE_ADAPTER_ROOT:-${HOME}/Documents/ZhudaCodex/mac}"
SOURCE_ADAPTER_FILE="${SOURCE_ADAPTER_ROOT}/zhuda_gemini_pool_adapter.py"
SOURCE_MODEL_INJECTOR_FILE="${SOURCE_ADAPTER_ROOT}/scripts/zhuda_model_injector.py"
SOURCE_ENV_FILE="${SOURCE_ADAPTER_ROOT}/.env"
SOURCE_VENV_ROOT="${SOURCE_ADAPTER_ROOT}/.venv"
BUNDLED_ADAPTER_ROOT="${APP_DIR}/Resources/zhuda"
BUNDLED_ADAPTER_FILE="${BUNDLED_ADAPTER_ROOT}/zhuda_gemini_pool_adapter.py"
BUNDLED_MODEL_INJECTOR_FILE="${BUNDLED_ADAPTER_ROOT}/zhuda_model_injector.py"
BUNDLED_VENV_ROOT="${BUNDLED_ADAPTER_ROOT}/python-runtime"
ADAPTER_RUNTIME_ROOT="${SUPPORT_ROOT}/adapters/gemini"
ADAPTER_FILE="${ADAPTER_RUNTIME_ROOT}/zhuda_gemini_pool_adapter.py"
MODEL_INJECTOR_FILE="${ADAPTER_RUNTIME_ROOT}/zhuda_model_injector.py"
RUNTIME_VENV_ROOT="${SUPPORT_ROOT}/runtime/python"
ADAPTER_RUNNER="${ZHUDA_CODEX_ADAPTER_RUNNER:-${RUNTIME_VENV_ROOT}/bin/python}"
ADAPTER_LOG="${LOG_DIR}/gemini-adapter-${ADAPTER_PORT}.out.log"
ADAPTER_ERR="${LOG_DIR}/gemini-adapter-${ADAPTER_PORT}.err.log"
MODEL_INJECTOR_LOG="${LOG_DIR}/model-injector-${CDP_PORT}.out.log"
MODEL_INJECTOR_ERR="${LOG_DIR}/model-injector-${CDP_PORT}.err.log"
ADAPTER_PID_FILE="${ADAPTER_RUNTIME_ROOT}/adapter-${ADAPTER_PORT}.pid"
SESSION_ENV_FILE="${ZHUDA_CODEX_SESSION_ENV_FILE:-}"
SESSION_LAUNCH="0"
if [[ -n "$SESSION_ENV_FILE" \
  || -n "${ZHUDA_CODEX_LAUNCHER_SESSION:-}" \
  || -n "${ZHUDA_PROVIDER:-}" \
  || -n "${ZHUDA_MODEL_MAPPINGS:-}" \
  || -n "${MIMO_API_KEY_1:-}" \
  || -n "${DEEPSEEK_API_KEY_1:-}" \
  || -n "${DEEPSEEK_API_KEY:-}" \
  || -n "${ZHUDA_DEEPSEEK_API_KEY:-}" \
  || -n "${GEMINI_API_KEY_1:-}" \
  || -n "${ZHUDA_GEMINI_API_KEY:-}" ]]; then
  SESSION_LAUNCH="1"
fi
ADAPTER_LABEL="${APP_DOMAIN}.gemini-adapter"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
ADAPTER_PLIST="${LAUNCH_AGENTS_DIR}/${ADAPTER_LABEL}.plist"

mkdir -p "$CODEX_HOME_DIR" "$USER_DATA_DIR" "$LOG_DIR" "$ADAPTER_RUNTIME_ROOT"

defaults write "$APP_DOMAIN" SUEnableAutomaticChecks -bool false >/dev/null 2>&1 || true
defaults write "$APP_DOMAIN" SUAutomaticallyUpdate -bool false >/dev/null 2>&1 || true
defaults write "$APP_DOMAIN" SUHasLaunchedBefore -bool true >/dev/null 2>&1 || true

write_config() {
  local selected_model="${ZHUDA_SELECTED_CODEX_MODEL:-zhuda-codex}"
  cat > "$CONFIG_FILE" <<EOF
model = "${selected_model}"
model_provider = "zhuda_gemini_adapter"
model_context_window = 49152
model_auto_compact_token_limit = 32000
tool_output_token_limit = 4000
check_for_update_on_startup = false

[model_providers.zhuda_gemini_adapter]
name = "Zhuda-Codex Adapter"
base_url = "${ADAPTER_BASE_URL}/v1"
wire_api = "responses"
experimental_bearer_token = "zhuda-codex-local-token"
EOF
}

write_model_cache() {
  local models
  models="$(selected_visible_models)"
  if [[ -z "$models" ]]; then
    return 0
  fi

  local default_model="${ZHUDA_SELECTED_CODEX_MODEL:-${ZHUDA_SELECTED_UPSTREAM_MODEL:-}}"
  if [[ -z "$default_model" ]]; then
    default_model="${models%%,*}"
  fi
  local provider_name="${ZHUDA_PROVIDER:-Zhuda-Codex}"
  local cache_file="${CODEX_HOME_DIR}/models_cache.json"
  local template_file="${HOME}/.codex/models_cache.json"
  local python_bin="/usr/bin/python3"
  if [[ ! -x "$python_bin" && -x "$ADAPTER_RUNNER" ]]; then
    python_bin="$ADAPTER_RUNNER"
  fi
  if [[ ! -x "$python_bin" ]]; then
    return 0
  fi

  "$python_bin" - "$cache_file" "$template_file" "$models" "$default_model" "$provider_name" <<'PY'
import copy
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

cache_file = Path(sys.argv[1])
template_file = Path(sys.argv[2])
models = []
for item in sys.argv[3].split(","):
    item = item.strip()
    if item and item not in models:
        models.append(item)
default_model = (sys.argv[4] or "").strip() or (models[0] if models else "zhuda-codex")
provider_name = (sys.argv[5] or "Zhuda-Codex").strip()
if default_model and default_model not in models:
    models.insert(0, default_model)

def fallback_model():
    return {
        "slug": "template",
        "display_name": "Template",
        "description": "Template",
        "default_reasoning_level": "medium",
        "supported_reasoning_levels": [
            {"effort": "low", "description": "Fast responses"},
            {"effort": "medium", "description": "Balanced reasoning"},
            {"effort": "high", "description": "More deliberate reasoning"},
            {"effort": "xhigh", "description": "Maximum reasoning"},
        ],
        "shell_type": "shell_command",
        "visibility": "list",
        "supported_in_api": True,
        "priority": 99,
        "additional_speed_tiers": [],
        "service_tiers": [],
        "availability_nux": None,
        "upgrade": None,
        "base_instructions": "You are Codex, a coding agent.",
        "supports_reasoning_summaries": False,
        "default_reasoning_summary": "auto",
        "support_verbosity": False,
        "default_verbosity": None,
        "apply_patch_tool_type": None,
        "web_search_tool_type": "text",
        "truncation_policy": {"mode": "tokens", "limit": 10000},
        "supports_parallel_tool_calls": False,
        "supports_image_detail_original": False,
        "effective_context_window_percent": 95,
        "experimental_supported_tools": [],
        "input_modalities": ["text", "image"],
        "supports_search_tool": False,
    }

template = None
cache_meta = {}
if template_file.exists():
    try:
        cache_meta = json.loads(template_file.read_text(encoding="utf-8"))
        for item in cache_meta.get("models") or []:
            if item.get("slug") in ("gpt-5.5", "gpt-5.4-mini"):
                template = item
                break
        if template is None and cache_meta.get("models"):
            template = cache_meta["models"][0]
    except Exception:
        template = None
if template is None:
    template = fallback_model()

out_models = []
for index, model_name in enumerate(models):
    item = copy.deepcopy(template)
    item["slug"] = model_name
    item["display_name"] = model_name
    item["description"] = f"{provider_name} upstream model"
    item["visibility"] = "list"
    item["supported_in_api"] = True
    item["availability_nux"] = None
    item["upgrade"] = None
    item["additional_speed_tiers"] = []
    item["service_tiers"] = []
    item["priority"] = 9 + index * 7
    out_models.append(item)

payload = {
    "fetched_at": cache_meta.get("fetched_at") or datetime.now(timezone.utc).isoformat(),
    "etag": f"zhuda-{provider_name}",
    "client_version": cache_meta.get("client_version") or "zhuda-local",
    "models": out_models,
}
cache_file.parent.mkdir(parents=True, exist_ok=True)
cache_file.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
PY
}

prepare_adapter_runtime() {
  if [[ ! -x "$ADAPTER_RUNNER" ]]; then
    if [[ -x "${BUNDLED_VENV_ROOT}/bin/python" ]]; then
      /usr/bin/ditto "$BUNDLED_VENV_ROOT" "$RUNTIME_VENV_ROOT"
    elif [[ -x "${SOURCE_VENV_ROOT}/bin/python" ]]; then
      /usr/bin/ditto "$SOURCE_VENV_ROOT" "$RUNTIME_VENV_ROOT"
    fi
  fi

  if [[ -f "$BUNDLED_ADAPTER_FILE" ]]; then
    if [[ ! -f "$ADAPTER_FILE" || "$BUNDLED_ADAPTER_FILE" -nt "$ADAPTER_FILE" ]]; then
      /bin/cp "$BUNDLED_ADAPTER_FILE" "$ADAPTER_FILE"
    fi
  elif [[ -f "$SOURCE_ADAPTER_FILE" ]]; then
    if [[ ! -f "$ADAPTER_FILE" || "$SOURCE_ADAPTER_FILE" -nt "$ADAPTER_FILE" ]]; then
      /bin/cp "$SOURCE_ADAPTER_FILE" "$ADAPTER_FILE"
    fi
  fi

  if [[ -f "$BUNDLED_MODEL_INJECTOR_FILE" ]]; then
    if [[ ! -f "$MODEL_INJECTOR_FILE" || "$BUNDLED_MODEL_INJECTOR_FILE" -nt "$MODEL_INJECTOR_FILE" ]]; then
      /bin/cp "$BUNDLED_MODEL_INJECTOR_FILE" "$MODEL_INJECTOR_FILE"
    fi
  elif [[ -f "$SOURCE_MODEL_INJECTOR_FILE" ]]; then
    if [[ ! -f "$MODEL_INJECTOR_FILE" || "$SOURCE_MODEL_INJECTOR_FILE" -nt "$MODEL_INJECTOR_FILE" ]]; then
      /bin/cp "$SOURCE_MODEL_INJECTOR_FILE" "$MODEL_INJECTOR_FILE"
    fi
  fi

  if [[ -f "$SOURCE_ENV_FILE" && ! -f "${ADAPTER_RUNTIME_ROOT}/.env" ]]; then
    /bin/cp "$SOURCE_ENV_FILE" "${ADAPTER_RUNTIME_ROOT}/.env"
    /bin/chmod 600 "${ADAPTER_RUNTIME_ROOT}/.env" || true
  fi
}

adapter_health() {
  /usr/bin/curl -fsS --max-time 2 "${ADAPTER_BASE_URL}/health/readiness"
}

cleanup_session_env() {
  if [[ -z "$SESSION_ENV_FILE" ]]; then
    return 0
  fi
  case "$SESSION_ENV_FILE" in
    "${TMPDIR:-/tmp}"/zhuda-codex-session.*.env|/tmp/zhuda-codex-session.*.env)
      /bin/rm -f "$SESSION_ENV_FILE"
      ;;
  esac
}

write_launch_agent() {
  mkdir -p "$LAUNCH_AGENTS_DIR"
  cat > "$ADAPTER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${ADAPTER_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${ADAPTER_RUNNER}</string>
    <string>-m</string>
    <string>uvicorn</string>
    <string>zhuda_gemini_pool_adapter:app</string>
    <string>--host</string>
    <string>127.0.0.1</string>
    <string>--port</string>
    <string>${ADAPTER_PORT}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${ADAPTER_RUNTIME_ROOT}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${ADAPTER_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${ADAPTER_ERR}</string>
</dict>
</plist>
EOF
}

start_adapter_direct() {
  prepare_adapter_runtime

  if [[ ! -f "$ADAPTER_FILE" ]]; then
    {
      echo "Missing Zhuda adapter source:"
      echo "$SOURCE_ADAPTER_FILE"
    } >>"$ADAPTER_ERR"
    return 1
  fi

  if [[ ! -x "$ADAPTER_RUNNER" ]]; then
    {
      echo "Missing Python runner:"
      echo "$ADAPTER_RUNNER"
    } >>"$ADAPTER_ERR"
    return 1
  fi

  (
    cd "$ADAPTER_RUNTIME_ROOT"
    if [[ -n "$SESSION_ENV_FILE" ]]; then
      export ZHUDA_DOTENV_PATH="$SESSION_ENV_FILE"
    fi
    exec "$ADAPTER_RUNNER" -m uvicorn zhuda_gemini_pool_adapter:app --host 127.0.0.1 --port "$ADAPTER_PORT"
  ) >>"$ADAPTER_LOG" 2>>"$ADAPTER_ERR" &
  echo $! >"$ADAPTER_PID_FILE"

  for _ in {1..40}; do
    if adapter_health >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done

  return 1
}

start_adapter() {
  if [[ "$SESSION_LAUNCH" == "1" ]]; then
    stop_adapter
    start_adapter_direct
    return $?
  fi

  if adapter_health >/dev/null 2>&1; then
    return 0
  fi

  prepare_adapter_runtime

  if [[ ! -f "$ADAPTER_FILE" ]]; then
    {
      echo "Missing Zhuda adapter source:"
      echo "$SOURCE_ADAPTER_FILE"
    } >>"$ADAPTER_ERR"
    return 1
  fi

  if [[ ! -x "$ADAPTER_RUNNER" ]]; then
    {
      echo "Missing Python runner:"
      echo "$ADAPTER_RUNNER"
    } >>"$ADAPTER_ERR"
    return 1
  fi

  write_launch_agent
  /bin/launchctl bootout "gui/$(/usr/bin/id -u)" "$ADAPTER_PLIST" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$ADAPTER_PLIST" >/dev/null 2>>"$ADAPTER_ERR" || true
  /bin/launchctl enable "gui/$(/usr/bin/id -u)/${ADAPTER_LABEL}" >/dev/null 2>>"$ADAPTER_ERR" || true
  /bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/${ADAPTER_LABEL}" >/dev/null 2>>"$ADAPTER_ERR" || true

  for _ in {1..40}; do
    if adapter_health >/dev/null 2>&1; then
      /usr/sbin/lsof -tiTCP:"$ADAPTER_PORT" -sTCP:LISTEN 2>/dev/null | head -n 1 >"$ADAPTER_PID_FILE" || true
      return 0
    fi
    sleep 0.5
  done

  return 1
}

stop_adapter() {
  local pids
  /bin/launchctl bootout "gui/$(/usr/bin/id -u)" "$ADAPTER_PLIST" >/dev/null 2>&1 || true
  pids="$(/usr/sbin/lsof -tiTCP:"$ADAPTER_PORT" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    /bin/kill $pids >/dev/null 2>&1 || true
  fi
  /bin/rm -f "$ADAPTER_PID_FILE"
}

selected_visible_models() {
  if [[ -n "${ZHUDA_VISIBLE_MODELS:-}" ]]; then
    echo "$ZHUDA_VISIBLE_MODELS"
  elif [[ -n "${ZHUDA_DEEPSEEK_VISIBLE_MODELS:-}" ]]; then
    echo "$ZHUDA_DEEPSEEK_VISIBLE_MODELS"
  elif [[ -n "${ZHUDA_MIMO_VISIBLE_MODELS:-}" ]]; then
    echo "$ZHUDA_MIMO_VISIBLE_MODELS"
  elif [[ -n "${ZHUDA_GEMINI_VISIBLE_MODELS:-}" ]]; then
    echo "$ZHUDA_GEMINI_VISIBLE_MODELS"
  else
    echo ""
  fi
}

choose_cdp_port() {
  if [[ -n "${ZHUDA_CODEX_CDP_PORT:-}" ]]; then
    return 0
  fi

  local candidate="$CDP_PORT"
  while /usr/sbin/lsof -nP -iTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1; do
    candidate=$((candidate + 1))
  done
  CDP_PORT="$candidate"
  MODEL_INJECTOR_LOG="${LOG_DIR}/model-injector-${CDP_PORT}.out.log"
  MODEL_INJECTOR_ERR="${LOG_DIR}/model-injector-${CDP_PORT}.err.log"
}

start_model_injector() {
  local models
  models="$(selected_visible_models)"
  if [[ -z "$models" ]]; then
    return 0
  fi
  if [[ ! -f "$MODEL_INJECTOR_FILE" ]]; then
    return 0
  fi
  if [[ ! -x "$ADAPTER_RUNNER" ]]; then
    return 0
  fi
  local selected_model="${ZHUDA_SELECTED_CODEX_MODEL:-${ZHUDA_SELECTED_UPSTREAM_MODEL:-}}"
  local provider_name="${ZHUDA_PROVIDER:-Zhuda-Codex}"
  local duration="${ZHUDA_MODEL_INJECT_DURATION_SECONDS:-75}"
  (
    sleep 0.8
    exec "$ADAPTER_RUNNER" "$MODEL_INJECTOR_FILE" \
      --port "$CDP_PORT" \
      --models "$models" \
      --default-model "$selected_model" \
      --provider-name "$provider_name" \
      --duration "$duration"
  ) >>"$MODEL_INJECTOR_LOG" 2>>"$MODEL_INJECTOR_ERR" &
}

ZHUDA_CODEX_DEBUG_ARGS=()
set_codex_debug_args() {
  ZHUDA_CODEX_DEBUG_ARGS=()
  if [[ -n "$(selected_visible_models)" ]]; then
    ZHUDA_CODEX_DEBUG_ARGS=("--remote-debugging-address=127.0.0.1" "--remote-debugging-port=${CDP_PORT}")
  fi
}

export CODEX_HOME="$CODEX_HOME_DIR"
export ZHUDA_CODEX_GEMINI_APP="1"
export ELECTRON_NO_UPDATER="1"

if [[ "${1:-}" == "--zhuda-dry-run" ]]; then
  choose_cdp_port
  echo "app_root=$APP_ROOT"
  echo "codex_home=$CODEX_HOME"
  echo "user_data_dir=$USER_DATA_DIR"
  echo "adapter_port=$ADAPTER_PORT"
  echo "adapter_base_url=$ADAPTER_BASE_URL"
  echo "cdp_port=$CDP_PORT"
  echo "adapter_runtime_root=$ADAPTER_RUNTIME_ROOT"
  echo "runtime_venv_root=$RUNTIME_VENV_ROOT"
  echo "source_adapter_root=$SOURCE_ADAPTER_ROOT"
  echo "adapter_runner=$ADAPTER_RUNNER"
  echo "config_file=$CONFIG_FILE"
  echo "model_injector=$MODEL_INJECTOR_FILE"
  exit 0
fi

write_config

if [[ "${1:-}" == "--zhuda-stop-adapter" ]]; then
  stop_adapter
  echo "stopped adapter on ${ADAPTER_BASE_URL}"
  exit 0
fi

if [[ "${1:-}" == "--zhuda-start-adapter-only" ]]; then
  start_adapter
  adapter_health
  exit 0
fi

if [[ "$SESSION_LAUNCH" == "1" ]]; then
  trap 'stop_adapter; cleanup_session_env' EXIT
  start_adapter || true
  choose_cdp_port
  write_model_cache
  set_codex_debug_args
  start_model_injector
  "$APP_DIR/MacOS/Codex.real" "${ZHUDA_CODEX_DEBUG_ARGS[@]}" --user-data-dir="$USER_DATA_DIR" "$@"
  exit $?
fi

start_adapter || true

choose_cdp_port
write_model_cache
set_codex_debug_args
start_model_injector

exec "$APP_DIR/MacOS/Codex.real" "${ZHUDA_CODEX_DEBUG_ARGS[@]}" --user-data-dir="$USER_DATA_DIR" "$@"
