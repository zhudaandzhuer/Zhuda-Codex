# Zhuda-Codex

Zhuda-Codex 是一个本地 Codex Desktop 启动器和模型适配器。它会打开一个轻量 Web 启动页，让你选择模型供应商、选择真实上游模型、输入本次会话 API key，然后通过本地 Responses 兼容适配器启动 Codex。

API key 只在本次启动时通过进程环境变量注入，不写入仓库，也不保存到本地源码目录。

![Zhuda-Codex 启动器](docs/images/launcher-overview.png)

## 它解决什么

- 在中国内地网络环境里，可以通过本地 adapter + 可直连的上游供应商使用 Codex Desktop 的工作流，不需要为了连接 OpenAI 官方线路而翻墙。
- 它不是破解 Codex，也不是官方产品；它只是把 Codex Desktop 的本地应用体验接到你自己选择的模型供应商。
- 请遵守你所在地区的法律法规、供应商服务条款，以及你自己 API key 的使用限制。

## 一键安装

GitHub 不分发夹带官方 Codex Desktop 本体的 portable 包。安装脚本只下载 Zhuda-Codex 自己的启动器、adapter 和构建脚本；需要 Codex 本体时，会在你的电脑本机安装或读取已安装的官方 Codex Desktop，并在需要时生成私有副本。

### macOS

先安装官方 Codex Desktop，然后运行：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/zhudaandzhuer/Zhuda-Codex/main/install/macos.sh)"
```

脚本会安装到 `~/Documents/ZhudaCodex`，并在本机从 `/Applications/Codex.app` 生成 `mac/dist/Zhuda-Codex.app`。

### Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/zhudaandzhuer/Zhuda-Codex/main/install/windows.ps1 | iex"
```

脚本会安装到 `Documents\ZhudaCodex` 并打开 Zhuda-Codex Launcher。

Windows 脚本会先检查本机是否已经安装官方 Codex Desktop。若没有安装，会尝试通过 Microsoft Store / `winget` 安装官方 Codex；如果自动安装没有完成，脚本会打开 Microsoft Store 页面并停止，请先安装 Codex Desktop 后再重跑上面的命令。

如果想在自己的 Windows 机器上生成私有 portable 副本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/zhudaandzhuer/Zhuda-Codex/main/install/windows.ps1))) -BuildPortable"
```

## 实验产品说明

Zhuda-Codex 目前是实验产品。不同 Codex Desktop 版本、不同供应商模型、不同网络环境都会带来边界问题，例如模型菜单刷新慢、上游 5xx、工具调用格式不稳定、长任务超时等。

遇到问题时，推荐直接让 AI 读取并分析 adapter log，然后根据日志继续改进 adapter。日志入口通常是：

- macOS：`~/Library/Application Support/Zhuda-Codex/logs/`
- Windows portable：`profile/logs/`
- 局域网日志面板：`http://YOUR_MAC_IP:4100/logs`

## 现在的状态

- macOS 版本已经有 Web 启动器、本机独立 App 构建脚本、本地 adapter、模型菜单 bundle 补丁、错误边界处理。
- Windows 版本已经有 Web 启动器、供应商选择、API key 会话注入、本机 portable 构建脚本。
- Windows portable 构建脚本会在用户自己的 Windows 机器上复制已安装的官方 Codex Desktop，并在可用时给 `app.asar` 套用同一套模型菜单 bundle 补丁；如果构建机缺少 Python 或 npx，会退回模型缓存和运行时注入兜底。
- portable 会使用隔离的 `CODEX_HOME`，并把仓库 `skills/` 同步到 portable 内部的 `CODEX_HOME/skills`。如果 portable 包内没有真正的 `SKILL.md`，启动时会自动镜像当前电脑的官方全局 `~/.codex/skills` 到隔离目录；这只复制到 portable profile，不会修改官方全局目录。
- portable 启动时会写入 `check_for_update_on_startup = false`，并设置 Electron/updater 抑制环境变量。它会运行包内复制出来的 Codex 本体，不会在每次启动时从 Microsoft Store 或官方 App 自动追新版。
- GitHub 仓库发布的是源码和 Zhuda-Codex 工具，不分发官方 Codex Desktop 二进制。Windows 想免安装运行，需要在自己的电脑上用构建脚本生成 private portable 包。

## 支持的供应商

### Gemini

- Flash 3.5：`gemini-3.5-flash`
- Flash 3.0：`gemini-3-flash-preview`
- Flash Lite 3.1：`gemini-3.1-flash-lite`
- Pro 3.1：`gemini-3.1-pro`
- Gemma 31B：`gemma-4-31b-it`

### Xiaomi MiMo

- 支持接口模式：一般 API、Token Plan
- MiMo v2.5 Pro：`mimo-v2.5-pro`
- MiMo v2.5：`mimo-v2.5`

### DeepSeek

- DeepSeek V4 Pro：`deepseek-v4-pro`
- DeepSeek V4 Flash：`deepseek-v4-flash`

供应商和模型配置在 `providers.json` 中维护。启动器会把选择结果注入本次 Codex 会话，adapter 不会私自把你选择的模型切到其他模型。

## 快速开始

### macOS

```bash
cd /path/to/ZhudaCodex
./mac/Zhuda-Codex-Launcher.command
```

如果已经构建了 `mac/dist/Zhuda-Codex.app`，启动器会通过这个独立 App 启动 Codex，并在当前会话注入模型菜单。

如果需要重新给独立 App 套用模型菜单补丁：

```bash
python3 scripts/patch_codex_asar_models.py \
  --asar mac/dist/Zhuda-Codex.app/Contents/Resources/app.asar
```

### Windows 源码运行

```powershell
cd C:\path\to\ZhudaCodex
.\win\Zhuda-Codex-Launcher.cmd
```

源码运行要求本机已经安装 Codex Desktop，并且 Windows 脚本能找到本地 adapter 或 legacy adapter。

### Windows portable 构建

```powershell
cd C:\path\to\ZhudaCodex
powershell -NoProfile -ExecutionPolicy Bypass -File .\win\windows_zhuda_make_portable.ps1 -Zip
```

脚本会从本机已安装的 Windows Codex AppX 复制应用文件，并生成：

```text
Documents\ZhudaCodex\portable\Zhuda-Codex\
Documents\ZhudaCodex\portable\Zhuda-Codex-Portable.zip
```

生成后的 portable 包才是更接近“下载后直接运行”的版本。仓库源码本身不会包含 `app/Codex.exe`、本地 profile、运行日志或 API key。

构建脚本会优先尝试修补 portable 内部的 `app.asar`，让模型菜单直接读取本地 adapter 的 `/pool/status`。如果构建环境没有 Python 或 npx，脚本会保留旧的模型缓存和运行时注入兜底，不会中断 portable 生成。

如果要把当前 Windows 用户的全局 Codex skills 一起打进自己的私有 portable 包：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\win\windows_zhuda_make_portable.ps1 -Zip -IncludeUserSkills
```

不加 `-IncludeUserSkills` 时，只会携带仓库根目录下的公开 `skills/`。如果包内没有真正的 `SKILL.md`，启动时会临时镜像当前电脑的 `~/.codex/skills`；若不想这样做，可在启动前设置 `ZHUDA_CODEX_IMPORT_USER_SKILLS=0`。

macOS 私有构建若要带入当前用户的全局 skills：

```bash
ZHUDA_CODEX_INCLUDE_USER_SKILLS=1 ./mac/scripts/build_zhuda_codex_app.sh
```

不加这个环境变量时，macOS App 也只会携带仓库根目录下的公开 `skills/`。如果包内没有真正的 `SKILL.md`，启动时会临时镜像当前电脑的 `~/.codex/skills`；若不想这样做，可在启动前设置 `ZHUDA_CODEX_IMPORT_USER_SKILLS=0`。

## 目录结构

```text
ZhudaCodex/
  assets/brand/              品牌图、图标、启动器展示图
  docs/images/               README 展示截图
  launcher/                  macOS / Windows 共用 Web 启动器
  mac/                       macOS adapter、App 包装脚本、局域网日志接收器
  skills/                    可随 portable 携带的公开 Codex skills
  win/                       Windows 启动器、远程接入脚本、portable 构建脚本
  providers.json             供应商和模型清单
  scripts/                    维护脚本，例如 app.asar 模型菜单补丁
  tests/                     adapter 边界测试
```

## 不会提交的内容

这些内容是本机生成物，不应提交到 GitHub：

```text
.env
*.env
.venv/
dist/
build/
release/
out/
mac/dist/
mac/archive/runtime_logs/
*.log
*.jsonl
*.pid
*.zip
```

## 安全说明

- 仓库不应该包含任何真实 API key。
- 启动页输入的 key 只进入本次启动的进程环境变量。
- 日志会对常见 key 格式做脱敏。
- 开源前请跑敏感字符串扫描。

```bash
rg -n "AIza|sk-[A-Za-z0-9_-]{12,}|192\\.168\\.|api[_-]?key\\s*[:=]" \
  . \
  --glob '!mac/.venv/**' \
  --glob '!mac/dist/**' \
  --glob '!mac/archive/runtime_logs/**' \
  --glob '!**/.DS_Store'
```

扫描结果只应该出现占位符、正则、环境变量名或文档说明，不能出现真实密钥。

## 验证

```bash
python3 -m py_compile mac/zhuda_gemini_pool_adapter.py launcher/zhuda_web_launcher.py
python3 -m py_compile scripts/patch_codex_asar_models.py
node -c launcher/web/app.js
python3 -m json.tool providers.json >/dev/null
python3 tests/test_adapter_boundaries.py
```

Windows 脚本语法可在 Windows PowerShell 5.1 里运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\win\Zhuda-Codex-Launcher.ps1 -Headless -NoLaunch -Provider gemini -Model gemma-31b -ApiKey test
```

## 常见问题

### 从 GitHub 拉下来为什么会报错？

因为 GitHub 仓库是源码，不是完整 portable 成品包。源码不会包含 Windows 的 `app/Codex.exe`，也不会包含 macOS 的 `mac/dist/Zhuda-Codex.app` 生成物。Windows 一键安装脚本会先确保官方 Codex Desktop 已安装，再启动 Zhuda-Codex Launcher；如果你手动下载源码运行，请先按平台构建，或使用自己机器生成的 private portable 包。

### 为什么 Codex 菜单里还是 GPT 名称？

某些 Codex Desktop 前端会锁死内置模型菜单。Zhuda-Codex portable 会优先用 `app.asar` bundle 补丁，让菜单直接读取本地 adapter 的 `/pool/status`，显示当前供应商可用的真实模型。若补丁未套用成功，系统会退回模型缓存或运行时注入兜底；即使菜单显示 GPT，实际请求仍会按照启动器注入的映射发给对应上游模型。

### adapter 会不会自动切模型？

不会。用户选择什么模型，这一轮就只打这个模型。上游报错时，adapter 会把上游原始错误和本地解释返回给 Codex，不会偷偷换到其他模型。

## 免责声明

Zhuda-Codex 是本地启动器和适配器实验项目，不是 OpenAI、Google、Xiaomi、DeepSeek 的官方产品。请只使用你有权使用的 API key 和品牌素材。
