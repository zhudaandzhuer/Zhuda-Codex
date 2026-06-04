#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE_APP=""
TARGET_APP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --source-app)
      SOURCE_APP="$2"
      shift 2
      ;;
    --target-app)
      TARGET_APP="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$SOURCE_APP" ]]; then
  for candidate in "/Applications/Codex.app" "$HOME/Applications/Codex.app"; do
    if [[ -d "$candidate" ]]; then
      SOURCE_APP="$candidate"
      break
    fi
  done
fi

if [[ -z "$SOURCE_APP" || ! -d "$SOURCE_APP" ]]; then
  echo "Codex.app was not found. Install official Codex Desktop first, then run this script again." >&2
  exit 1
fi

if [[ -z "$TARGET_APP" ]]; then
  TARGET_APP="$PROJECT_ROOT/mac/dist/Zhuda-Codex.app"
fi

CONTENTS="$TARGET_APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
ZHUDA_RESOURCES="$RESOURCES_DIR/zhuda"
REAL_EXE="$MACOS_DIR/Codex.real"
LAUNCHER_EXE="$MACOS_DIR/Codex"
WRAPPER="$MACOS_DIR/Codex.wrapper.sh"
PLIST="$CONTENTS/Info.plist"

echo "Building private Zhuda-Codex app from: $SOURCE_APP"
rm -rf "$TARGET_APP"
mkdir -p "$(dirname "$TARGET_APP")"
/usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"

mkdir -p "$ZHUDA_RESOURCES"

if [[ -f "$LAUNCHER_EXE" && ! -f "$REAL_EXE" ]]; then
  mv "$LAUNCHER_EXE" "$REAL_EXE"
fi

cp "$PROJECT_ROOT/mac/scripts/Codex.wrapper.sh" "$WRAPPER"
chmod +x "$WRAPPER"
cp "$PROJECT_ROOT/mac/zhuda_gemini_pool_adapter.py" "$ZHUDA_RESOURCES/zhuda_gemini_pool_adapter.py"
cp "$PROJECT_ROOT/mac/scripts/zhuda_model_injector.py" "$ZHUDA_RESOURCES/zhuda_model_injector.py"
if [[ "${ZHUDA_CODEX_INCLUDE_USER_SKILLS:-0}" == "1" && -d "$HOME/.codex/skills" ]]; then
  /usr/bin/ditto "$HOME/.codex/skills" "$ZHUDA_RESOURCES/skills"
elif [[ -d "$PROJECT_ROOT/skills" ]]; then
  /usr/bin/ditto "$PROJECT_ROOT/skills" "$ZHUDA_RESOURCES/skills"
fi

cat > "$ZHUDA_RESOURCES/CodexLauncher.c" <<'C'
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int executable_dir(char *out, size_t out_size) {
  char raw[PATH_MAX];
  uint32_t raw_size = sizeof(raw);
  if (_NSGetExecutablePath(raw, &raw_size) != 0) return -1;
  char resolved[PATH_MAX];
  if (realpath(raw, resolved) == NULL) return -1;
  char *slash = strrchr(resolved, '/');
  if (slash == NULL) return -1;
  *slash = '\0';
  return snprintf(out, out_size, "%s", resolved) >= (int)out_size ? -1 : 0;
}

int main(int argc, char **argv) {
  char dir[PATH_MAX];
  if (executable_dir(dir, sizeof(dir)) != 0) return 127;
  char wrapper[PATH_MAX];
  if (snprintf(wrapper, sizeof(wrapper), "%s/Codex.wrapper.sh", dir) >= (int)sizeof(wrapper)) return 127;
  char **child_argv = calloc((size_t)argc + 2, sizeof(char *));
  if (child_argv == NULL) return 127;
  child_argv[0] = "/bin/bash";
  child_argv[1] = wrapper;
  for (int i = 1; i < argc; i++) child_argv[i + 1] = argv[i];
  child_argv[argc + 1] = NULL;
  execv("/bin/bash", child_argv);
  return 127;
}
C

if command -v clang >/dev/null 2>&1; then
  clang "$ZHUDA_RESOURCES/CodexLauncher.c" -o "$LAUNCHER_EXE"
else
  cat > "$LAUNCHER_EXE" <<'SH'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec /bin/bash "$DIR/Codex.wrapper.sh" "$@"
SH
fi
chmod +x "$LAUNCHER_EXE"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.zhuda.zhuda-codex" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Set :CFBundleName Zhuda-Codex" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Zhuda-Codex" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Codex" "$PLIST" >/dev/null 2>&1 || true

if [[ -f "$PROJECT_ROOT/assets/brand/zhuda-codex-app-icon.icns" ]]; then
  cp "$PROJECT_ROOT/assets/brand/zhuda-codex-app-icon.icns" "$RESOURCES_DIR/app.icns"
  cp "$PROJECT_ROOT/assets/brand/zhuda-codex-app-icon.icns" "$RESOURCES_DIR/icon.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile app.icns" "$PLIST" >/dev/null 2>&1 || true
fi

if [[ -f "$PROJECT_ROOT/scripts/patch_codex_asar_models.py" && -f "$RESOURCES_DIR/app.asar" ]]; then
  /usr/bin/python3 "$PROJECT_ROOT/scripts/patch_codex_asar_models.py" --asar "$RESOURCES_DIR/app.asar" || true
fi

rm -rf "$CONTENTS/_CodeSignature"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$TARGET_APP" >/dev/null 2>&1 || true
fi

echo "Zhuda-Codex app is ready: $TARGET_APP"
