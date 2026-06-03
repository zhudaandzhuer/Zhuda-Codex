#requires -version 5.1
param(
    [string]$ReceiverUrl = "__ZHUDA_RECEIVER_URL__",
    [ValidateSet("local", "official", "remote-only")]
    [string]$Mode = "local",
    [string]$Model = "gemma-31b",
    [switch]$NoAgent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeDir = Join-Path $env:USERPROFILE ".zhuda-codex-win"
$DesktopDir = [Environment]::GetFolderPath("Desktop")
$ReceiverPath = Join-Path $RuntimeDir "receiver.url"

function Ensure-Runtime {
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
}

function Resolve-ReceiverUrl {
    Ensure-Runtime
    if ($ReceiverUrl -and $ReceiverUrl -notmatch "^__ZHUDA_") {
        $url = $ReceiverUrl.TrimEnd("/")
        $url | Set-Content -Path $ReceiverPath -Encoding ASCII
        return $url
    }
    if (Test-Path $ReceiverPath) {
        $saved = Get-Content $ReceiverPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($saved) { return $saved.TrimEnd("/") }
    }
    $fallback = "__ZHUDA_RECEIVER_URL__"
    $fallback | Set-Content -Path $ReceiverPath -Encoding ASCII
    return $fallback
}

function Download-File {
    param([string]$Url, [string]$Path)
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path
    if (-not (Test-Path $Path)) { throw "download failed: $Url" }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $enc)
}

function Install-Shortcuts {
    param([string]$ConnectPath)
    if (-not $DesktopDir) { return }
    $localCmd = Join-Path $DesktopDir "Zhuda Codex Local.cmd"
    $officialCmd = Join-Path $DesktopDir "Zhuda Codex Official.cmd"
    $agentCmd = Join-Path $DesktopDir "Zhuda Remote Agent.cmd"
    $launcherCmd = Join-Path $DesktopDir "Zhuda Codex Launcher.cmd"
    $launcherPath = Join-Path $RuntimeDir "Zhuda-Codex-Launcher.cmd"
    Write-Utf8NoBom $localCmd "@echo off`r`ncall `"$launcherPath`"`r`n"
    Write-Utf8NoBom $officialCmd "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$ConnectPath`" -Mode official`r`npause`r`n"
    Write-Utf8NoBom $agentCmd "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$ConnectPath`" -Mode remote-only`r`npause`r`n"
    Write-Utf8NoBom $launcherCmd "@echo off`r`ncall `"$launcherPath`"`r`n"
}

function Start-RemoteAgent {
    param([string]$RemoteScript, [string]$Url)
    $already = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains("windows_zhuda_remote.ps1") } |
        Select-Object -First 1
    if ($already) {
        Write-Host "Remote agent already running: pid $($already.ProcessId)" -ForegroundColor Green
        return
    }
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $RemoteScript,
        "-ReceiverUrl", $Url, "-IntervalSec", "2"
    ) -WindowStyle Hidden | Out-Null
    Write-Host "Remote agent started." -ForegroundColor Green
}

function Main {
    Ensure-Runtime
    $url = Resolve-ReceiverUrl
    $remoteScript = Join-Path $RuntimeDir "windows_zhuda_remote.ps1"
    $adapterScript = Join-Path $RuntimeDir "windows_zhuda_local_adapter.ps1"
    $connectPath = Join-Path $RuntimeDir "windows_zhuda_connect.ps1"
    $providersPath = Join-Path $RuntimeDir "providers.json"
    $launcherScript = Join-Path $RuntimeDir "Zhuda-Codex-Launcher.ps1"
    $launcherCmd = Join-Path $RuntimeDir "Zhuda-Codex-Launcher.cmd"
    $launcherDir = Join-Path $RuntimeDir "launcher"
    $launcherWebDir = Join-Path $launcherDir "web"
    $brandDir = Join-Path $RuntimeDir "assets\brand"

    Write-Host "Zhuda receiver: $url" -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $brandDir | Out-Null
    New-Item -ItemType Directory -Force -Path $launcherWebDir | Out-Null
    Download-File "$url/download/windows_zhuda_remote.ps1" $remoteScript
    Download-File "$url/download/windows_zhuda_local_adapter.ps1" $adapterScript
    Download-File "$url/download/windows_zhuda_connect.ps1" $connectPath
    Download-File "$url/download/providers.json" $providersPath
    Download-File "$url/download/Zhuda-Codex-Launcher.ps1" $launcherScript
    Download-File "$url/download/Zhuda-Codex-Launcher.cmd" $launcherCmd
    Download-File "$url/download/launcher/zhuda_web_launcher.ps1" (Join-Path $launcherDir "zhuda_web_launcher.ps1")
    foreach ($asset in @(
        "index.html",
        "styles.css",
        "app.js"
    )) {
        Download-File "$url/download/launcher/web/$asset" (Join-Path $launcherWebDir $asset)
    }
    foreach ($asset in @(
        "zhuda-codex-launcher-hero-533x300.png",
        "zhuda-codex-launcher-hero.png",
        "zhuda-codex-app-icon-180.png",
        "zhuda-codex-app-icon.png",
        "zhuda-codex-provider-gemini-240x180.png",
        "zhuda-codex-provider-gemini.png"
    )) {
        Download-File "$url/download/assets/brand/$asset" (Join-Path $brandDir $asset)
    }
    Install-Shortcuts $connectPath

    if (-not $NoAgent) {
        Start-RemoteAgent $remoteScript $url
    }

    if ($Mode -eq "local") {
        Write-Host "Switching Codex Desktop to Zhuda local adapter, model: $Model" -ForegroundColor Cyan
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File $adapterScript -Local -Model $Model
    } elseif ($Mode -eq "official") {
        Write-Host "Switching Codex Desktop to official route." -ForegroundColor Cyan
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File $adapterScript -Official
    } else {
        Write-Host "Remote-only mode. Codex route was not changed." -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "Mac logs:    $url/logs" -ForegroundColor Green
    Write-Host "Mac control: $url/control" -ForegroundColor Green
    Write-Host "Runtime:     $RuntimeDir" -ForegroundColor DarkGray
}

Main
