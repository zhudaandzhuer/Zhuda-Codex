#requires -version 5.1
param(
    [string]$ReceiverUrl = "__ZHUDA_RECEIVER_URL__",
    [int]$IntervalSec = 2,
    [switch]$Once,
    [switch]$NoSnapshot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ControlToken = "__ZHUDA_CONTROL_TOKEN__"
$RuntimeDir = Join-Path $env:USERPROFILE ".zhuda-codex-win"
$ReceiverPath = Join-Path $RuntimeDir "receiver.url"
$ClientId = "$env:COMPUTERNAME-$env:USERNAME"
$MaxTailLines = 260
$MaxFileChars = 160000
$MaxOutputChars = 240000

function Ensure-Runtime {
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
}

function Redact-Secret {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $Text = $Text -replace '(?i)data:[^,\s]{1,120};base64,[A-Za-z0-9+/=\r\n]{512,}', '<redacted-long-data-url-base64-blob>'
    $Text = $Text -replace '(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{512,}={0,2}(?![A-Za-z0-9+/=])', '<redacted-long-base64-like-blob>'
    $Text = $Text -replace 'AIza[0-9A-Za-z_-]{20,}', '<redacted-google-api-key>'
    $Text = $Text -replace 'sk-[0-9A-Za-z_-]{20,}', '<redacted-openai-key>'
    $Text = $Text -replace 'AQ\.[0-9A-Za-z_-]{20,}', '<redacted-token>'
    $Text = $Text -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[0-9A-Za-z._~+/=-]{8,}', '${1}<redacted-bearer>'
    $Text = $Text -replace '(?i)(api[_-]?key\s*[:=]\s*)[0-9A-Za-z._~+/=-]{8,}', '${1}<redacted-api-key>'
    return $Text
}

function Trim-Text {
    param([string]$Text, [int]$Limit)
    if ($null -eq $Text) { return "" }
    if ($Text.Length -le $Limit) { return $Text }
    return "[trimmed to last $Limit chars]`n" + $Text.Substring($Text.Length - $Limit)
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
                $content = Trim-Text (Redact-Secret (($lines -join "`n"))) $MaxFileChars
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
                Select-Object -First 20
        } catch {}
    }
    return @($files | Sort-Object FullName -Unique | Sort-Object LastWriteTime -Descending | Select-Object -First 36)
}

function Get-LocalEndpoint {
    param([string]$Path)
    try {
        return Invoke-RestMethod -Uri "http://127.0.0.1:4000$Path" -TimeoutSec 2
    } catch {
        return @{ error = $_.Exception.Message }
    }
}

function Get-CodexProcesses {
    $items = @()
    try {
        $items = Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -match "Codex|ChatGPT|OpenAI|powershell|pwsh|cmd" } |
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
    foreach ($name in @("adapter.episodes.jsonl", "adapter.pool.jsonl", "adapter.requests.jsonl", "adapter.err.log", "model-injector.log", "model-injector.err.log")) {
        Add-FileItem $files "zhuda-win-$name" (Join-Path $RuntimeDir $name)
    }
    foreach ($file in (Find-RecentLogFiles)) {
        Add-FileItem $files ("app-" + $file.Name) $file.FullName
    }

    return @{
        client_id = $ClientId
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

function Invoke-JsonApi {
    param([string]$Method, [string]$Url, [object]$Body = $null)
    $headers = @{ "X-Zhuda-Control-Token" = $ControlToken }
    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -TimeoutSec 20
    }
    $json = $Body | ConvertTo-Json -Depth 80 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec 30
}

function Send-Snapshot {
    param([string]$Url)
    $payload = New-Snapshot
    $json = $payload | ConvertTo-Json -Depth 80 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Invoke-RestMethod -Method Post -Uri "$Url/ingest" -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec 12 | Out-Null
    Write-Host "$(Get-Date -Format s) snapshot sent" -ForegroundColor DarkGreen
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Write-Utf8Bom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Read-SharedText {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return "" }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        try {
            return $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
            $stream = $null
        }
    } catch {
        return "read_error: $($_.Exception.Message)"
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Invoke-RemoteCommand {
    param($Command)
    $id = [string]$Command.id
    $shell = [string]$Command.shell
    if (-not $shell) { $shell = "powershell" }
    $commandText = [string]$Command.command
    $timeout = 60
    try { $timeout = [int]$Command.timeout_sec } catch {}
    if ($timeout -lt 1) { $timeout = 1 }
    if ($timeout -gt 600) { $timeout = 600 }
    $cwd = [string]$Command.cwd
    $started = Get-Date
    $outPath = Join-Path $RuntimeDir "command-$id.out.txt"
    $errPath = Join-Path $RuntimeDir "command-$id.err.txt"
    $scriptPath = Join-Path $RuntimeDir "command-$id.ps1"
    $fileName = "powershell.exe"
    $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath)

    if ($shell -eq "cmd") {
        $scriptPath = Join-Path $RuntimeDir "command-$id.cmd"
        Write-Utf8NoBom $scriptPath ("@echo off`r`n" + $commandText + "`r`n")
        $fileName = "cmd.exe"
        $args = @("/d", "/c", $scriptPath)
    } else {
        # Windows PowerShell 5.1 treats UTF-8 without BOM as ANSI, which corrupts CJK prompts.
        $prelude = "[Console]::InputEncoding = [System.Text.Encoding]::UTF8`r`n[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`r`n`$OutputEncoding = [System.Text.Encoding]::UTF8`r`n"
        Write-Utf8Bom $scriptPath ($prelude + $commandText)
    }

    $result = @{
        client_id = $ClientId
        id = $id
        ok = $false
        exit_code = $null
        duration_ms = 0
        stdout = ""
        stderr = ""
        error = ""
    }

    try {
        $splat = @{
            FilePath = $fileName
            ArgumentList = $args
            RedirectStandardOutput = $outPath
            RedirectStandardError = $errPath
            PassThru = $true
            WindowStyle = "Hidden"
        }
        if ($cwd -and (Test-Path $cwd)) {
            $splat["WorkingDirectory"] = $cwd
        }
        $proc = Start-Process @splat
        $finished = $proc.WaitForExit($timeout * 1000)
        if (-not $finished) {
            try { $proc.Kill() } catch {}
            $result.error = "timeout after $timeout seconds"
            $result.exit_code = -1
        } else {
            try { $proc.Refresh() } catch {}
            $exitCode = 0
            try {
                if ($null -ne $proc.ExitCode) { $exitCode = [int]$proc.ExitCode }
            } catch {
                $exitCode = 0
            }
            $result.exit_code = $exitCode
        }
        if (Test-Path $outPath) { $result.stdout = Trim-Text (Redact-Secret (Read-SharedText $outPath)) $MaxOutputChars }
        if (Test-Path $errPath) { $result.stderr = Trim-Text (Redact-Secret (Read-SharedText $errPath)) $MaxOutputChars }
        if ($null -eq $result.exit_code -and -not $result.error) { $result.exit_code = 0 }
        $result.ok = (-not $result.error -and [int]$result.exit_code -eq 0)
    } catch {
        $result.error = $_.Exception.Message
    }
    $result.duration_ms = [int]((Get-Date) - $started).TotalMilliseconds
    return $result
}

function Poll-And-Run {
    param([string]$Url)
    $encodedClient = [uri]::EscapeDataString($ClientId)
    $next = Invoke-JsonApi "GET" "$Url/api/command/next?client=$encodedClient"
    if ($null -eq $next -or $null -eq $next.command) { return $false }
    $cmd = $next.command
    Write-Host "$(Get-Date -Format s) running command $($cmd.id)" -ForegroundColor Cyan
    $result = Invoke-RemoteCommand $cmd
    Invoke-JsonApi "POST" "$Url/api/command/result" $result | Out-Null
    Write-Host "$(Get-Date -Format s) command $($cmd.id) done exit=$($result.exit_code)" -ForegroundColor Green
    return $true
}

function Main {
    Ensure-Runtime
    $url = Resolve-ReceiverUrl
    Write-Host "Zhuda remote agent connected to $url" -ForegroundColor Cyan
    Write-Host "Client: $ClientId" -ForegroundColor Cyan
    Write-Host "Mac control page: $url/control" -ForegroundColor Cyan
    Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray

    $tick = 0
    while ($true) {
        try {
            if (-not $NoSnapshot -and ($tick -eq 0 -or ($tick % 10) -eq 0)) {
                Send-Snapshot $url
            }
            $ran = Poll-And-Run $url
            if ($ran -and -not $NoSnapshot) {
                Send-Snapshot $url
            }
        } catch {
            Write-Host "$(Get-Date -Format s) agent error: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        if ($Once) { return }
        $tick += 1
        Start-Sleep -Seconds ([Math]::Max(1, $IntervalSec))
    }
}

Main
