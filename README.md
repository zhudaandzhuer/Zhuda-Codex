# Zhuda-Codex

Zhuda-Codex is a local launcher and adapter layer for Codex Desktop. It opens a small Web UI, lets the user pick a provider, maps Codex model labels to upstream models, injects the API key for the current launch, and starts Codex through a local Responses-compatible adapter.

The project is split by platform but shares one provider manifest and one Web Launcher UI.

## Providers

Current provider cards:

- Gemini
  - Flash 3.5
  - Flash 3.0
  - Flash Lite 3.1
  - Pro 3.1
  - Gemma 31B
- Xiaomi MiMo
  - Endpoint modes: General API, Token Plan
  - MiMo v2.5 Pro
  - MiMo v2.5

The Codex-side model list is defined in `providers.json`. Each Codex model can be mapped to a provider model from the launcher before Codex starts.
Providers may also define endpoint modes in `providers.json`; the launcher sends the selected endpoint as a launch-time environment value instead of persisting it with any secret.

## Security

This repository should not contain provider API keys.

- The Web Launcher asks for an API key at launch time.
- Launcher-entered keys are passed through process environment variables.
- Keys are not written into the source tree.
- Runtime logs redact common key patterns before storing forwarded machine data.
- Generated local files such as `.env`, `.venv/`, `mac/dist/`, runtime logs, and downloaded remote bundles are ignored by `.gitignore`.

Before publishing, run the sensitive-string scan in the verification section below.

## Quick Start

macOS:

```bash
cd /path/to/ZhudaCodex
./mac/Zhuda-Codex-Launcher.command
```

Windows:

```powershell
cd C:\path\to\ZhudaCodex
.\win\Zhuda-Codex-Launcher.cmd
```

The launcher opens a local browser page. Choose a provider card, enter a key, map the Codex labels to upstream models, and click the launch button.

## Directory Layout

```text
ZhudaCodex/
  assets/brand/              generated Zhuda/ZhuEr launcher artwork
  launcher/                  shared Web Launcher
  mac/                       macOS adapter, app launcher, and LAN receiver
  win/                       Windows launcher, remote receiver scripts, portable builder
  providers.json             shared provider/model manifest
```

Generated runtime artifacts are intentionally not part of the public source package:

```text
mac/dist/
mac/.venv/
mac/.env
mac/archive/runtime_logs/
*.log
*.jsonl
```

If you are distributing source, publish the tracked source files and exclude those generated artifacts.

## macOS

The macOS launcher starts the bundled `Zhuda-Codex.app` from `mac/dist/` when a local app bundle has been built. The adapter listens on localhost and implements the OpenAI Responses shape that Codex expects.

Useful commands:

```bash
cd /path/to/ZhudaCodex/mac
./scripts/setup.sh
./scripts/start_adapter.sh
./scripts/install_launch_agent.sh
./scripts/uninstall_launch_agent.sh
```

The persistent LaunchAgent writes runtime files under:

```text
~/.zhuda-codex/
```

That runtime directory is local machine state and should not be committed.

## Windows

Windows can run from the source folder or from a portable bundle generated from an installed Codex Desktop app.

Source launcher:

```powershell
.\win\Zhuda-Codex-Launcher.cmd
```

Build portable bundle:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\win\windows_zhuda_make_portable.ps1
```

Remote onboarding through a macOS LAN receiver is documented in `mac/README.md` and `win/README.md`.

## Verification

Run syntax checks:

```bash
python3 -m py_compile mac/zhuda_gemini_pool_adapter.py launcher/zhuda_web_launcher.py
node -c launcher/web/app.js
python3 -m json.tool providers.json >/dev/null
```

Run adapter boundary checks without calling any provider API:

```bash
python3 tests/test_adapter_boundaries.py
```

Run a source-only sensitive scan:

```bash
rg -n "AIza|sk-[A-Za-z0-9_-]{12,}|192\\.168\\.|api[_-]?key\\s*[:=]" \
  . \
  --glob '!mac/.venv/**' \
  --glob '!mac/dist/**' \
  --glob '!mac/archive/runtime_logs/**' \
  --glob '!**/.DS_Store'
```

Expected result: only documentation, placeholder hints, redaction regexes, or environment-variable names should appear. No real API key should appear. Also search for your local username before publishing.

## Notes

- Do not override an existing paid Codex setup globally unless you intend to. Zhuda-Codex is designed to run as a separate local provider route.
- MiMo 5xx or timeout messages are usually provider gateway/model latency issues, not a balance signal by themselves. The launcher uses smaller MiMo context budgets, longer timeout cooldowns, and lower output limits to avoid repeated failed long-context turns.
- Brand images under `assets/brand/` are generated Zhuda/ZhuEr derivatives. Only publish or redistribute assets you have rights to use.
- This project is a local adapter/launcher experiment, not an official OpenAI, Google, or Xiaomi product.
