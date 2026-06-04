# Zhuda-Codex macOS

这里放 macOS 版本的本地 adapter、Web 启动器、独立 App 包装脚本、模型菜单注入脚本，以及局域网日志/控制接收器。

## 本地启动

从仓库根目录执行：

```bash
./mac/Zhuda-Codex-Launcher.command
```

启动器会打开本地 Web 页面。选择供应商、选择默认真实模型、输入本次会话 API key，然后启动 Codex。API key 只通过进程环境变量注入，不会写进源码目录。

如果 `mac/dist/Zhuda-Codex.app` 已经存在，launcher 会使用这个独立 App 包。它不会覆盖系统里的官方 Codex，也不会把 provider 配置写进官方 Codex 全局配置。

## Adapter

开发环境：

```bash
cd /path/to/ZhudaCodex/mac
./scripts/setup.sh
./scripts/start_adapter.sh
```

快速测试：

```bash
./scripts/test_responses.sh
```

LaunchAgent：

```bash
./scripts/install_launch_agent.sh
./scripts/uninstall_launch_agent.sh
```

运行时目录：

```text
~/.zhuda-codex/
~/Library/Application Support/Zhuda-Codex/
```

这些目录是本机状态，可能包含日志和临时配置，不要提交到 GitHub。

## Codex 配置示例

```toml
model = "zhuda-codex"
model_provider = "zhuda_gemini_pool"
model_context_window = 49152
model_auto_compact_token_limit = 32000
tool_output_token_limit = 4000

[model_providers.zhuda_gemini_pool]
name = "Zhuda Adapter"
base_url = "http://127.0.0.1:4000/v1"
wire_api = "responses"
experimental_bearer_token = "zhuda-codex-local-token"
```

provider 名称里保留 `gemini_pool` 是历史遗留；现在 adapter 可以根据启动器选择路由到 Gemini、MiMo、DeepSeek 等供应商。

## 模型菜单注入

有些 Codex Desktop 版本会忽略 adapter 暴露的 `/v1/models`，继续显示内置 GPT 名称。macOS 独立 App 会在启动时打开一个仅限 localhost 的临时 DevTools 端口，并运行：

```text
mac/scripts/zhuda_model_injector.py
```

它只修改当前渲染器会话里的模型菜单，不改官方 Codex 安装包。

可选环境变量：

```text
ZHUDA_CODEX_CDP_PORT=9233
ZHUDA_MODEL_INJECT_DURATION_SECONDS=75
```

日志位置：

```text
~/Library/Application Support/Zhuda-Codex/logs/model-injector-*.out.log
~/Library/Application Support/Zhuda-Codex/logs/model-injector-*.err.log
```

## 局域网日志接收器

启动：

```bash
./scripts/start_mac_lan_log_receiver.sh
```

打开：

```text
http://YOUR_MAC_IP:4100/logs
http://YOUR_MAC_IP:4100/control
```

Windows 接入命令模板：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr 'http://YOUR_MAC_IP:4100/download/windows_zhuda_connect.ps1' -OutFile \"$env:TEMP\zhuda_connect.ps1\"; powershell -NoProfile -ExecutionPolicy Bypass -File \"$env:TEMP\zhuda_connect.ps1\" -Mode local -Model gemma-31b"
```

接收器会对常见 API key 形态做脱敏后再写日志。

## 开源前不要提交

```text
.env
.venv/
dist/
archive/runtime_logs/
*.log
*.jsonl
.DS_Store
```

仓库 `.gitignore` 已覆盖这些路径。
