#requires -version 5.1
param(
    [string]$InstallDir = "",
    [switch]$BuildPortable,
    [switch]$SkipCodexInstall,
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$RepoZipUrl = if ($env:ZHUDA_CODEX_REPO_ZIP_URL) { $env:ZHUDA_CODEX_REPO_ZIP_URL } else { "https://github.com/zhudaandzhuer/Zhuda-Codex/archive/refs/heads/main.zip" }
$CodexProductId = "9PLM9XGG6VKS"
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

function Get-CodexPackage {
    Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Ensure-CodexDesktop {
    $pkg = Get-CodexPackage
    if ($pkg) {
        Write-Host "Codex Desktop found: $($pkg.Version)"
        return
    }
    if ($SkipCodexInstall) {
        Write-Warning "Codex Desktop is not installed. Zhuda-Codex can install adapter files, but it cannot launch Codex until the official app is installed."
        return
    }

    Write-Host "Codex Desktop is not installed. Installing official Codex Desktop from Microsoft Store..."
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        & winget install --id $CodexProductId --source msstore --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
        $pkg = Get-CodexPackage
        if ($pkg) {
            Write-Host "Codex Desktop installed: $($pkg.Version)"
            return
        }
    }

    Write-Warning "Automatic Store install did not complete. Opening Microsoft Store page. Install Codex Desktop there, then rerun this installer."
    Start-Process "ms-windows-store://pdp/?productid=$CodexProductId" | Out-Null
    throw "Codex Desktop is required before Zhuda-Codex can launch."
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

    Ensure-CodexDesktop

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
