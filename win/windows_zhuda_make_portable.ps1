#requires -version 5.1
param(
    [string]$ReceiverUrl = "__ZHUDA_RECEIVER_URL__",
    [string]$Model = "gemma-31b",
    [string]$OutputRoot = "",
    [switch]$Launch,
    [switch]$Zip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ProductId = "9PLM9XGG6VKS"
$RuntimeDir = Join-Path $env:USERPROFILE ".zhuda-codex-win"
$ReceiverPath = Join-Path $RuntimeDir "receiver.url"
if (-not $OutputRoot) {
    $OutputRoot = Join-Path $env:USERPROFILE "Documents\ZhudaCodex\portable"
}

function Ensure-Dir {
    param([string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $enc)
}

function Resolve-ReceiverUrl {
    Ensure-Dir $RuntimeDir
    if ($ReceiverUrl -and $ReceiverUrl -notmatch "^__ZHUDA_") {
        $url = $ReceiverUrl.TrimEnd("/")
        $url | Set-Content -Path $ReceiverPath -Encoding ASCII
        return $url
    }
    if (Test-Path $ReceiverPath) {
        $saved = Get-Content $ReceiverPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($saved) { return $saved.TrimEnd("/") }
    }
    return ""
}

function Download-File {
    param([string]$Url, [string]$Path)
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path
    if (-not (Test-Path $Path)) { throw "download failed: $Url" }
}

function Ensure-CodexInstalled {
    $pkg = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($pkg) { return $pkg }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { throw "Codex is not installed and winget.exe is not available." }
    & winget install --id $ProductId --source msstore --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
    $pkg = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pkg) { throw "Codex install did not produce OpenAI.Codex AppX package." }
    return $pkg
}

function Copy-Tree {
    param([string]$Source, [string]$Dest)
    Ensure-Dir $Dest
    $null = robocopy $Source $Dest /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed with exit code $LASTEXITCODE"
    }
}

function Stop-PortableProcesses {
    param([string]$PortableRoot)
    if (-not $PortableRoot) { return }
    $prefix = $PortableRoot.TrimEnd("\")
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ExecutablePath -and
                $_.ExecutablePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
            } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
    } catch {}
}

function Remove-TreeRobust {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    Stop-PortableProcesses $Path
    $empty = Join-Path $env:TEMP ("zhuda-empty-" + [guid]::NewGuid().ToString("N"))
    Ensure-Dir $empty
    try {
        $null = robocopy $empty $Path /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
        cmd.exe /c rmdir /s /q "`"$Path`"" | Out-Null
    } finally {
        Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Build-Launcher {
    param([string]$PortableRoot, [string]$DefaultModel, [string]$Receiver)

    $localPs1 = @'
#requires -version 5.1
param(
    [string]$Model = "__DEFAULT_MODEL__",
    [switch]$NoLaunch,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppExe = Join-Path $Root "app\Codex.exe"
$ToolsDir = Join-Path $Root "tools"
$Adapter = Join-Path $ToolsDir "windows_zhuda_local_adapter.ps1"
$ProfileRoot = Join-Path $Root "profile"
$CodexHome = Join-Path $ProfileRoot ".codex"
$AppData = Join-Path $ProfileRoot "AppData\Roaming"
$LocalAppData = Join-Path $ProfileRoot "AppData\Local"
$ElectronData = Join-Path $ProfileRoot "ElectronUserData"
$AdapterLogDir = Join-Path $ProfileRoot "logs"

function Ensure-Dir { param([string]$Path) New-Item -ItemType Directory -Force -Path $Path | Out-Null }

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $enc)
}

function Resolve-CodexModelSlug {
    param([string]$Name)
    if ($null -eq $Name) { $Name = "" }
    $key = $Name.Trim().ToLowerInvariant()
    if ($key.StartsWith("gemini-") -or $key.StartsWith("gemma-") -or $key.StartsWith("mimo-") -or $key.StartsWith("models/")) {
        return $Name.Trim()
    }
    switch ($key) {
        "gemma-31b" { return "gpt-5.5" }
        "31b" { return "gpt-5.5" }
        "zhuda-gemma-31b" { return "gpt-5.5" }
        "gemma-26b" { return "gpt-5.3-codex" }
        "26b" { return "gpt-5.3-codex" }
        "zhuda-gemma-26b" { return "gpt-5.3-codex" }
        "flash-lite" { return "gpt-5.4-mini" }
        "zhuda-flash-lite" { return "gpt-5.4-mini" }
        "flash-3.5" { return "gpt-5.4" }
        "zhuda-flash-3-5" { return "gpt-5.4" }
        "flash-3" { return "gpt-5.2" }
        "zhuda-flash-3" { return "gpt-5.2" }
        default { return "gpt-5.5" }
    }
}

function Test-Adapter {
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:4000/health/readiness" -TimeoutSec 2
        return ($health.status -eq "healthy")
    } catch {
        return $false
    }
}

function Stop-AdapterProcesses {
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine.Contains("windows_zhuda_local_adapter.ps1")
            } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
    } catch {}
}

Ensure-Dir $ProfileRoot
Ensure-Dir $CodexHome
Ensure-Dir $AppData
Ensure-Dir $LocalAppData
Ensure-Dir $ElectronData
Ensure-Dir $AdapterLogDir

$env:USERPROFILE = $ProfileRoot
$env:APPDATA = $AppData
$env:LOCALAPPDATA = $LocalAppData
$env:CODEX_HOME = $CodexHome
$env:ZHUDA_CODEX_PORTABLE = "1"

$codexModel = Resolve-CodexModelSlug $Model
$config = @"
model = "$codexModel"
model_provider = "zhuda_gemini_pool"
model_context_window = 49152
model_auto_compact_token_limit = 32000
tool_output_token_limit = 4000
check_for_update_on_startup = false

[model_providers.zhuda_gemini_pool]
name = "Zhuda Local Gemini"
base_url = "http://127.0.0.1:4000/v1"
wire_api = "responses"
experimental_bearer_token = "zhuda-codex-local-token"

[windows]
sandbox = "unelevated"
"@
Write-Utf8NoBom (Join-Path $CodexHome "config.toml") $config

if ($DryRun) {
    Write-Output "root=$Root"
    Write-Output "app=$AppExe"
    Write-Output "profile=$ProfileRoot"
    Write-Output "codex_home=$CodexHome"
    Write-Output "model=$Model"
    Write-Output "codex_model=$codexModel"
    Write-Output "adapter=$Adapter"
    Write-Output "adapter_healthy=$(Test-Adapter)"
    exit 0
}

if (-not (Test-Path $AppExe)) { throw "missing portable app exe: $AppExe" }
if (-not (Test-Path $Adapter)) { throw "missing adapter script: $Adapter" }

if ($env:ZHUDA_GEMINI_API_KEY -or $env:GEMINI_API_KEY_1 -or $env:GEMINI_API_KEY) {
    Stop-AdapterProcesses
    Start-Sleep -Milliseconds 300
}

if (-not (Test-Adapter)) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Adapter,
        "-ServeOnly", "-Model", $Model
    ) -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 300
        if (Test-Adapter) { break }
    }
}

if (-not (Test-Adapter)) {
    Write-Warning "Adapter is not healthy yet; launching Codex anyway."
}

if (-not $NoLaunch) {
    Start-Process -FilePath $AppExe -WorkingDirectory (Join-Path $Root "app") -ArgumentList @("--user-data-dir=$ElectronData") | Out-Null
}
'@
    $localPs1 = $localPs1.Replace("__DEFAULT_MODEL__", $DefaultModel)
    Write-Utf8NoBom (Join-Path $PortableRoot "Start-Zhuda-Codex-Local.ps1") $localPs1
    Write-Utf8NoBom (Join-Path $PortableRoot "Start-Zhuda-Codex-Local.cmd") "@echo off`r`ncall `"%~dp0Zhuda-Codex-Launcher.cmd`"`r`n"

    $logsCmd = "@echo off`r`nstart `"`" `"__RECEIVER__/logs`"`r`n"
    if ($Receiver) {
        $logsCmd = $logsCmd.Replace("__RECEIVER__", $Receiver)
    } else {
        $logsCmd = $logsCmd.Replace("__RECEIVER__", "http://127.0.0.1:4100")
    }
    Write-Utf8NoBom (Join-Path $PortableRoot "Open-Zhuda-Logs.cmd") $logsCmd
    Write-Utf8NoBom (Join-Path $PortableRoot "Start-Zhuda-Codex.cmd") "@echo off`r`ncall `"%~dp0Zhuda-Codex-Launcher.cmd`"`r`n"

    $readme = @"
Zhuda-Codex portable

Run:
  Zhuda-Codex-Launcher.cmd

Advanced direct launch:
  Start-Zhuda-Codex-Local.cmd

PowerShell options:
  powershell -NoProfile -ExecutionPolicy Bypass -File Zhuda-Codex-Launcher.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File Start-Zhuda-Codex-Local.ps1 -Model gemma-31b
  powershell -NoProfile -ExecutionPolicy Bypass -File Start-Zhuda-Codex-Local.ps1 -Model flash-lite

Portable profile:
  profile\

Bundled app:
  app\Codex.exe

Logs:
  Open-Zhuda-Logs.cmd
"@
    Write-Utf8NoBom (Join-Path $PortableRoot "README.txt") $readme
}

function Main {
    Ensure-Dir $RuntimeDir
    $receiver = Resolve-ReceiverUrl
    $pkg = Ensure-CodexInstalled
    $source = Join-Path $pkg.InstallLocation "app"
    if (-not (Test-Path $source)) { $source = $pkg.InstallLocation }
    if (-not (Test-Path (Join-Path $source "Codex.exe"))) {
        throw "Could not find Codex.exe under $source"
    }

    $portableRoot = Join-Path $OutputRoot "Zhuda-Codex"
    $tmpRoot = Join-Path $OutputRoot "Zhuda-Codex.tmp"
    if (Test-Path $tmpRoot) { Remove-TreeRobust $tmpRoot }
    Ensure-Dir $tmpRoot
    Ensure-Dir (Join-Path $tmpRoot "app")
    Ensure-Dir (Join-Path $tmpRoot "tools")

    Copy-Tree $source (Join-Path $tmpRoot "app")

    $toolNames = @(
        "windows_zhuda_local_adapter.ps1",
        "windows_zhuda_remote.ps1",
        "windows_zhuda_connect.ps1"
    )
    foreach ($name in $toolNames) {
        $local = Join-Path $RuntimeDir $name
        if ($receiver) {
            try { Download-File "$receiver/download/$name" $local } catch {}
        }
        if (-not (Test-Path $local)) {
            $candidate = Join-Path (Split-Path -Parent $PSCommandPath) $name
            if (Test-Path $candidate) { $local = $candidate }
        }
        if (-not (Test-Path $local) -and $name -eq "windows_zhuda_local_adapter.ps1") {
            $legacy = Join-Path (Split-Path -Parent $PSCommandPath) "legacy\windows_zhuda_codex_switch.ps1"
            if (Test-Path $legacy) { $local = $legacy }
        }
        if (-not (Test-Path $local)) { throw "missing tool script: $local" }
        Copy-Item $local (Join-Path $tmpRoot "tools\$name") -Force
    }

    foreach ($name in @("providers.json", "Zhuda-Codex-Launcher.ps1", "Zhuda-Codex-Launcher.cmd")) {
        $local = Join-Path $RuntimeDir $name
        if ($receiver) {
            try { Download-File "$receiver/download/$name" $local } catch {}
        }
        if (-not (Test-Path $local)) {
            $candidate = Join-Path (Split-Path -Parent $PSCommandPath) $name
            if (Test-Path $candidate) { $local = $candidate }
        }
        if (-not (Test-Path $local)) { throw "missing portable launcher asset: $name" }
        Copy-Item $local (Join-Path $tmpRoot $name) -Force
    }

    $launcherTmp = Join-Path $tmpRoot "launcher"
    Ensure-Dir $launcherTmp
    $sourceRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    $sharedLauncher = Join-Path $sourceRoot "launcher\zhuda_web_launcher.ps1"
    if (Test-Path $sharedLauncher) {
        Copy-Item $sharedLauncher (Join-Path $launcherTmp "zhuda_web_launcher.ps1") -Force
    } else {
        throw "missing shared web launcher: $sharedLauncher"
    }
    $sharedWeb = Join-Path $sourceRoot "launcher\web"
    if (Test-Path $sharedWeb) {
        Copy-Tree $sharedWeb (Join-Path $launcherTmp "web")
    } else {
        throw "missing shared web assets: $sharedWeb"
    }

    $brandTmp = Join-Path $tmpRoot "assets\brand"
    Ensure-Dir $brandTmp
    foreach ($name in @(
        "zhuda-codex-launcher-hero-533x300.png",
        "zhuda-codex-launcher-hero.png",
        "zhuda-codex-app-icon-180.png",
        "zhuda-codex-app-icon.png",
        "zhuda-codex-provider-gemini-240x180.png",
        "zhuda-codex-provider-gemini.png"
    )) {
        $local = Join-Path $RuntimeDir "assets\brand\$name"
        if ($receiver) {
            try {
                Ensure-Dir (Split-Path -Parent $local)
                Download-File "$receiver/download/assets/brand/$name" $local
            } catch {}
        }
        if (-not (Test-Path $local)) {
            foreach ($candidate in @(
                (Join-Path (Split-Path -Parent $PSCommandPath) "assets\brand\$name"),
                (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) "assets\brand\$name")
            )) {
                if (Test-Path $candidate) {
                    $local = $candidate
                    break
                }
            }
        }
        if (Test-Path $local) {
            Copy-Item $local (Join-Path $brandTmp $name) -Force
        }
    }

    Build-Launcher $tmpRoot $Model $receiver

    if (Test-Path $portableRoot) { Remove-TreeRobust $portableRoot }
    Move-Item $tmpRoot $portableRoot

    $zipPath = Join-Path $OutputRoot "Zhuda-Codex-Portable.zip"
    if ($Zip) {
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Compress-Archive -Path $portableRoot -DestinationPath $zipPath -Force
    }

    Write-Output "portable_root=$portableRoot"
    Write-Output "codex_version=$($pkg.Version)"
    Write-Output "source=$source"
    Write-Output "launcher=$(Join-Path $portableRoot 'Start-Zhuda-Codex-Local.cmd')"
    if ($Zip) { Write-Output "zip=$zipPath" }

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $portableRoot "Start-Zhuda-Codex-Local.ps1") -Model $Model -DryRun

    if ($Launch) {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $portableRoot "Start-Zhuda-Codex-Local.ps1") -Model $Model
    }
}

Main
