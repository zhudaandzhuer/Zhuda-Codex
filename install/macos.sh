#!/usr/bin/env bash
set -euo pipefail

REPO_ZIP_URL="${ZHUDA_CODEX_REPO_ZIP_URL:-https://github.com/zhudaandzhuer/Zhuda-Codex/archive/refs/heads/main.zip}"
INSTALL_DIR="${ZHUDA_CODEX_INSTALL_DIR:-$HOME/Documents/ZhudaCodex}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zhuda-codex-install.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "Installing Zhuda-Codex to: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

ZIP_PATH="$TMP_DIR/Zhuda-Codex-main.zip"
/usr/bin/curl -fsSL "$REPO_ZIP_URL" -o "$ZIP_PATH"
/usr/bin/ditto -x -k "$ZIP_PATH" "$TMP_DIR"

SRC_DIR="$TMP_DIR/Zhuda-Codex-main"
if [[ ! -d "$SRC_DIR" ]]; then
  echo "Could not unpack Zhuda-Codex source zip." >&2
  exit 1
fi

/usr/bin/ditto "$SRC_DIR" "$INSTALL_DIR"

BUILD_SCRIPT="$INSTALL_DIR/mac/scripts/build_zhuda_codex_app.sh"
if [[ -x "$BUILD_SCRIPT" ]]; then
  "$BUILD_SCRIPT" --project-root "$INSTALL_DIR"
else
  echo "Missing build script: $BUILD_SCRIPT" >&2
  exit 1
fi

LAUNCHER="$INSTALL_DIR/mac/Zhuda-Codex-Launcher.command"
chmod +x "$LAUNCHER"
echo "Opening Zhuda-Codex Launcher..."
/usr/bin/open "$LAUNCHER"

