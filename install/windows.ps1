#requires -version 5.1
param(
    [string]$InstallDir = "",
    [switch]$BuildPortable,
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$RepoZipUrl = if ($env:ZHUDA_CODEX_REPO_ZIP_URL) { $env:ZHUDA_CODEX_REPO_ZIP_URL } else { "https://github.com/zhudaandzhuer/Zhuda-Codex/archive/refs/heads/main.zip" }
if (-not $InstallDir) {
    $InstallDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "ZhudaCodex"
}

$TempRoot = Join-Path $env:TEMP ("zhuda-codex-install-" + [guid]::NewGuid().ToString("N"))
$ZipPath = Join-Path $TempRoot "Zhuda-Codex-main.zip"
$ExtractRoot = Join-Path $TempRoot "extract"

function Ensure-Dir {
    param([string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

try {
    Write-Host "Installing Zhuda-Codex to: $InstallDir"
    Ensure-Dir $TempRoot
    Ensure-Dir $ExtractRoot
    Ensure-Dir $InstallDir

    Invoke-WebRequest -UseBasicParsing -Uri $RepoZipUrl -OutFile $ZipPath
    Expand-Archive -Path $ZipPath -DestinationPath $ExtractRoot -Force

    $Source = Join-Path $ExtractRoot "Zhuda-Codex-main"
    if (-not (Test-Path $Source)) {
        throw "Could not unpack Zhuda-Codex source zip."
    }

    robocopy $Source $InstallDir /MIR /XD ".git" "release" "mac\dist" /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed with exit code $LASTEXITCODE"
    }

    if ($BuildPortable) {
        $Builder = Join-Path $InstallDir "win\windows_zhuda_make_portable.ps1"
        if (-not (Test-Path $Builder)) { throw "Missing builder: $Builder" }
        powershell -NoProfile -ExecutionPolicy Bypass -File $Builder -Zip
    }

    if (-not $NoLaunch) {
        $Launcher = Join-Path $InstallDir "win\Zhuda-Codex-Launcher.cmd"
        if (-not (Test-Path $Launcher)) { throw "Missing launcher: $Launcher" }
        Start-Process -FilePath $Launcher -WorkingDirectory (Split-Path -Parent $Launcher)
    }
} finally {
    Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

