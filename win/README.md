# Zhuda-Codex Windows

Windows files for launching Codex through the Zhuda-Codex local adapter, connecting a Windows host to a macOS LAN receiver, and building a portable Codex bundle.

## Local Launcher

```powershell
.\Zhuda-Codex-Launcher.cmd
```

The launcher opens the shared Web UI. Choose a provider card, enter an API key, choose model mappings, and launch Codex. The API key is passed to the launched process environment for that session and is not saved into this source folder.

## Remote Onboarding

If a macOS receiver is running, use this template from the Windows machine:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr 'http://YOUR_MAC_IP:4100/download/windows_zhuda_connect.ps1' -OutFile \"$env:TEMP\zhuda_connect.ps1\"; powershell -NoProfile -ExecutionPolicy Bypass -File \"$env:TEMP\zhuda_connect.ps1\" -Mode local -Model gemma-31b"
```

The Windows remote agent forwards redacted logs and status snapshots to the receiver so problems can be diagnosed from one place.

## Portable Bundle

Build a portable bundle from an installed Windows Codex app:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows_zhuda_make_portable.ps1
```

Portable entry points:

```text
Zhuda-Codex-Launcher.cmd
Start-Zhuda-Codex.cmd
Start-Zhuda-Codex-Local.cmd
Open-Zhuda-Logs.cmd
```

Portable profiles and runtime logs are generated locally and should not be committed.

## Providers

Provider and model options come from the repository root `providers.json`.

Current provider cards:

- Gemini: Flash 3.5, Flash 3.0, Flash Lite 3.1, Pro 3.1, Gemma 31B
- Xiaomi MiMo: MiMo v2.5 Pro, MiMo v2.5

## Open Source Checklist

Do not publish local runtime files, portable output folders, logs, or secrets. The source tree should contain scripts and public assets only.
