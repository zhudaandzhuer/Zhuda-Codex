# Zhuda-Codex macOS

macOS files for the Zhuda-Codex local adapter, launcher, persistent LaunchAgent, and LAN log/control receiver.

## Local Launcher

From the repository root:

```bash
./mac/Zhuda-Codex-Launcher.command
```

The launcher opens a local Web UI, asks for a provider API key, applies the selected Codex-to-upstream model mapping, and launches Codex. API keys entered through the launcher are injected through the launch environment and are not written into the source tree.

## Adapter

Development setup:

```bash
cd /path/to/ZhudaCodex/mac
./scripts/setup.sh
./scripts/start_adapter.sh
```

Smoke test:

```bash
./scripts/test_responses.sh
```

Persistent LaunchAgent:

```bash
./scripts/install_launch_agent.sh
./scripts/uninstall_launch_agent.sh
```

The LaunchAgent runtime lives at:

```text
~/.zhuda-codex/
```

That directory can contain runtime logs and optional local `.env` state. It is not source and must not be committed.

## Codex Config

Example provider config:

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

The provider name is historical; the adapter can route more than Gemini depending on `providers.json` and the launcher-selected environment.

## LAN Receiver

Start the macOS receiver:

```bash
./scripts/start_mac_lan_log_receiver.sh
```

Open:

```text
http://YOUR_MAC_IP:4100/logs
http://YOUR_MAC_IP:4100/control
```

Windows onboarding command template:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr 'http://YOUR_MAC_IP:4100/download/windows_zhuda_connect.ps1' -OutFile \"$env:TEMP\zhuda_connect.ps1\"; powershell -NoProfile -ExecutionPolicy Bypass -File \"$env:TEMP\zhuda_connect.ps1\" -Mode local -Model gemma-31b"
```

The receiver redacts common API-key patterns before writing forwarded logs. Receiver runtime data is stored outside the repository under the user's home directory.

## Open Source Checklist

Before publishing this folder, exclude:

```text
.env
.venv/
dist/
archive/runtime_logs/
*.log
*.jsonl
.DS_Store
```

The repository `.gitignore` already covers these paths.
