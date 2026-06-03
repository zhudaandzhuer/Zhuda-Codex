#requires -version 5.1
param(
    [string]$ReceiverUrl = "",
    [int]$IntervalSec = 3,
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DefaultReceiverUrl = "http://YOUR_MAC_IP:4100"
$RuntimeDir = Join-Path $env:USERPROFILE ".zhuda-codex-win"
$ReceiverPath = Join-Path $RuntimeDir "receiver.url"
$MaxTailLines = 240
$MaxFileChars = 120000

function Ensure-Runtime {
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
}

function Redact-Secret {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $Text = $Text -replace 'AIza[0-9A-Za-z_-]{20,}', '<redacted-google-api-key>'
    $Text = $Text -replace 'sk-[0-9A-Za-z_-]{20,}', '<redacted-openai-key>'
    $Text = $Text -replace 'AQ\.[0-9A-Za-z_-]{20,}', '<redacted-token>'
    $Text = $Text -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[0-9A-Za-z._~+/=-]{8,}', '${1}<redacted-bearer>'
    $Text = $Text -replace '(?i)(api[_-]?key\s*[:=]\s*)[0-9A-Za-z._~+/=-]{8,}', '${1}<redacted-api-key>'
    return $Text
}

function Resolve-ReceiverUrl {
    Ensure-Runtime
    if ($ReceiverUrl) { return $ReceiverUrl.TrimEnd("/") }
    if (Test-Path $ReceiverPath) {
        $saved = (Get-Content $ReceiverPath -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($saved) { return $saved.TrimEnd("/") }
    }
    Write-Host ""
    Write-Host "Mac receiver URL. Press Enter to use default: $DefaultReceiverUrl" -ForegroundColor Cyan
    $entered = Read-Host "Receiver URL"
    if (-not $entered) { $entered = $DefaultReceiverUrl }
    $entered = $entered.TrimEnd("/")
    $entered | Set-Content -Path $ReceiverPath -Encoding ASCII
    return $entered
}

function Add-FileItem {
    param([System.Collections.ArrayList]$Items, [string]$Label, [string]$Path)
    if (-not $Path) { return }
    $exists = Test-Path $Path
    $content = ""
    $lastWrite = ""
    if ($exists) {
        try {
            $info = Get-Item $Path -ErrorAction Stop
            $lastWrite = $info.LastWriteTime.ToString("s")
            if ($info.Length -gt 0) {
                $lines = @(Get-Content -Path $Path -Tail $MaxTailLines -ErrorAction Stop)
                $content = Redact-Secret (($lines -join "`n"))
                if ($content.Length -gt $MaxFileChars) {
                    $content = $content.Substring($content.Length - $MaxFileChars)
                }
            }
        } catch {
            $content = "read_error: $($_.Exception.Message)"
        }
    }
    [void]$Items.Add(@{
        label = $Label
        path = $Path
        exists = $exists
        last_write_time = $lastWrite
        content = $content
    })
}

function Find-RecentLogFiles {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($path in @(
        (Join-Path $env:APPDATA "Codex"),
        (Join-Path $env:APPDATA "OpenAI"),
        (Join-Path $env:LOCALAPPDATA "Codex"),
        (Join-Path $env:LOCALAPPDATA "OpenAI"),
        (Join-Path $env:USERPROFILE ".codex")
    )) {
        if (Test-Path $path) { $roots.Add($path) }
    }
    $packageRoot = Join-Path $env:LOCALAPPDATA "Packages"
    if (Test-Path $packageRoot) {
        Get-ChildItem -Path $packageRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "OpenAI|Codex|ChatGPT" } |
            ForEach-Object { $roots.Add($_.FullName) }
    }

    $files = @()
    foreach ($root in $roots) {
        try {
            $files += Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in @(".log", ".jsonl", ".txt", ".toml") } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 16
        } catch {}
    }
    return @($files | Sort-Object FullName -Unique | Sort-Object LastWriteTime -Descending | Select-Object -First 32)
}

function Get-LocalEndpoint {
    param([string]$Path)
    try {
        $value = Invoke-RestMethod -Uri "http://127.0.0.1:4000$Path" -TimeoutSec 2
        return $value
    } catch {
        return @{ error = $_.Exception.Message }
    }
}

function Get-CodexProcesses {
    $items = @()
    try {
        $items = Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -match "Codex|ChatGPT|OpenAI" } |
            ForEach-Object {
                $startTime = ""
                try { $startTime = $_.StartTime.ToString("s") } catch {}
                @{
                    name = $_.ProcessName
                    id = $_.Id
                    path = Redact-Secret $_.Path
                    start_time = $startTime
                }
            }
    } catch {}
    return @($items)
}

function New-Snapshot {
    $files = New-Object System.Collections.ArrayList
    Add-FileItem $files "codex-config" (Join-Path $env:USERPROFILE ".codex\config.toml")
    Add-FileItem $files "codex-config-backup" (Join-Path $env:USERPROFILE ".codex\config.toml.before-zhuda-local")
    foreach ($name in @("adapter.episodes.jsonl", "adapter.pool.jsonl", "adapter.requests.jsonl", "adapter.err.log")) {
        Add-FileItem $files "zhuda-win-$name" (Join-Path $RuntimeDir $name)
    }
    foreach ($file in (Find-RecentLogFiles)) {
        Add-FileItem $files ("app-" + $file.Name) $file.FullName
    }

    return @{
        client_id = "$env:COMPUTERNAME-$env:USERNAME"
        computer = $env:COMPUTERNAME
        user = $env:USERNAME
        created_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        ps_version = $PSVersionTable.PSVersion.ToString()
        local_4000_health = Get-LocalEndpoint "/health/readiness"
        local_4000_pool_status = Get-LocalEndpoint "/pool/status"
        codex_processes = Get-CodexProcesses
        files = @($files)
    }
}

function Send-Snapshot {
    param([string]$Url)
    $payload = New-Snapshot
    $json = $payload | ConvertTo-Json -Depth 80 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Invoke-RestMethod -Method Post -Uri "$Url/ingest" -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec 8 | Out-Null
    Write-Host "$(Get-Date -Format s) sent logs to $Url" -ForegroundColor Green
}

function Main {
    $url = Resolve-ReceiverUrl
    Write-Host "Forwarding logs to $url every $IntervalSec seconds." -ForegroundColor Cyan
    Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
    while ($true) {
        try {
            Send-Snapshot $url
        } catch {
            Write-Host "$(Get-Date -Format s) send failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        if ($Once) { return }
        Start-Sleep -Seconds ([Math]::Max(1, $IntervalSec))
    }
}

Main
