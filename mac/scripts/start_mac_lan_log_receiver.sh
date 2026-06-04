#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WIN_DIR="${PROJECT_DIR}/win"
RUNTIME_DIR="${HOME}/.zhuda-codex"
PID_FILE="${RUNTIME_DIR}/lan_log_receiver.pid"
LOG_FILE="${RUNTIME_DIR}/lan_log_receiver.log"
DOWNLOAD_DIR="${RUNTIME_DIR}/downloads"
BRAND_DOWNLOAD_DIR="${DOWNLOAD_DIR}/assets/brand"
LAUNCHER_DOWNLOAD_DIR="${DOWNLOAD_DIR}/launcher"
LAUNCHER_WEB_DOWNLOAD_DIR="${LAUNCHER_DOWNLOAD_DIR}/web"
PORT="${1:-4100}"

mkdir -p "${RUNTIME_DIR}"
mkdir -p "${DOWNLOAD_DIR}"
mkdir -p "${BRAND_DOWNLOAD_DIR}"
mkdir -p "${LAUNCHER_WEB_DOWNLOAD_DIR}"

cp "${WIN_DIR}/windows_zhuda_remote.ps1" "${DOWNLOAD_DIR}/windows_zhuda_remote.ps1"
cp "${WIN_DIR}/windows_zhuda_remote.cmd" "${DOWNLOAD_DIR}/windows_zhuda_remote.cmd"
cp "${WIN_DIR}/windows_zhuda_connect.ps1" "${DOWNLOAD_DIR}/windows_zhuda_connect.ps1"
cp "${WIN_DIR}/windows_zhuda_connect.cmd" "${DOWNLOAD_DIR}/windows_zhuda_connect.cmd"
cp "${WIN_DIR}/windows_zhuda_make_portable.ps1" "${DOWNLOAD_DIR}/windows_zhuda_make_portable.ps1"
cp "${WIN_DIR}/Zhuda-Codex-Launcher.ps1" "${DOWNLOAD_DIR}/Zhuda-Codex-Launcher.ps1"
cp "${WIN_DIR}/Zhuda-Codex-Launcher.cmd" "${DOWNLOAD_DIR}/Zhuda-Codex-Launcher.cmd"
cp "${WIN_DIR}/zhuda_model_injector.ps1" "${DOWNLOAD_DIR}/zhuda_model_injector.ps1"
cp "${PROJECT_DIR}/providers.json" "${DOWNLOAD_DIR}/providers.json"
cp "${PROJECT_DIR}/launcher/zhuda_web_launcher.ps1" "${LAUNCHER_DOWNLOAD_DIR}/zhuda_web_launcher.ps1"
cp "${PROJECT_DIR}/launcher/web/"*.html "${LAUNCHER_WEB_DOWNLOAD_DIR}/" 2>/dev/null || true
cp "${PROJECT_DIR}/launcher/web/"*.css "${LAUNCHER_WEB_DOWNLOAD_DIR}/" 2>/dev/null || true
cp "${PROJECT_DIR}/launcher/web/"*.js "${LAUNCHER_WEB_DOWNLOAD_DIR}/" 2>/dev/null || true
cp "${WIN_DIR}/legacy/windows_zhuda_codex_switch.ps1" "${DOWNLOAD_DIR}/windows_zhuda_local_adapter.ps1"
cp "${SCRIPT_DIR}/mac_lan_log_receiver.py" "${RUNTIME_DIR}/lan_log_receiver.py"
if [[ -d "${PROJECT_DIR}/assets/brand" ]]; then
  cp "${PROJECT_DIR}/assets/brand/"*.png "${BRAND_DOWNLOAD_DIR}/" 2>/dev/null || true
fi

if [[ -f "${PID_FILE}" ]]; then
  OLD_PID="$(cat "${PID_FILE}" || true)"
  if [[ -n "${OLD_PID}" ]] && kill -0 "${OLD_PID}" 2>/dev/null; then
    kill "${OLD_PID}" 2>/dev/null || true
    sleep 0.3
  fi
fi

if command -v lsof >/dev/null 2>&1; then
  while IFS= read -r PID_ON_PORT; do
    [[ -n "${PID_ON_PORT}" ]] && kill "${PID_ON_PORT}" 2>/dev/null || true
  done < <(lsof -tiTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true)
  sleep 0.3
fi

nohup python3 "${RUNTIME_DIR}/lan_log_receiver.py" --host 0.0.0.0 --port "${PORT}" --root "${RUNTIME_DIR}/remote_logs" >"${LOG_FILE}" 2>&1 &
echo "$!" > "${PID_FILE}"
sleep 0.5

echo "Receiver started."
echo "Local: http://127.0.0.1:${PORT}/logs"
echo "LAN:   http://$(ipconfig getifaddr en0 2>/dev/null || echo YOUR_MAC_IP):${PORT}/logs"
echo "Ctrl:  http://$(ipconfig getifaddr en0 2>/dev/null || echo YOUR_MAC_IP):${PORT}/control"
echo "Log:   ${LOG_FILE}"
echo "Win:   powershell -NoProfile -ExecutionPolicy Bypass -Command \"iwr 'http://$(ipconfig getifaddr en0 2>/dev/null || echo YOUR_MAC_IP):${PORT}/download/windows_zhuda_connect.ps1' -OutFile \\\"\$env:TEMP\\zhuda_connect.ps1\\\"; powershell -NoProfile -ExecutionPolicy Bypass -File \\\"\$env:TEMP\\zhuda_connect.ps1\\\" -Mode local -Model gemma-31b\""
