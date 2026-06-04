#requires -version 5.1
param(
    [switch]$Server,
    [switch]$ServeOnly,
    [switch]$Local,
    [switch]$Official,
    [switch]$SetModel,
    [string]$Model = "",
    [switch]$SetRateProfile,
    [string]$RateProfile = "",
    [switch]$RepairConfig,
    [switch]$SandboxFallback
)

# PowerShell 5.1 StrictMode Latest is brittle with JSON PSCustomObject values
# and can turn harmless scalar/empty-list access into adapter HTTP 500s.
Set-StrictMode -Off
$ErrorActionPreference = "Stop"

$ScriptPath = $PSCommandPath
$RuntimeDir = Join-Path $env:USERPROFILE ".zhuda-codex-win"
$ConfigDir = Join-Path $env:USERPROFILE ".codex"
$ConfigPath = Join-Path $ConfigDir "config.toml"
$BackupPath = Join-Path $ConfigDir "config.toml.before-zhuda-local"
$PidPath = Join-Path $RuntimeDir "adapter.pid"
$ProviderPath = Join-Path $RuntimeDir "active_provider.txt"
$ModelPath = Join-Path $RuntimeDir "active_model.txt"
$MappingsPath = Join-Path $RuntimeDir "active_mappings.json"
$ApiKeyPath = Join-Path $RuntimeDir "active_api_key.txt"
$ModelCatalogPath = Join-Path $RuntimeDir "zhuda-model-catalog.json"
$ModelCachePath = Join-Path $ConfigDir "models_cache.json"
$ModelCacheBackupPath = Join-Path $ConfigDir "models_cache.json.before-zhuda-local"
$LocalModeMarkerPath = Join-Path $RuntimeDir "local-mode.enabled"
$RateProfilePath = Join-Path $RuntimeDir "rate_profile.txt"
$Port = 4000
$BaseUrl = "http://127.0.0.1:$Port"
$LocalBearer = "zhuda-codex-local-token"
$DefaultGeminiApiKey = ""
$DefaultProvider = "gemini"
$Provider = $DefaultProvider
$ModelMappings = @{}
$GeminiApiKey = $DefaultGeminiApiKey
$DefaultGeminiModel = "gemini-3.1-flash-lite"
$GeminiModel = $DefaultGeminiModel
$DefaultRateProfile = "free"
$script:LocalRateHistory = @{}
$TimeoutSec = 60
$MaxPromptChars = 36000

$LogFiles = @(
    @{ Label = "Episodes"; File = "adapter.episodes.jsonl" },
    @{ Label = "Pool attempts"; File = "adapter.pool.jsonl" },
    @{ Label = "Requests"; File = "adapter.requests.jsonl" },
    @{ Label = "Errors"; File = "adapter.err.log" }
)

function Resolve-GeminiModel {
    param([string]$Name)
    if (-not $Name) { return $DefaultGeminiModel }
    $key = $Name.Trim().ToLowerInvariant()
    if ($script:ModelMappings -and $script:ModelMappings.ContainsKey($key)) {
        return [string]$script:ModelMappings[$key]
    }
    $aliases = @{
        "zhuda-default" = $DefaultGeminiModel
        "zhuda-gemma-31b" = "gemma-4-31b-it"
        "gemma-31b" = "gemma-4-31b-it"
        "31b" = "gemma-4-31b-it"
        "gemma31b" = "gemma-4-31b-it"
        "gemma-4-31b" = "gemma-4-31b-it"
        "gemma-4-31b-it" = "gemma-4-31b-it"
        "gpt-5.5" = "gemma-4-31b-it"
        "zhuda-gemma-26b" = "gemma-4-26b-a4b-it"
        "gemma-26b" = "gemma-4-26b-a4b-it"
        "26b" = "gemma-4-26b-a4b-it"
        "gemma26b" = "gemma-4-26b-a4b-it"
        "gemma-4-26b" = "gemma-4-26b-a4b-it"
        "gemma-4-26b-a4b-it" = "gemma-4-26b-a4b-it"
        "gpt-5.3-codex" = "gemma-4-26b-a4b-it"
        "zhuda-flash-lite" = "gemini-3.1-flash-lite"
        "flash-lite" = "gemini-3.1-flash-lite"
        "gemini-flash-lite" = "gemini-3.1-flash-lite"
        "gemini-3.1-flash-lite" = "gemini-3.1-flash-lite"
        "3.1-lite" = "gemini-3.1-flash-lite"
        "gpt-5.4-mini" = "gemini-3.1-flash-lite"
        "codex-auto-review" = "gemini-3.1-flash-lite"
        "zhuda-flash-3-5" = "gemini-3.5-flash"
        "flash-3.5" = "gemini-3.5-flash"
        "gemini-3.5-flash" = "gemini-3.5-flash"
        "gpt-5.4" = "gemini-3.5-flash"
        "zhuda-flash-3" = "gemini-3-flash-preview"
        "flash-3" = "gemini-3-flash-preview"
        "gemini-3-flash-preview" = "gemini-3-flash-preview"
        "gpt-5.2" = "gemini-3-flash-preview"
    }
    if ($aliases.ContainsKey($key)) { return $aliases[$key] }
    return $Name.Trim()
}

function Is-ZhudaModelAlias {
    param([string]$Name)
    if (-not $Name) { return $false }
    $key = $Name.Trim().ToLowerInvariant()
    if ($script:ModelMappings -and $script:ModelMappings.ContainsKey($key)) { return $true }
    return @(
        "gemini-codex",
        "zhuda-default",
        "zhuda-gemma-31b",
        "zhuda-gemma-26b",
        "zhuda-flash-lite",
        "zhuda-flash-3-5",
        "zhuda-flash-3",
        "gemma-31b",
        "gemma-26b",
        "flash-lite",
        "flash-3.5",
        "flash-3",
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.3-codex",
        "gpt-5.2",
        "codex-auto-review"
    ) -contains $key
}

function Resolve-RequestedGeminiModel {
    param([string]$RequestedModel)
    if (-not $RequestedModel) { return $GeminiModel }
    $trimmed = $RequestedModel.Trim()
    $key = $trimmed.ToLowerInvariant()
    if ($key -eq "gemini-codex" -or $key -eq "zhuda-default") { return $GeminiModel }
    if (Is-ZhudaModelAlias $trimmed) { return (Resolve-GeminiModel $trimmed) }
    if ($key.StartsWith("gemini-") -or $key.StartsWith("gemma-") -or $key.StartsWith("gpt-") -or $key.StartsWith("mimo-") -or $key.StartsWith("models/")) {
        return (Resolve-GeminiModel $trimmed)
    }
    return $GeminiModel
}

function Load-ActiveProvider {
    $selected = ""
    $envProvider = [Environment]::GetEnvironmentVariable("ZHUDA_PROVIDER", "Process")
    if ($envProvider) { $selected = $envProvider }
    if (-not $selected -and (Test-Path $ProviderPath)) {
        try { $selected = (Get-Content $ProviderPath -ErrorAction Stop | Select-Object -First 1) } catch {}
    }
    if (-not $selected) { $selected = $DefaultProvider }
    $selected = $selected.Trim().ToLowerInvariant()
    if ($selected -in @("mimo", "xiaomi", "xiaomi_mimo", "xiaomi-mimo")) {
        $script:Provider = "mimo"
    } else {
        $script:Provider = "gemini"
    }
}

function Load-ModelMappings {
    $table = @{}
    $raw = [Environment]::GetEnvironmentVariable("ZHUDA_MODEL_MAPPINGS", "Process")
    if (-not $raw -and (Test-Path $MappingsPath)) {
        try { $raw = [IO.File]::ReadAllText($MappingsPath) } catch {}
    }
    if ($raw) {
        $raw = $raw.Trim()
        if ($raw.StartsWith("{")) {
            try {
                $json = $raw | ConvertFrom-Json
                foreach ($prop in $json.PSObject.Properties) {
                    if ($prop.Name -and $prop.Value) { $table[$prop.Name.ToLowerInvariant()] = [string]$prop.Value }
                }
            } catch {
                Write-ErrorLog "Failed to parse ZHUDA_MODEL_MAPPINGS JSON: $($_.Exception.Message)"
            }
        } else {
            foreach ($item in ($raw -split ",")) {
                if (-not $item.Trim() -or -not $item.Contains("=")) { continue }
                $parts = $item.Split("=", 2)
                $key = $parts[0].Trim().ToLowerInvariant()
                $value = $parts[1].Trim()
                if ($key -and $value) { $table[$key] = $value }
            }
        }
    }
    $script:ModelMappings = $table
}

function Load-ActiveModel {
    $selected = ""
    if (Test-Path $ModelPath) {
        try { $selected = (Get-Content $ModelPath -ErrorAction Stop | Select-Object -First 1) } catch {}
    }
    if (-not $selected) { $selected = $Model }
    $script:GeminiModel = Resolve-GeminiModel $selected
}

function Load-ActiveApiKey {
    $selected = ""
    $names = if ($script:Provider -eq "mimo") {
        @("MIMO_API_KEY_1", "MIMO_API_KEY", "XIAOMI_MIMO_API_KEY", "ZHUDA_MIMO_API_KEY")
    } else {
        @("ZHUDA_GEMINI_API_KEY", "GEMINI_API_KEY_1", "GEMINI_API_KEY")
    }
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name, "Process")
        if ($value) {
            $selected = $value
            break
        }
    }
    Remove-Item $ApiKeyPath -Force -ErrorAction SilentlyContinue
    if (-not $selected) { $selected = $DefaultGeminiApiKey }
    $script:GeminiApiKey = $selected.Trim()
}

function Load-RuntimeConfig {
    Load-ActiveProvider
    Load-ModelMappings
    Load-ActiveModel
    Load-ActiveApiKey
}

function Save-ActiveModel {
    param([string]$Name)
    Ensure-Runtime
    $script:GeminiModel = Resolve-GeminiModel $Name
    $script:GeminiModel | Set-Content -Path $ModelPath -Encoding ASCII
    Write-Host "Active upstream model: $script:GeminiModel" -ForegroundColor Green
}

function Get-VisibleModelNames {
    $raw = [Environment]::GetEnvironmentVariable("ZHUDA_VISIBLE_MODELS", "Process")
    if (-not $raw -and $script:Provider -eq "mimo") {
        $raw = [Environment]::GetEnvironmentVariable("ZHUDA_MIMO_VISIBLE_MODELS", "Process")
    }
    if (-not $raw) {
        $raw = [Environment]::GetEnvironmentVariable("ZHUDA_GEMINI_VISIBLE_MODELS", "Process")
    }
    $items = New-Object System.Collections.Generic.List[string]
    if ($raw) {
        foreach ($item in ($raw -split ",")) {
            $name = $item.Trim()
            if ($name -and -not $items.Contains($name)) { $items.Add($name) | Out-Null }
        }
    }
    foreach ($value in @($script:ModelMappings.Values)) {
        $name = ([string]$value).Trim()
        if ($name -and -not $items.Contains($name)) { $items.Add($name) | Out-Null }
    }
    if ($GeminiModel -and -not $items.Contains($GeminiModel)) { $items.Insert(0, $GeminiModel) }
    if ($items.Count -eq 0) {
        if ($script:Provider -eq "mimo") {
            @("mimo-v2.5-pro", "mimo-v2.5") | ForEach-Object { $items.Add($_) | Out-Null }
        } else {
            @("gemini-3.5-flash", "gemini-3-flash-preview", "gemini-3.1-flash-lite", "gemini-3.1-pro", "gemma-4-31b-it") | ForEach-Object { $items.Add($_) | Out-Null }
        }
    }
    return @($items.ToArray())
}

function Save-ActiveApiKey {
    param([string]$Key)
    Ensure-Runtime
    if (-not $Key) { return }
    $script:GeminiApiKey = $Key.Trim()
    [Environment]::SetEnvironmentVariable("ZHUDA_GEMINI_API_KEY", $script:GeminiApiKey, "Process")
    Remove-Item $ApiKeyPath -Force -ErrorAction SilentlyContinue
    Write-Host "Active upstream API key updated for this process only." -ForegroundColor Green
}

function Normalize-RateProfile {
    param([string]$Name)
    if (-not $Name) { return $DefaultRateProfile }
    $key = $Name.Trim().ToLowerInvariant()
    switch ($key) {
        { $_ -in @("tier1", "paid", "t1", "pay") } { return "tier1" }
        { $_ -in @("off", "none", "unlimited", "disabled") } { return "off" }
        default { return "free" }
    }
}

function Save-RateProfile {
    param([string]$Name)
    Ensure-Runtime
    $profile = Normalize-RateProfile $Name
    $profile | Set-Content -Path $RateProfilePath -Encoding ASCII
    Write-Host "Active rate profile: $profile" -ForegroundColor Green
}

function Get-RateProfile {
    if (Test-Path $RateProfilePath) {
        try {
            $saved = Get-Content $RateProfilePath -ErrorAction Stop | Select-Object -First 1
            if ($saved) { return (Normalize-RateProfile $saved) }
        } catch {}
    }
    return $DefaultRateProfile
}

function Get-ApiKeyHint {
    if (-not $GeminiApiKey) { return "" }
    if ($GeminiApiKey.Length -le 8) { return "<set>" }
    return ($GeminiApiKey.Substring(0, [Math]::Min(6, $GeminiApiKey.Length)) + "..." + $GeminiApiKey.Substring($GeminiApiKey.Length - 4))
}

function Get-UpstreamTimeoutSec {
    param([string]$ModelName = "")
    $target = if ($ModelName) { $ModelName } else { $GeminiModel }
    if ($target -match "31b") { return 60 }
    if ($target -match "26b") { return 45 }
    return 35
}

function Get-LocalRpmLimit {
    param([string]$ModelName = "")
    $profile = Get-RateProfile
    if ($profile -eq "off") { return 0 }
    $target = if ($ModelName) { (Resolve-GeminiModel $ModelName).ToLowerInvariant() } else { $GeminiModel.ToLowerInvariant() }

    if ($profile -eq "tier1") {
        if ($target -eq "gemini-3.5-flash") { return 900 }
        if ($target -eq "gemini-3-flash-preview") { return 900 }
        if ($target -eq "gemini-3.1-flash-lite") { return 3600 }
        if ($target -match "gemma-4-(31b|26b)") { return 25 }
        return 120
    }

    if ($target -eq "gemini-3.5-flash") { return 5 }
    if ($target -eq "gemini-3-flash-preview") { return 5 }
    if ($target -eq "gemini-3.1-flash-lite") { return 15 }
    if ($target -match "gemma-4-(31b|26b)") { return 15 }
    return 5
}

function Wait-LocalRateLimit {
    param([string]$UpstreamModel, $StreamContext = $null)
    $limit = Get-LocalRpmLimit $UpstreamModel
    $profile = Get-RateProfile
    if ($limit -le 0) { return }

    $key = $UpstreamModel.ToLowerInvariant()
    if (-not $script:LocalRateHistory.ContainsKey($key)) {
        $script:LocalRateHistory[$key] = @()
    }

    while ($true) {
        $now = Get-Date
        $windowStart = $now.AddSeconds(-60)
        $items = @($script:LocalRateHistory[$key]) | Where-Object { $_ -gt $windowStart }
        if (@($items).Count -lt $limit) {
            $items = @($items) + @($now)
            $script:LocalRateHistory[$key] = @($items)
            return
        }

        $oldest = @($items | Sort-Object)[0]
        $waitMs = [int][Math]::Ceiling(($oldest.AddSeconds(61) - $now).TotalMilliseconds)
        if ($waitMs -lt 1000) { $waitMs = 1000 }
        Write-JsonLine "adapter.pool.jsonl" @{
            created_at = (Unix-Time)
            model = $UpstreamModel
            key_index = 1
            status = 0
            ok = $false
            error = "local_rate_wait"
            waitMs = $waitMs
            recentCount = @($items).Count
            limit = $limit
            rateProfile = $profile
        }
        Wait-WithSseHeartbeat $waitMs $StreamContext $UpstreamModel "local_rate_wait"
    }
}

function Ensure-Runtime {
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
}

function Read-ConfigText {
    if (-not (Test-Path $ConfigPath)) { return "" }
    return [System.IO.File]::ReadAllText($ConfigPath)
}

function Write-ConfigText {
    param([string]$Text)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ConfigPath, $Text, $encoding)
}

function Repair-ConfigText {
    param([string]$Text)
    if ($null -eq $Text) { $Text = "" }
    $Text = $Text.TrimStart(@([char]0xFEFF))
    $Text = $Text -replace '^[\u00EF\u00BB\u00BF]+', ''
    $Text = $Text -replace '^\s*[^\r\n]*ool_output_token_limit\s*=', 'tool_output_token_limit ='
    $Text = $Text -replace '("zhuda-codex-local-token")(?=\[)', "`$1`r`n`r`n"

    $lines = $Text -split "\r?\n", -1
    $out = New-Object System.Collections.Generic.List[string]
    $skipMalformedSection = $false
    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($trim.StartsWith("[projects.")) {
            $skipMalformedSection = $true
            continue
        }
        if ($trim.StartsWith("[") -and -not $trim.EndsWith("]")) {
            $skipMalformedSection = $true
            continue
        }
        if ($skipMalformedSection) {
            if ($trim.StartsWith("[") -and $trim.EndsWith("]")) {
                $skipMalformedSection = $false
            } else {
                continue
            }
        }
        $out.Add($line)
    }
    return (($out.ToArray()) -join "`r`n").Trim() + "`r`n"
}

function Write-JsonLine {
    param([string]$FileName, [object]$Value)
    Ensure-Runtime
    $path = Join-Path $RuntimeDir $FileName
    ($Value | ConvertTo-Json -Depth 80 -Compress) + "`n" | Add-Content -Path $path -Encoding UTF8
}

function Write-ErrorLog {
    param([string]$Text)
    Ensure-Runtime
    $path = Join-Path $RuntimeDir "adapter.err.log"
    "$(Get-Date -Format s) $Text" | Add-Content -Path $path -Encoding UTF8
}

function Escape-JsonString {
    param([string]$Text)
    if ($null -eq $Text) { $Text = "" }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -eq 8) {
            [void]$sb.Append('\b')
        } elseif ($code -eq 9) {
            [void]$sb.Append('\t')
        } elseif ($code -eq 10) {
            [void]$sb.Append('\n')
        } elseif ($code -eq 12) {
            [void]$sb.Append('\f')
        } elseif ($code -eq 13) {
            [void]$sb.Append('\r')
        } elseif ($code -eq 34) {
            [void]$sb.Append('\"')
        } elseif ($code -eq 92) {
            [void]$sb.Append('\\')
        } elseif ($code -lt 32 -or $code -eq 0x2028 -or $code -eq 0x2029 -or ($code -ge 0xD800 -and $code -le 0xDFFF)) {
            [void]$sb.Append(('\u{0:x4}' -f $code))
        } else {
            [void]$sb.Append($ch)
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-JsonStrict {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 120) { return (Escape-JsonString "[Max JSON depth exceeded]") }
    if ($null -eq $Value) { return "null" }
    if ($Value -is [bool]) { if ($Value) { return "true" } else { return "false" } }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [int64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string] -or $Value -is [char]) { return (Escape-JsonString ([string]$Value)) }

    if ($Value -is [System.Collections.IDictionary]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $Value.GetEnumerator()) {
            if ($null -eq $entry.Key) { continue }
            $parts.Add((Escape-JsonString ([string]$entry.Key)) + ":" + (ConvertTo-JsonStrict $entry.Value ($Depth + 1)))
        }
        return "{" + ($parts -join ",") + "}"
    }

    if ($Value -is [pscustomobject]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($prop in $Value.PSObject.Properties) {
            $parts.Add((Escape-JsonString ([string]$prop.Name)) + ":" + (ConvertTo-JsonStrict $prop.Value ($Depth + 1)))
        }
        return "{" + ($parts -join ",") + "}"
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) {
            $parts.Add((ConvertTo-JsonStrict $item ($Depth + 1)))
        }
        return "[" + ($parts -join ",") + "]"
    }

    return (Escape-JsonString ([string]$Value))
}

function Escape-Html {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Redact-LongBase64 {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $Text = $Text -replace '(?i)data:[^,\s]{1,120};base64,[A-Za-z0-9+/=\r\n]{512,}', '[Zhuda adapter omitted long data-url/base64 blob. Use the actual file path or image attachment instead.]'
    $Text = $Text -replace '(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{512,}={0,2}(?![A-Za-z0-9+/=])', '[Zhuda adapter omitted long base64-like blob. Do not decode this from chat history; ask for or use the actual file/image path.]'
    return $Text
}

function Redact-Secret {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $Text = Redact-LongBase64 $Text
    $Text = $Text -replace 'AIza[0-9A-Za-z_-]{20,}', '<redacted-api-key>'
    $Text = $Text -replace 'sk-[0-9A-Za-z_-]{20,}', '<redacted-api-key>'
    $Text = $Text -replace 'AQ\.[0-9A-Za-z_-]{20,}', '<redacted-api-key>'
    return $Text
}

function New-ResponseId { return "resp_$([Guid]::NewGuid().ToString('N'))" }
function New-ItemId { param([string]$Prefix) return "$Prefix`_$([Guid]::NewGuid().ToString('N'))" }
function Unix-Time { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Read-BodyText {
    param($Context)
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, $Context.Request.ContentEncoding)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Status-Text {
    param([int]$StatusCode)
    switch ($StatusCode) {
        200 { "OK" }
        400 { "Bad Request" }
        404 { "Not Found" }
        500 { "Internal Server Error" }
        default { "OK" }
    }
}

function Write-RawHeaders {
    param($Context, [int]$StatusCode, [string]$ContentType, $ContentLength)
    if (-not $Context.PSObject.Properties["Raw"]) { return }
    if ($Context.HeadersSent) { return }
    $headers = "HTTP/1.1 $StatusCode $(Status-Text $StatusCode)`r`nContent-Type: $ContentType`r`nCache-Control: no-cache`r`nConnection: close`r`n"
    if ($null -ne $ContentLength) { $headers += "Content-Length: $ContentLength`r`n" }
    $headers += "`r`n"
    $bytes = [Text.Encoding]::ASCII.GetBytes($headers)
    $Context.ClientStream.Write($bytes, 0, $bytes.Length)
    $Context.HeadersSent = $true
}

function Send-Bytes {
    param($Context, [byte[]]$Bytes, [string]$ContentType = "text/plain; charset=utf-8", [int]$StatusCode = 200)
    if ($Context.PSObject.Properties["Raw"]) {
        Write-RawHeaders $Context $StatusCode $ContentType $Bytes.Length
        $Context.ClientStream.Write($Bytes, 0, $Bytes.Length)
        $Context.ClientStream.Close()
        $Context.Client.Close()
        return
    }
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    try { $Context.Response.OutputStream.Flush() } catch {}
    try { $Context.Response.OutputStream.Close() } catch {}
    if ($Context.PSObject.Properties["Raw"]) {
        try { $Context.ClientStream.Close() } catch {}
        try { $Context.Client.Close() } catch {}
    }
}

function Send-Text {
    param($Context, [string]$Text, [string]$ContentType = "text/plain; charset=utf-8", [int]$StatusCode = 200)
    Send-Bytes $Context ([Text.Encoding]::UTF8.GetBytes($Text)) $ContentType $StatusCode
}

function Send-Json {
    param($Context, [object]$Value, [int]$StatusCode = 200)
    Send-Text $Context ($Value | ConvertTo-Json -Depth 100 -Compress) "application/json; charset=utf-8" $StatusCode
}

function Write-Sse {
    param($Context, [object]$Value)
    if ($Context.PSObject.Properties["Raw"] -and -not $Context.HeadersSent) {
        Write-RawHeaders $Context 200 "text/event-stream; charset=utf-8" $null
    }
    $line = "data: $(ConvertTo-JsonStrict $Value)`n`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($line)
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Flush()
}

function Write-SseComment {
    param($Context, [string]$Text)
    if ($Context.PSObject.Properties["Raw"] -and -not $Context.HeadersSent) {
        Write-RawHeaders $Context 200 "text/event-stream; charset=utf-8" $null
    }
    $safe = ([string]$Text) -replace "[\r\n]", " "
    $line = ": $safe`n`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($line)
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Flush()
}

function Wait-WithSseHeartbeat {
    param([int]$Milliseconds, $StreamContext = $null, [string]$UpstreamModel = "", [string]$Reason = "wait")
    $remaining = [Math]::Max($Milliseconds, 0)
    while ($remaining -gt 0) {
        if ($null -ne $StreamContext) {
            Write-SseComment $StreamContext "zhuda $Reason model=$UpstreamModel remaining_ms=$remaining"
        }
        $chunk = [Math]::Min($remaining, 5000)
        Start-Sleep -Milliseconds $chunk
        $remaining -= $chunk
    }
}

function Text-From-Content {
    param($Content)
    if ($null -eq $Content) { return "" }
    if ($Content -is [string]) { return $Content }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Content)) {
        if ($item -is [string]) {
            $parts.Add($item)
        } elseif ($null -ne $item.PSObject.Properties["text"]) {
            $parts.Add([string]$item.text)
        } elseif ($null -ne $item.PSObject.Properties["input_text"]) {
            $parts.Add([string]$item.input_text)
        } elseif ($null -ne $item.PSObject.Properties["content"]) {
            $parts.Add([string]$item.content)
        }
    }
    return ($parts | Where-Object { $_ }) -join "`n"
}

function Json-String {
    param($Value)
    if ($Value -is [string]) { return $Value }
    return ($Value | ConvertTo-Json -Depth 80 -Compress)
}

function Input-Item-Text {
    param($Item)
    if ($null -eq $Item -or $Item -is [string]) { return [string]$Item }
    $type = if ($Item.PSObject.Properties["type"]) { [string]$Item.type } else { "" }
    if ($type -eq "message") {
        $role = if ($Item.PSObject.Properties["role"]) { [string]$Item.role } else { "user" }
        $label = switch ($role) {
            "user" { "USER_MESSAGE" }
            "assistant" { "ASSISTANT_MESSAGE" }
            "system" { "SYSTEM_MESSAGE" }
            "developer" { "DEVELOPER_MESSAGE" }
            default { $role.ToUpperInvariant() }
        }
        $text = Text-From-Content $Item.content
        if ($text) { return "$label`:`n$text" }
    }
    if ($type -eq "function_call") {
        return "ASSISTANT_TOOL_CALL $($Item.name):`n$($Item.arguments)"
    }
    if ($type -eq "function_call_output") {
        return "TOOL_RESULT $($Item.call_id):`n$(Json-String $Item.output)"
    }
    return Text-From-Content $Item.content
}

function Extract-Prompt {
    param($Payload)
    $chunks = New-Object System.Collections.Generic.List[string]
    if ($Payload.PSObject.Properties["instructions"] -and $Payload.instructions) {
        $chunks.Add("CODEX_INSTRUCTIONS:`n$($Payload.instructions)")
    }
    if ($Payload.PSObject.Properties["input"]) {
        if ($Payload.input -is [string]) {
            $chunks.Add([string]$Payload.input)
        } else {
            foreach ($item in @($Payload.input)) {
                $text = Input-Item-Text $item
                if ($text) { $chunks.Add($text) }
            }
        }
    }
    if ($Payload.PSObject.Properties["messages"]) {
        foreach ($item in @($Payload.messages)) {
            $text = Input-Item-Text $item
            if ($text) { $chunks.Add($text) }
        }
    }
    $prompt = Redact-LongBase64 (($chunks | Where-Object { $_ }) -join "`n`n")
    if (-not $prompt) { $prompt = "Reply OK only." }
    if ($prompt.Length -gt $MaxPromptChars) {
        $prompt = "[Zhuda adapter note: older context was trimmed on Windows to keep the request stable.]`n`n" + $prompt.Substring($prompt.Length - $MaxPromptChars)
    }
    return $prompt
}

function Convert-ToPlain {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($entry in $Value.GetEnumerator()) { $h[[string]$entry.Key] = Convert-ToPlain $entry.Value }
        return $h
    }
    if ($Value -is [System.Array]) {
        $arr = @($Value | ForEach-Object { Convert-ToPlain $_ })
        return ,$arr
    }
    if ($Value -is [pscustomobject]) {
        $h = @{}
        foreach ($prop in $Value.PSObject.Properties) { $h[$prop.Name] = Convert-ToPlain $prop.Value }
        return $h
    }
    return $Value
}

function Get-FieldValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    return $null
}

function Get-ObjectEntries {
    param($Object)
    $items = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Object) { return $items.ToArray() }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($entry in $Object.GetEnumerator()) {
            $items.Add([pscustomobject]@{ Key = [string]$entry.Key; Value = $entry.Value })
        }
        return $items.ToArray()
    }
    foreach ($prop in $Object.PSObject.Properties) {
        $items.Add([pscustomobject]@{ Key = [string]$prop.Name; Value = $prop.Value })
    }
    return $items.ToArray()
}

function Convert-GeminiSchema {
    param($Value)
    if ($null -eq $Value) { return @{ type = "object"; properties = @{} } }

    $schema = @{}
    $propertiesValue = Get-FieldValue $Value "properties"
    $itemsValue = Get-FieldValue $Value "items"
    $typeValue = Get-FieldValue $Value "type"
    if ($typeValue -is [System.Array]) {
        $typeValue = @($typeValue | Where-Object { [string]$_ -ne "null" } | Select-Object -First 1)
    }
    $kind = ([string]$typeValue).ToLowerInvariant()
    if (-not $kind -and $propertiesValue) { $kind = "object" }
    if (-not $kind) { $kind = "object" }
    $schema["type"] = switch ($kind) {
        "object" { "object" }
        "array" { "array" }
        "string" { "string" }
        "number" { "number" }
        "integer" { "integer" }
        "boolean" { "boolean" }
        default { "object" }
    }

    $description = Get-FieldValue $Value "description"
    if ($description) { $schema["description"] = [string]$description }

    $propertyNames = @()
    if ($propertiesValue) {
        $props = @{}
        foreach ($entry in (Get-ObjectEntries $propertiesValue)) {
            if (-not $entry.Key) { continue }
            $props[$entry.Key] = Convert-GeminiSchema $entry.Value
            $propertyNames += $entry.Key
        }
        $schema["properties"] = $props
    }

    if ($itemsValue) {
        $schema["items"] = Convert-GeminiSchema $itemsValue
    }

    $requiredValue = Get-FieldValue $Value "required"
    if ($requiredValue) {
        $required = @($requiredValue | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if ($propertyNames.Count -gt 0) {
            $required = @($required | Where-Object { $propertyNames -contains $_ })
        }
        if ($required.Count -gt 0) { $schema["required"] = [string[]]$required }
    }

    $enumValue = Get-FieldValue $Value "enum"
    if ($enumValue) {
        $enum = @($enumValue | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if ($enum.Count -gt 0) { $schema["enum"] = [string[]]$enum }
    }

    return $schema
}

function Safe-ToolName {
    param([string]$Name)
    $safe = ($Name -replace '[^A-Za-z0-9_]', '_')
    if (-not $safe) { $safe = "tool" }
    if ($safe[0] -match '[0-9]') { $safe = "tool_$safe" }
    if ($safe.Length -gt 63) { $safe = $safe.Substring(0, 63) }
    return $safe
}

function Tool-Parameters {
    param($Tool)
    foreach ($key in @("parameters", "input_schema", "inputSchema", "schema")) {
        if ($Tool.PSObject.Properties[$key] -and $Tool.PSObject.Properties[$key].Value) {
            return $Tool.PSObject.Properties[$key].Value
        }
    }
    return @{ type = "object"; properties = @{} }
}

function Convert-ToObjectList {
    param($Value)
    $list = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Value) { return $list.ToArray() }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $item = $Value[$key]
            if ($null -eq $item) { continue }
            if ($item.PSObject.Properties -and -not $item.PSObject.Properties["name"]) {
                try { $item | Add-Member -NotePropertyName name -NotePropertyValue ([string]$key) -Force -ErrorAction SilentlyContinue } catch {}
            }
            $list.Add($item)
        }
        return $list.ToArray()
    }

    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            if ($null -ne $item) { $list.Add($item) }
        }
        return $list.ToArray()
    }

    $props = $Value.PSObject.Properties
    if ($props["type"] -or $props["name"]) {
        $list.Add($Value)
        return $list.ToArray()
    }

    foreach ($prop in $props) {
        $item = $prop.Value
        if ($null -eq $item) { continue }
        if ($item.PSObject.Properties -and -not $item.PSObject.Properties["name"]) {
            try { $item | Add-Member -NotePropertyName name -NotePropertyValue $prop.Name -Force -ErrorAction SilentlyContinue } catch {}
        }
        $list.Add($item)
    }
    return $list.ToArray()
}

function Build-ToolDeclarations {
    param($Payload)
    try {
        $decls = New-Object System.Collections.Generic.List[object]
        $seen = @{}
        if (-not $Payload.PSObject.Properties["tools"]) { return @() }

        $tools = Convert-ToObjectList $Payload.PSObject.Properties["tools"].Value
        foreach ($tool in $tools) {
            if ($null -eq $tool -or -not $tool.PSObject.Properties["type"]) { continue }
            $toolType = [string]$tool.PSObject.Properties["type"].Value
            if ($toolType -eq "function") {
                $name = Safe-ToolName ([string]$tool.PSObject.Properties["name"].Value)
                if ($seen.ContainsKey($name)) { continue }
                $seen[$name] = $true
                $desc = if ($tool.PSObject.Properties["description"]) { [string]$tool.PSObject.Properties["description"].Value } else { $name }
                $decls.Add(@{ name = $name; description = $desc; parameters = Convert-GeminiSchema (Tool-Parameters $tool) })
            } elseif ($toolType -eq "namespace" -and $tool.PSObject.Properties["tools"]) {
                $namespace = [string]$tool.PSObject.Properties["name"].Value
                $nestedItems = Convert-ToObjectList $tool.PSObject.Properties["tools"].Value
                foreach ($nested in $nestedItems) {
                    if ($null -eq $nested -or -not $nested.PSObject.Properties["name"]) { continue }
                    $nestedName = [string]$nested.PSObject.Properties["name"].Value
                    $flat = Safe-ToolName "$namespace`__$nestedName"
                    if ($seen.ContainsKey($flat)) { continue }
                    $seen[$flat] = $true
                    $desc = if ($nested.PSObject.Properties["description"]) { [string]$nested.PSObject.Properties["description"].Value } else { $nestedName }
                    $decls.Add(@{
                        name = $flat
                        description = "$desc`n`nCodex namespace tool: $namespace.$nestedName. Call this declared function as $flat."
                        parameters = Convert-GeminiSchema (Tool-Parameters $nested)
                    })
                }
            }
        }
        return $decls.ToArray()
    } catch {
        Write-ErrorLog "Build-ToolDeclarations failed safely: $($_.Exception.Message)"
        return @()
    }
}

function System-Instruction {
    return @"
Answer the user directly in the user's language, usually Traditional Chinese.
Never reveal hidden reasoning, scratch notes, analysis bullets, draft notes, or step-by-step private deliberation. Output only the final user-facing answer or the needed tool call.
Use Gemini function calling for declared tools.
For text replies, wrap only the final user-facing answer in <final>...</final>. Do not include anything outside the final tag.
Never pass tool names like mcp__node_repl__js or mcp__computer_use__get_app_state to the shell.
exec_command is only for real shell commands.
If a tool result is unsupported or failed, choose another valid route or summarize the current state.
Long base64-like blobs in chat history are usually transport or screenshot artifacts. Do not try to decode them unless the user explicitly asks and provides an actual file path or attachment.
If the history contains an omitted base64 marker, ignore that artifact and answer the user's latest message directly.
"@
}

function Clean-ModelText {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $value = $Text.Trim()
    $match = [regex]::Match($value, "(?is)<final>\s*(.*?)\s*</final>")
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    $value = [regex]::Replace($value, "(?is)^\s*The user (wants|asked|is asking|said).*?\.(?=\s*\S)", "").Trim()
    $value = [regex]::Replace($value, "(?is)^\s*I (must|should|need to|will) .*?\.(?=\s*\S)", "").Trim()
    $value = [regex]::Replace($value, "(?is)^\s*\*\s+Input:.*?No tool use needed here\.", "").Trim()
    $value = [regex]::Replace($value, "(?im)^\s*(Language|Constraint|Plan|Reasoning|Analysis|Self-correction)\s*:\s*.*(?:\r?\n)?", "").Trim()
    $value = [regex]::Replace($value, "(?is)^\s*(Looking back at the conversation history|Current status|Wait,|Actually,).*?(?=\r?\n\r?\n|\z)", "").Trim()
    return $value
}

function Utf8-Text {
    param([string]$Base64)
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
}

function Codex-AliasForUpstream {
    param([string]$UpstreamModel)
    $model = ([string]$UpstreamModel).ToLowerInvariant()
    if ($model -eq "gemini-3.5-flash") { return "GPT-5.4 / zhuda-flash-3-5" }
    if ($model -eq "gemini-3.1-flash-lite") { return "GPT-5.4-Mini / zhuda-flash-lite" }
    if ($model -eq "gemini-3-flash-preview") { return "GPT-5.2 / zhuda-flash-3" }
    if ($model -eq "gemma-4-31b-it") { return "GPT-5.5 / zhuda-gemma-31b" }
    if ($model -eq "gemma-4-26b-a4b-it") { return "GPT-5.3-Codex / zhuda-gemma-26b" }
    return $UpstreamModel
}

function Alternative-ModelHint {
    param([string]$UpstreamModel)
    $model = ([string]$UpstreamModel).ToLowerInvariant()
    if ($model -eq "gemini-3.5-flash") { return "GPT-5.4-Mini (gemini-3.1-flash-lite) / GPT-5.5 (gemma-4-31b-it) / GPT-5.3-Codex (gemma-4-26b-a4b-it)" }
    if ($model -eq "gemini-3.1-flash-lite") { return "GPT-5.5 (gemma-4-31b-it) / GPT-5.3-Codex (gemma-4-26b-a4b-it) / GPT-5.4 (gemini-3.5-flash)" }
    if ($model -eq "gemini-3-flash-preview") { return "GPT-5.4-Mini (gemini-3.1-flash-lite) / GPT-5.5 (gemma-4-31b-it) / GPT-5.4 (gemini-3.5-flash)" }
    if ($model -eq "gemma-4-31b-it") { return "GPT-5.4-Mini (gemini-3.1-flash-lite) / GPT-5.4 (gemini-3.5-flash) / GPT-5.3-Codex (gemma-4-26b-a4b-it)" }
    if ($model -eq "gemma-4-26b-a4b-it") { return "GPT-5.5 (gemma-4-31b-it) / GPT-5.4-Mini (gemini-3.1-flash-lite) / GPT-5.4 (gemini-3.5-flash)" }
    return (Utf8-Text "Q29kZXgg5bem5LiL6KeS5qih5Z6L6YG45Zau5Lit55qE5YW25LuWIFpodWRhIOaooeWeiw==")
}

function Gemini-FailureText {
    param([int]$Status, [string]$Message, [string]$ResponseBody, [string]$UpstreamModel)
    $raw = "$Message`n$ResponseBody"
    $alias = Codex-AliasForUpstream $UpstreamModel
    $alternatives = Alternative-ModelHint $UpstreamModel
    $isQuota = ($Status -eq 429) -or ($raw -match "RESOURCE_EXHAUSTED|Quota exceeded|quota")
    $isDaily = $isQuota -and ($raw -match "GenerateRequestsPerDay|RequestsPerDay|PerDay|per day|daily|RPD|requests per day")
    $isMinute = $isQuota -and ($raw -match "GenerateRequestsPerMinute|RequestsPerMinute|PerMinute|retryDelay|Please retry|RPM|requests per minute")

    if ($isDaily) {
        return (Utf8-Text "5LuK5aSp6YCZ5YCL5qih5Z6L55qEIEdlbWluaSBBUEkg5pel6aGN5bqm55So5a6M5ZWm772e6KuL55SoIENvZGV4IOW3puS4i+inkuaooeWei+mBuOWWruWIh+WIsOWFtuS7luaooeWei+WTpu+8jOimqu+8gQoKLSDnm67liY3mqKHlnos6IHthbGlhc30gKHttb2RlbH0pCi0g5bu66K2w5pS555SoOiB7YWx0ZXJuYXRpdmVzfQotIOaYjuWkqemFjemhjemHjee9ruW+jO+8jOWPr+S7peWGjeWIh+WbnumAmeWAi+aooeWei+OAgg==").Replace("{alias}", $alias).Replace("{model}", $UpstreamModel).Replace("{alternatives}", $alternatives)
    }
    if ($isMinute) {
        return (Utf8-Text "6YCZ5YCL5qih5Z6L55qE5Zau5YiG6ZCY6aGN5bqm5pqr5pmC5omT5ru/5ZWm772eWmh1ZGEgYWRhcHRlciDmnIPnm6Hph4/nr4DmtYHnrYnlvoXvvJvlpoLmnpzkvaDotpXmmYLplpPvvIzoq4vlhYjliIfliLDlhbbku5bmqKHlnovlk6bvvIzopqrvvIEKCi0g55uu5YmN5qih5Z6LOiB7YWxpYXN9ICh7bW9kZWx9KQotIOW7uuitsOaUueeUqDoge2FsdGVybmF0aXZlc30KLSDkuIrmuLjni4DmhYs6IHtzdGF0dXN9").Replace("{alias}", $alias).Replace("{model}", $UpstreamModel).Replace("{alternatives}", $alternatives).Replace("{status}", [string]$Status)
    }
    return "Zhuda local Gemini could not complete this turn.`n`n- Model: $UpstreamModel`n- Status: $Status`n- Reason: $Message"
}

function Get-RetryDelayMs {
    param([string]$Text)
    $raw = [string]$Text
    $match = [regex]::Match($raw, '"retryDelay"\s*:\s*"([0-9]+(?:\.[0-9]+)?)s"', "IgnoreCase")
    if (-not $match.Success) {
        $match = [regex]::Match($raw, 'Please retry in\s+([0-9]+(?:\.[0-9]+)?)s', "IgnoreCase")
    }
    if ($match.Success) {
        $seconds = 0.0
        if ([double]::TryParse($match.Groups[1].Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)) {
            return [int][Math]::Ceiling(($seconds + 1.0) * 1000)
        }
    }
    return 15000
}

function Invoke-Gemini {
    param([string]$Prompt, [object[]]$Declarations, [string]$RequestedModel = "", $StreamContext = $null, [int]$RetryAttempt = 0)
    Load-RuntimeConfig
    $UpstreamModel = Resolve-RequestedGeminiModel $RequestedModel
    if (-not $GeminiApiKey) {
        $text = "Zhuda-Codex did not receive a Gemini API key. Reopen Zhuda-Codex Launcher, choose Gemini and a model, then paste the one-session API key. The launcher does not save API keys locally."
        return @{ type = "text"; text = $text; upstream = $null; upstreamModel = $UpstreamModel; durationMs = 0; error = "missing_api_key" }
    }
    $Declarations = @($Declarations)
    $parts = @(@{ text = $Prompt })
    $body = @{
        systemInstruction = @{ parts = @(@{ text = (System-Instruction) }) }
        contents = @(@{ role = "user"; parts = $parts })
        generationConfig = @{ temperature = 0.2; maxOutputTokens = 2048 }
    }
    if (@($Declarations).Count -gt 0) {
        $body.tools = @(@{ functionDeclarations = $Declarations })
        $body.toolConfig = @{ functionCallingConfig = @{ mode = "AUTO" } }
    }
    $url = "https://generativelanguage.googleapis.com/v1beta/models/$($UpstreamModel):generateContent?key=$GeminiApiKey"
    $started = Get-Date
    $timeout = Get-UpstreamTimeoutSec $UpstreamModel
    Write-JsonLine "adapter.pool.jsonl" @{ created_at = (Unix-Time); model = $UpstreamModel; key_index = 1; status = 0; ok = $false; error = "started" }
    try {
        $json = ConvertTo-JsonStrict $body
        try { $null = $json | ConvertFrom-Json } catch { Write-ErrorLog "Generated invalid upstream JSON: $($_.Exception.Message)" }
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $resp = Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec $timeout
        Write-JsonLine "adapter.pool.jsonl" @{ created_at = (Unix-Time); model = $UpstreamModel; key_index = 1; status = 200; ok = $true; error = "" }
        $candidate = @($resp.candidates)[0]
        $partsOut = @($candidate.content.parts)
        foreach ($part in $partsOut) {
            if ($part.PSObject.Properties["functionCall"]) {
                $call = $part.functionCall
                return @{ type = "function_call"; name = [string]$call.name; arguments = (Convert-ToPlain $call.args); upstream = $resp; upstreamModel = $UpstreamModel; durationMs = [int]((Get-Date) - $started).TotalMilliseconds }
            }
        }
        $texts = New-Object System.Collections.Generic.List[string]
        foreach ($part in $partsOut) {
            if ($part.PSObject.Properties["text"]) { $texts.Add([string]$part.text) }
        }
        return @{ type = "text"; text = (Clean-ModelText (($texts -join "").Trim())); upstream = $resp; upstreamModel = $UpstreamModel; durationMs = [int]((Get-Date) - $started).TotalMilliseconds }
    } catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        $message = $_.Exception.Message
        $responseBody = ""
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                try { $responseBody = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        } catch {}
        if ($responseBody) { $message = "$message :: $responseBody" }
        Write-JsonLine "adapter.pool.jsonl" @{ created_at = (Unix-Time); model = $UpstreamModel; key_index = 1; status = $status; ok = $false; error = $message }
        $raw = "$message`n$responseBody"
        $isQuota = ($status -eq 429) -or ($raw -match "RESOURCE_EXHAUSTED|Quota exceeded|quota")
        $isDaily = $isQuota -and ($raw -match "GenerateRequestsPerDay|RequestsPerDay|PerDay|per day|daily|RPD|requests per day")
        $isMinute = $isQuota -and ($raw -match "GenerateRequestsPerMinute|RequestsPerMinute|PerMinute|retryDelay|Please retry|RPM|requests per minute")
        if ($isMinute -and -not $isDaily -and $RetryAttempt -lt 3) {
            $waitMs = Get-RetryDelayMs $raw
            if ($waitMs -lt 1000) { $waitMs = 1000 }
            if ($waitMs -gt 75000) { $waitMs = 75000 }
            Write-JsonLine "adapter.pool.jsonl" @{ created_at = (Unix-Time); model = $UpstreamModel; key_index = 1; status = 0; ok = $false; error = "upstream_retry_wait"; waitMs = $waitMs; retryAttempt = ($RetryAttempt + 1) }
            Wait-WithSseHeartbeat $waitMs $StreamContext $UpstreamModel "upstream_retry_wait"
            return (Invoke-Gemini $Prompt $Declarations $RequestedModel $StreamContext ($RetryAttempt + 1))
        }
        $friendly = Gemini-FailureText $status $message $responseBody $UpstreamModel
        return @{ type = "text"; text = $friendly; upstream = $null; upstreamModel = $UpstreamModel; durationMs = [int]((Get-Date) - $started).TotalMilliseconds; error = $message }
    }
}

function Get-MimoBaseUrl {
    $value = [Environment]::GetEnvironmentVariable("MIMO_BASE_URL", "Process")
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable("XIAOMI_MIMO_BASE_URL", "Process") }
    if (-not $value) { $value = "https://token-plan-sgp.xiaomimimo.com/v1" }
    return $value.TrimEnd("/")
}

function Mimo-FailureText {
    param([int]$Status, [string]$Message, [string]$ResponseBody, [string]$UpstreamModel)
    $raw = "$Message`n$ResponseBody"
    if (($Status -eq 429) -or ($raw -match "quota|rate|limit|RESOURCE_EXHAUSTED")) {
        return "Zhuda local MiMo could not complete this turn.`n`n- Model: $UpstreamModel`n- Status: $Status`n- Reason: quota/rate limit or upstream throttling`n`nRetry later, or use Zhuda-Codex Launcher to map this Codex model to another upstream model."
    }
    return "Zhuda local MiMo could not complete this turn.`n`n- Model: $UpstreamModel`n- Status: $Status`n- Reason: $Message"
}

function Invoke-Mimo {
    param([string]$Prompt, [object[]]$Declarations, [string]$RequestedModel = "", $StreamContext = $null, [int]$RetryAttempt = 0)
    Load-RuntimeConfig
    $UpstreamModel = Resolve-RequestedGeminiModel $RequestedModel
    if (-not $GeminiApiKey) {
        $text = "Zhuda-Codex did not receive a MiMo API key. Reopen Zhuda-Codex Launcher, choose Xiaomi MiMo, then paste the one-session API key. The launcher does not save API keys locally."
        return @{ type = "text"; text = $text; upstream = $null; upstreamModel = $UpstreamModel; durationMs = 0; error = "missing_api_key" }
    }
    $systemText = (System-Instruction) + "`n`n[Zhuda provider note] This turn is routed through Xiaomi MiMo in text-answer mode. If tools are needed, explain the next useful step instead of pretending a tool was executed."
    $body = @{
        model = $UpstreamModel
        messages = @(
            @{ role = "system"; content = $systemText },
            @{ role = "user"; content = $Prompt }
        )
        stream = $false
        temperature = 0.2
        max_tokens = 2048
    }
    $url = "$(Get-MimoBaseUrl)/chat/completions"
    $started = Get-Date
    $timeout = Get-UpstreamTimeoutSec $UpstreamModel
    Write-JsonLine "adapter.pool.jsonl" @{ created_at = (Unix-Time); model = $UpstreamModel; key_index = 1; status = 0; ok = $false; error = "started"; provider = "mimo" }
    try {
        $json = ConvertTo-JsonStrict $body
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $headers = @{ Authorization = "Bearer $GeminiApiKey"; "api-key" = $GeminiApiKey }
        $resp = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec $timeout
        Write-JsonLine "adapter.pool.jsonl" @{ created_at = (Unix-Time); model = $UpstreamModel; key_index = 1; status = 200; ok = $true; error = ""; provider = "mimo" }
        $choice = @($resp.choices)[0]
        $text = ""
        if ($choice -and $choice.PSObject.Properties["message"]) {
            $text = Text-From-Content $choice.message.content
        }
        if (-not $text) { $text = "MiMo returned no text content." }
        return @{ type = "text"; text = (Clean-ModelText $text.Trim()); upstream = $resp; upstreamModel = $UpstreamModel; durationMs = [int]((Get-Date) - $started).TotalMilliseconds }
    } catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        $message = $_.Exception.Message
        $responseBody = ""
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                try { $responseBody = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        } catch {}
        if ($responseBody) { $message = "$message :: $responseBody" }
        Write-JsonLine "adapter.pool.jsonl" @{ created_at = (Unix-Time); model = $UpstreamModel; key_index = 1; status = $status; ok = $false; error = $message; provider = "mimo" }
        $friendly = Mimo-FailureText $status $message $responseBody $UpstreamModel
        return @{ type = "text"; text = $friendly; upstream = $null; upstreamModel = $UpstreamModel; durationMs = [int]((Get-Date) - $started).TotalMilliseconds; error = $message }
    }
}

function Invoke-Upstream {
    param([string]$Prompt, [object[]]$Declarations, [string]$RequestedModel = "", $StreamContext = $null)
    Load-RuntimeConfig
    if ($script:Provider -eq "mimo") {
        return (Invoke-Mimo $Prompt $Declarations $RequestedModel $StreamContext)
    }
    return (Invoke-Gemini $Prompt $Declarations $RequestedModel $StreamContext)
}

function Response-Object {
    param([string]$ResponseId, [string]$Model, [string]$Text)
    $itemId = New-ItemId "msg"
    return @{
        id = $ResponseId; object = "response"; created_at = (Unix-Time); status = "completed"; error = $null
        incomplete_details = $null; instructions = $null; model = $Model
        output = @(@{ id = $itemId; type = "message"; status = "completed"; role = "assistant"; content = @(@{ type = "output_text"; text = $Text; annotations = @() }) })
        parallel_tool_calls = $false; tool_choice = "auto"; tools = @(); usage = $null
    }
}

function Function-Response-Object {
    param([string]$ResponseId, [string]$Model, [string]$CallId, [string]$ItemId, [string]$Name, [string]$Arguments)
    return @{
        id = $ResponseId; object = "response"; created_at = (Unix-Time); status = "completed"; error = $null
        incomplete_details = $null; instructions = $null; model = $Model
        output = @(@{ id = $ItemId; type = "function_call"; call_id = $CallId; name = $Name; arguments = $Arguments; status = "completed" })
        parallel_tool_calls = $false; tool_choice = "auto"; tools = @(); usage = $null
    }
}

function Write-Episode {
    param($Payload, [string]$ResponseId, [string]$Model, [string]$Prompt, $Result, $Declarations)
    $declList = @($Declarations)
    $declNames = @($declList | ForEach-Object {
        if ($null -ne $_ -and $_ -is [System.Collections.IDictionary] -and $_.Contains("name")) {
            [string]$_["name"]
        } elseif ($null -ne $_ -and $_.PSObject.Properties["name"]) {
            [string]$_.PSObject.Properties["name"].Value
        }
    })
    $inputText = ""
    if ($Payload -and $Payload.PSObject.Properties["input"]) {
        $inputText = Json-String $Payload.input
    }
    $resultType = if ($Result["type"]) { [string]$Result["type"] } else { "text" }
    $resultText = if ($Result["text"]) { [string]$Result["text"] } else { "" }
    $textPreview = $resultText.Substring(0, [Math]::Min(300, $resultText.Length))
    $upstreamInfo = @{}
    if ($Result["upstream"]) {
        $upstreamInfo = @{
            modelVersion = $Result["upstream"].modelVersion
            responseId = $Result["upstream"].responseId
        }
    }
    Write-JsonLine "adapter.episodes.jsonl" @{
        created_at = (Unix-Time)
        responseId = $ResponseId
        status = "completed"
        codexModel = $Model
        upstreamModel = if ($Result["upstreamModel"]) { $Result["upstreamModel"] } else { $GeminiModel }
        promptChars = $Prompt.Length
        promptCharsSent = $Prompt.Length
        promptCharsRaw = $inputText.Length
        declaredTools = @{ count = $declList.Length; names = $declNames }
        result = if ($resultType -eq "function_call") { @{ type = "function_call"; name = $Result["name"] } } else { @{ type = "text"; textPreview = $textPreview } }
        upstream = $upstreamInfo
        durationMs = $Result["durationMs"]
        error = if ($Result["error"]) { $Result["error"] } else { $null }
    }
}

function Handle-Responses {
    param($Context)
    $body = Read-BodyText $Context
    Write-JsonLine "adapter.requests.jsonl" @{ created_at = (Unix-Time); rawChars = $body.Length }
    try {
        $payload = $body | ConvertFrom-Json
    } catch {
        Send-Json $Context @{ error = "invalid_json"; message = $_.Exception.Message } 400
        return
    }
    $model = if ($payload.PSObject.Properties["model"] -and $payload.model) { [string]$payload.model } else { "gemini-codex" }
    $stream = $true
    if ($payload.PSObject.Properties["stream"]) { $stream = [bool]$payload.stream }
    $prompt = Extract-Prompt $payload
    $declarations = @([object[]](Build-ToolDeclarations $payload))
    $responseId = New-ResponseId
    Load-RuntimeConfig
    $upstreamModel = Resolve-RequestedGeminiModel $model

    if (-not $stream) {
        Wait-LocalRateLimit $upstreamModel
        $result = Invoke-Upstream $prompt $declarations $model
        Write-Episode $payload $responseId $model $prompt $result $declarations
        if ($result.type -eq "function_call") {
            $callId = New-ItemId "call"
            $itemId = New-ItemId "fc"
            Send-Json $Context (Function-Response-Object $responseId $model $callId $itemId $result.name (($result.arguments | ConvertTo-Json -Depth 80 -Compress)))
        } else {
            Send-Json $Context (Response-Object $responseId $model ([string]$result.text))
        }
        return
    }

    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = "text/event-stream; charset=utf-8"
    $Context.Response.SendChunked = $true
    Write-Sse $Context @{ type = "response.created"; response = @{ id = $responseId; object = "response"; created_at = (Unix-Time); status = "in_progress"; model = $model; output = @() } }
    Wait-LocalRateLimit $upstreamModel $Context
    $result = Invoke-Upstream $prompt $declarations $model $Context
    Write-Episode $payload $responseId $model $prompt $result $declarations
    if ($result.type -eq "function_call") {
        $callId = New-ItemId "call"
        $itemId = New-ItemId "fc"
        $args = $result.arguments | ConvertTo-Json -Depth 80 -Compress
        Write-Sse $Context @{ type = "response.output_item.added"; response_id = $responseId; output_index = 0; item = @{ id = $itemId; type = "function_call"; call_id = $callId; name = $result.name; arguments = ""; status = "in_progress" } }
        Write-Sse $Context @{ type = "response.function_call_arguments.delta"; response_id = $responseId; item_id = $itemId; output_index = 0; delta = $args }
        Write-Sse $Context @{ type = "response.function_call_arguments.done"; response_id = $responseId; item_id = $itemId; output_index = 0; arguments = $args }
        $completedItem = @{ id = $itemId; type = "function_call"; call_id = $callId; name = $result.name; arguments = $args; status = "completed" }
        Write-Sse $Context @{ type = "response.output_item.done"; response_id = $responseId; output_index = 0; item = $completedItem }
        Write-Sse $Context @{ type = "response.completed"; response = (Function-Response-Object $responseId $model $callId $itemId $result.name $args) }
    } else {
        $itemId = New-ItemId "msg"
        $text = [string]$result.text
        Write-Sse $Context @{ type = "response.output_item.added"; response_id = $responseId; output_index = 0; item = @{ id = $itemId; type = "message"; status = "in_progress"; role = "assistant"; content = @() } }
        Write-Sse $Context @{ type = "response.content_part.added"; response_id = $responseId; item_id = $itemId; output_index = 0; content_index = 0; part = @{ type = "output_text"; text = ""; annotations = @() } }
        Write-Sse $Context @{ type = "response.output_text.delta"; response_id = $responseId; item_id = $itemId; output_index = 0; content_index = 0; delta = $text }
        Write-Sse $Context @{ type = "response.output_text.done"; response_id = $responseId; item_id = $itemId; output_index = 0; content_index = 0; text = $text }
        $part = @{ type = "output_text"; text = $text; annotations = @() }
        Write-Sse $Context @{ type = "response.content_part.done"; response_id = $responseId; item_id = $itemId; output_index = 0; content_index = 0; part = $part }
        Write-Sse $Context @{ type = "response.output_item.done"; response_id = $responseId; output_index = 0; item = @{ id = $itemId; type = "message"; status = "completed"; role = "assistant"; content = @($part) } }
        Write-Sse $Context @{ type = "response.completed"; response = (Response-Object $responseId $model $text) }
    }
    $Context.Response.OutputStream.Close()
}

function Get-LogTail {
    param([string]$FileName, [int]$Lines = 200)
    $allowed = @($LogFiles | ForEach-Object { $_.File })
    if ($allowed -notcontains $FileName) { $FileName = "adapter.episodes.jsonl" }
    $path = Join-Path $RuntimeDir $FileName
    if (-not (Test-Path $path)) { return @() }
    return @(Get-Content -Path $path -Tail ([Math]::Min([Math]::Max($Lines, 1), 1000)) | ForEach-Object { Redact-Secret $_ })
}

function Logs-Page {
    $options = ($LogFiles | ForEach-Object { "<option value=""$($_.File)"">$($_.Label)</option>" }) -join "`n"
    return @"
<!doctype html>
<html><head><meta charset="utf-8"><title>Zhuda Local Codex Logs</title>
<style>
body{margin:0;background:#101214;color:#eee;font-family:Segoe UI,Arial,sans-serif}header,.bar{padding:12px 16px;background:#171a1d;border-bottom:1px solid #333}select,input,button{height:34px;background:#222831;color:#eee;border:1px solid #444;border-radius:5px;padding:0 8px}.grid{display:grid;grid-template-columns:1fr 260px;height:calc(100vh - 98px)}pre{margin:0;padding:14px;overflow:auto;font:12px Consolas,monospace;white-space:pre-wrap}.side{border-left:1px solid #333;padding:12px;color:#aaa}.ok{color:#37c084}.warn{color:#f3bd4f}
</style></head><body>
<header><b>Zhuda Local Codex Logs</b> <span id="state" class="warn">loading</span></header>
<div class="bar"><select id="file">$options</select> <input id="q" placeholder="search"> <button onclick="load()">Refresh</button> <label><input id="auto" type="checkbox" checked> auto</label></div>
<div class="grid"><pre id="log"></pre><div class="side"><div>Port: 4000</div><div>Key count: <span id="keys">1</span></div><div>Model: <code>$GeminiModel</code></div><div>Updated: <span id="updated">-</span></div><hr><div>Endpoints:</div><div>/v1/responses</div><div>/logs</div><div>/pool/status</div></div></div>
<script>
let lines=[];
function esc(s){return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));}
function render(){let q=document.getElementById('q').value.toLowerCase();document.getElementById('log').innerHTML=lines.filter(x=>!q||x.toLowerCase().includes(q)).map(esc).join('\n');if(document.getElementById('auto').checked)document.getElementById('log').scrollTop=99999999;}
async function load(){let f=document.getElementById('file').value;let r=await fetch('/logs/api/tail?file='+encodeURIComponent(f)+'&lines=300');let d=await r.json();lines=d.lines||[];document.getElementById('state').textContent='live';document.getElementById('state').className='ok';document.getElementById('updated').textContent=new Date().toLocaleTimeString();render();}
document.getElementById('file').onchange=load;document.getElementById('q').oninput=render;setInterval(load,1000);load();
</script></body></html>
"@
}

function Handle-Request {
    param($Context)
    try {
        Load-RuntimeConfig
        $path = $Context.Request.Url.AbsolutePath
        if ($Context.Request.HttpMethod -eq "GET" -and $path -eq "/health/readiness") {
            Send-Json $Context @{ status = "healthy"; adapter = "zhuda-local-powershell"; provider = $Provider; keys = 1; model = $GeminiModel; apiKeySet = [bool]$GeminiApiKey; apiKeyHint = (Get-ApiKeyHint) }
        } elseif ($Context.Request.HttpMethod -eq "GET" -and $path -eq "/pool/status") {
            $modelMap = @{}
            foreach ($spec in (Get-ZhudaModelCatalogSpecs)) {
                $modelMap[$spec.Slug] = Resolve-RequestedGeminiModel $spec.Slug
            }
            foreach ($slug in @("gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.2", "codex-auto-review")) {
                $modelMap[$slug] = Resolve-RequestedGeminiModel $slug
            }
            Send-Json $Context @{ provider = $Provider; keyCount = 1; defaultUpstreamModel = $GeminiModel; forceUpstreamModel = $null; models = $modelMap; apiKeySet = [bool]$GeminiApiKey; apiKeyHint = (Get-ApiKeyHint); nextKeyIndex = 1; runtime = @{ maxKeyAttempts = 1; upstreamTimeoutSeconds = (Get-UpstreamTimeoutSec); maxPromptChars = $MaxPromptChars; activeCooldowns = @(); rateProfile = (Get-RateProfile); localRpmLimits = @{ "gemini-3.5-flash" = (Get-LocalRpmLimit "gemini-3.5-flash"); "gemini-3.1-flash-lite" = (Get-LocalRpmLimit "gemini-3.1-flash-lite"); "gemini-3-flash-preview" = (Get-LocalRpmLimit "gemini-3-flash-preview"); "gemma-4-31b-it" = (Get-LocalRpmLimit "gemma-4-31b-it"); "gemma-4-26b-a4b-it" = (Get-LocalRpmLimit "gemma-4-26b-a4b-it"); "mimo-v2.5-pro" = (Get-LocalRpmLimit "mimo-v2.5-pro"); "mimo-v2.5" = (Get-LocalRpmLimit "mimo-v2.5") } } }
        } elseif ($Context.Request.HttpMethod -eq "GET" -and $path -eq "/v1/models") {
            $items = @((Get-ZhudaModelCatalogSpecs) | ForEach-Object { @{ id = $_.Slug; object = "model"; owned_by = "zhuda-local-powershell" } })
            $items += @("gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.2", "codex-auto-review") | ForEach-Object { @{ id = $_; object = "model"; owned_by = "zhuda-local-powershell" } }
            Send-Json $Context @{ object = "list"; data = $items }
        } elseif ($Context.Request.HttpMethod -eq "POST" -and $path -eq "/v1/responses") {
            Handle-Responses $Context
        } elseif ($Context.Request.HttpMethod -eq "GET" -and $path -eq "/logs") {
            Send-Text $Context (Logs-Page) "text/html; charset=utf-8"
        } elseif ($Context.Request.HttpMethod -eq "GET" -and $path -eq "/logs/api/tail") {
            $file = $Context.Request.QueryString["file"]
            $lines = 200
            [void][int]::TryParse($Context.Request.QueryString["lines"], [ref]$lines)
            Send-Json $Context @{ file = $file; lines = @(Get-LogTail $file $lines); adapter = @{ keyCount = 1; model = $GeminiModel } }
        } else {
            Send-Json $Context @{ error = "not_found"; path = $path } 404
        }
    } catch {
        Write-ErrorLog $_.Exception.ToString()
        try { Send-Json $Context @{ error = "server_error"; message = $_.Exception.Message } 500 } catch {}
    }
}

function Decode-UrlComponent {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return [Uri]::UnescapeDataString(($Text -replace '\+', ' '))
}

function Parse-QueryString {
    param([string]$Query)
    $values = @{}
    if (-not $Query) { return $values }
    foreach ($pair in ($Query.TrimStart("?") -split "&")) {
        if (-not $pair) { continue }
        $parts = $pair -split "=", 2
        $name = Decode-UrlComponent $parts[0]
        $value = if (@($parts).Count -gt 1) { Decode-UrlComponent $parts[1] } else { "" }
        $values[$name] = $value
    }
    return $values
}

function Index-Of-Bytes {
    param([byte[]]$Bytes, [byte[]]$Needle)
    if ($Bytes.Length -lt $Needle.Length) { return -1 }
    for ($i = 0; $i -le $Bytes.Length - $Needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Bytes[$i + $j] -ne $Needle[$j]) { $match = $false; break }
        }
        if ($match) { return $i }
    }
    return -1
}

function New-RawContext {
    param($Client)
    $stream = $Client.GetStream()
    $buffer = New-Object byte[] 8192
    $ms = New-Object System.IO.MemoryStream
    $separator = [Text.Encoding]::ASCII.GetBytes("`r`n`r`n")
    $headerEnd = -1

    while ($headerEnd -lt 0) {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { throw "client closed before HTTP headers" }
        $ms.Write($buffer, 0, $read)
        $all = $ms.ToArray()
        $headerEnd = Index-Of-Bytes $all $separator
        if ($all.Length -gt 1048576 -and $headerEnd -lt 0) { throw "HTTP headers too large" }
    }

    $allBytes = $ms.ToArray()
    $bodyStart = $headerEnd + $separator.Length
    $headerText = [Text.Encoding]::ASCII.GetString($allBytes, 0, $headerEnd)
    $headerLines = $headerText -split "`r`n"
    $requestParts = $headerLines[0] -split " ", 3
    if (@($requestParts).Count -lt 2) { throw "invalid HTTP request line" }
    $method = $requestParts[0]
    $target = $requestParts[1]
    $headers = @{}
    for ($i = 1; $i -lt @($headerLines).Count; $i++) {
        $line = $headerLines[$i]
        $colon = $line.IndexOf(":")
        if ($colon -gt 0) {
            $headers[$line.Substring(0, $colon).Trim().ToLowerInvariant()] = $line.Substring($colon + 1).Trim()
        }
    }

    $contentLength = 0
    if ($headers.ContainsKey("content-length")) { [void][int]::TryParse($headers["content-length"], [ref]$contentLength) }
    while (($allBytes.Length - $bodyStart) -lt $contentLength) {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        $ms.Write($buffer, 0, $read)
        $allBytes = $ms.ToArray()
    }

    $bodyBytes = New-Object byte[] $contentLength
    if ($contentLength -gt 0) {
        [Array]::Copy($allBytes, $bodyStart, $bodyBytes, 0, [Math]::Min($contentLength, $allBytes.Length - $bodyStart))
    }

    $question = $target.IndexOf("?")
    $path = if ($question -ge 0) { $target.Substring(0, $question) } else { $target }
    $query = if ($question -ge 0) { $target.Substring($question + 1) } else { "" }
    $bodyStream = New-Object System.IO.MemoryStream -ArgumentList (,$bodyBytes)
    $uri = [Uri]("$BaseUrl$target")

    return [pscustomobject]@{
        Raw = $true
        Client = $Client
        ClientStream = $stream
        HeadersSent = $false
        Request = [pscustomobject]@{
            HttpMethod = $method
            Url = $uri
            Path = $path
            QueryString = (Parse-QueryString $query)
            InputStream = $bodyStream
            ContentEncoding = [Text.Encoding]::UTF8
            Headers = $headers
        }
        Response = [pscustomobject]@{
            StatusCode = 200
            ContentType = "text/plain; charset=utf-8"
            SendChunked = $false
            OutputStream = $stream
        }
    }
}

function Start-ServerMode {
    Ensure-Runtime
    $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList @(([System.Net.IPAddress]::Parse("127.0.0.1")), $Port)
    $listener.Start()
    $PID | Set-Content -Path $PidPath -Encoding ASCII
    Write-Host "Zhuda local Codex server listening at $BaseUrl"
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $ctx = New-RawContext $client
            Handle-Request $ctx
        } catch {
            Write-ErrorLog $_.Exception.ToString()
            try { $client.Close() } catch {}
        }
    }
}

function Test-Server {
    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/health/readiness" -TimeoutSec 2
        return ($r.status -eq "healthy")
    } catch {
        return $false
    }
}

function Test-PortOpen {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(500, $false)
        if ($ok) { $client.EndConnect($iar) }
        $client.Close()
        return $ok
    } catch {
        return $false
    }
}

function Start-LocalServer {
    Ensure-Runtime
    if (Test-Server) {
        Write-Host "Local server already running: $BaseUrl" -ForegroundColor Green
        return
    }
    if (Test-PortOpen) {
        Write-Host "Local server port is already open: $BaseUrl" -ForegroundColor Green
        return
    }
    $ps = (Get-Process -Id $PID).Path
    if (-not $ps) { $ps = "powershell.exe" }
    $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ScriptPath`"", "-Server", "-Model", "`"$GeminiModel`"")
    Start-Process -FilePath $ps -ArgumentList $args -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 300
        if (Test-Server) {
            Write-Host "Local server started: $BaseUrl" -ForegroundColor Green
            return
        }
    }
    Write-Host "Local server did not become ready. Check $RuntimeDir\adapter.err.log" -ForegroundColor Yellow
}

function Stop-StaleAdapterProcesses {
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -and
                $_.CommandLine -match "windows_zhuda_(local_adapter|codex_switch)\.ps1"
            } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                Write-Host "Stopped stale Zhuda adapter pid $($_.ProcessId)." -ForegroundColor DarkGray
            }
    } catch {}
}

function Stop-LocalServer {
    $owners = New-Object System.Collections.Generic.HashSet[int]
    if (Test-Path $PidPath) {
        $id = Get-Content $PidPath -ErrorAction SilentlyContinue
        if ($id) { [void]$owners.Add([int]$id) }
        Remove-Item $PidPath -Force -ErrorAction SilentlyContinue
    }
    try {
        Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique |
            ForEach-Object {
                if ($_ -and $_ -ne $PID) { [void]$owners.Add([int]$_) }
            }
    } catch {}
    foreach ($id in $owners) {
        if ($id -ne $PID) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    }
    Stop-StaleAdapterProcesses
    Write-Host "Local server stopped if it was running."
}

function Set-TopLevelString {
    param([string]$Text, [string]$Key, [string]$Value)
    if ($Text -match "(?m)^$([regex]::Escape($Key))\s*=") {
        return [regex]::Replace($Text, "(?m)^$([regex]::Escape($Key))\s*=.*$", "$Key = `"$Value`"", 1)
    }
    return "$Key = `"$Value`"`r`n$Text"
}

function Set-TopLevelLiteralString {
    param([string]$Text, [string]$Key, [string]$Value)
    $literal = $Value -replace "'", "''"
    if ($Text -match "(?m)^$([regex]::Escape($Key))\s*=") {
        return [regex]::Replace($Text, "(?m)^$([regex]::Escape($Key))\s*=.*$", "$Key = '$literal'", 1)
    }
    return "$Key = '$literal'`r`n$Text"
}

function Set-TopLevelNumber {
    param([string]$Text, [string]$Key, [int]$Value)
    if ($Text -match "(?m)^$([regex]::Escape($Key))\s*=") {
        return [regex]::Replace($Text, "(?m)^$([regex]::Escape($Key))\s*=.*$", "$Key = $Value", 1)
    }
    return "$Key = $Value`r`n$Text"
}

function Upsert-ProviderSection {
    param([string]$Text)
    $section = (
        "[model_providers.zhuda_gemini_pool]",
        'name = "Zhuda Local Gemini"',
        'base_url = "http://127.0.0.1:4000/v1"',
        'wire_api = "responses"',
        'experimental_bearer_token = "zhuda-codex-local-token"',
        ""
    ) -join "`r`n"
    $pattern = "(?ms)^\[model_providers\.zhuda_gemini_pool\]\r?\n.*?(?=^\[|\z)"
    if ([regex]::IsMatch($Text, $pattern)) {
        return [regex]::Replace($Text, $pattern, $section, 1)
    }
    return $Text.TrimEnd() + "`r`n`r`n" + $section
}

function Upsert-WindowsSandbox {
    param([string]$Text, [string]$Mode)
    $sectionPattern = "(?ms)^\[windows\]\r?\n.*?(?=^\[|\z)"
    $sandboxLine = "sandbox = `"$Mode`""
    $match = [regex]::Match($Text, $sectionPattern)
    if ($match.Success) {
        $section = [string]$match.Value
        if ($section -match "(?m)^sandbox\s*=") {
            $section = [regex]::Replace($section, "(?m)^sandbox\s*=.*$", $sandboxLine, 1)
        } else {
            $section = $section.TrimEnd() + "`r`n$sandboxLine`r`n"
        }
        return $Text.Substring(0, $match.Index) + $section + $Text.Substring($match.Index + $match.Length)
    }
    return $Text.TrimEnd() + "`r`n`r`n[windows]`r`n$sandboxLine`r`n"
}

function Remove-TopLevelKey {
    param([string]$Text, [string]$Key)
    return [regex]::Replace($Text, "(?m)^$([regex]::Escape($Key))\s*=.*\r?\n?", "")
}

function Get-ZhudaModelCatalogSpecs {
    Load-ActiveProvider
    Load-ModelMappings
    Load-ActiveModel
    $names = @(Get-VisibleModelNames)
    $specs = New-Object System.Collections.Generic.List[object]
    $priority = 9
    foreach ($name in $names) {
        $display = $name
        $description = "Zhuda-Codex $Provider upstream model."
        $specs.Add(@{ Slug = $name; Display = $display; Description = $description; Priority = $priority }) | Out-Null
        $priority += 7
    }
    return @($specs.ToArray())
}

function New-MinimalCatalogTemplate {
    return [ordered]@{
        slug = "template"
        display_name = "Template"
        description = "Template"
        default_reasoning_level = "medium"
        supported_reasoning_levels = @(
            @{ effort = "low"; description = "Fast responses with lighter reasoning" },
            @{ effort = "medium"; description = "Balanced reasoning for everyday coding" },
            @{ effort = "high"; description = "More deliberate reasoning for complex work" },
            @{ effort = "xhigh"; description = "Maximum reasoning effort" }
        )
        shell_type = "shell_command"
        visibility = "list"
        supported_in_api = $true
        priority = 99
        additional_speed_tiers = @()
        service_tiers = @()
        availability_nux = $null
        upgrade = $null
        base_instructions = "You are Codex, a coding agent. Work in the user's workspace, use tools carefully, and answer in the user's language."
        supports_reasoning_summaries = $false
        default_reasoning_summary = "auto"
        support_verbosity = $false
        default_verbosity = $null
        apply_patch_tool_type = $null
        web_search_tool_type = "text"
        truncation_policy = @{ mode = "tokens"; limit = 10000 }
        supports_parallel_tool_calls = $false
        supports_image_detail_original = $false
        effective_context_window_percent = 95
        experimental_supported_tools = @()
        input_modalities = @("text", "image")
        supports_search_tool = $false
    }
}

function Get-CatalogTemplate {
    $cachePath = if (Test-Path $ModelCacheBackupPath) { $ModelCacheBackupPath } else { $ModelCachePath }
    if (Test-Path $cachePath) {
        try {
            $cache = Get-Content -Path $cachePath -Raw -ErrorAction Stop | ConvertFrom-Json
            $models = @($cache.models)
            $template = @($models | Where-Object { $_.slug -eq "gpt-5.5" } | Select-Object -First 1)
            if (-not $template -and $models.Count -gt 0) { $template = $models[0] }
            if ($template) { return $template }
        } catch {
            Write-ErrorLog "Could not read models_cache.json for catalog template: $($_.Exception.Message)"
        }
    }
    return (New-MinimalCatalogTemplate)
}

function New-ZhudaCatalogModel {
    param($Template, [hashtable]$Spec)
    $model = [ordered]@{}
    foreach ($prop in $Template.PSObject.Properties) {
        $model[$prop.Name] = $prop.Value
    }
    $model["slug"] = $Spec.Slug
    $model["display_name"] = $Spec.Display
    $model["description"] = $Spec.Description
    $model["priority"] = [int]$Spec.Priority
    $model["availability_nux"] = $null
    $model["upgrade"] = $null
    $model["additional_speed_tiers"] = @()
    $model["service_tiers"] = @()
    $model["supported_in_api"] = $true
    $model["visibility"] = "list"
    if (-not $model.Contains("experimental_supported_tools")) { $model["experimental_supported_tools"] = @() }
    return $model
}

function Write-ZhudaModelCatalog {
    Ensure-Runtime
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    if ((Test-Path $ModelCachePath) -and -not (Test-Path $ModelCacheBackupPath)) {
        Copy-Item $ModelCachePath $ModelCacheBackupPath -Force
    }
    $template = Get-CatalogTemplate
    $cacheMeta = $null
    if (Test-Path $ModelCachePath) {
        try { $cacheMeta = Get-Content -Path $ModelCachePath -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
    }
    $models = New-Object System.Collections.Generic.List[object]
    foreach ($spec in (Get-ZhudaModelCatalogSpecs)) {
        $models.Add((New-ZhudaCatalogModel $template $spec)) | Out-Null
    }
    $catalog = [ordered]@{
        fetched_at = if ($cacheMeta -and $cacheMeta.PSObject.Properties["fetched_at"]) { [string]$cacheMeta.fetched_at } else { [DateTime]::UtcNow.ToString("o") }
        etag = if ($cacheMeta -and $cacheMeta.PSObject.Properties["etag"]) { [string]$cacheMeta.etag } else { "zhuda-local" }
        client_version = if ($cacheMeta -and $cacheMeta.PSObject.Properties["client_version"]) { [string]$cacheMeta.client_version } else { "zhuda-local" }
        models = $models.ToArray()
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $json = $catalog | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($ModelCatalogPath, $json, $enc)
    [System.IO.File]::WriteAllText($ModelCachePath, $json, $enc)
    Write-Host "Wrote Zhuda model catalog: $ModelCatalogPath" -ForegroundColor Green
    Write-Host "Injected Zhuda model cache: $ModelCachePath" -ForegroundColor Green
}

function Restore-CodexModelCacheForDesktop {
    if (Test-Path $ModelCacheBackupPath) {
        Copy-Item $ModelCacheBackupPath $ModelCachePath -Force
        Write-Host "Restored Codex desktop model cache: $ModelCachePath" -ForegroundColor Green
    }
}

function Set-LocalCodexConfigText {
    param([string]$Text)
    $text = Repair-ConfigText $Text
    $text = Set-TopLevelString $text "model" $GeminiModel
    $text = Set-TopLevelString $text "model_provider" "zhuda_gemini_pool"
    $text = Remove-TopLevelKey $text "model_catalog_json"
    $text = Set-TopLevelNumber $text "model_context_window" 49152
    $text = Set-TopLevelNumber $text "model_auto_compact_token_limit" 32000
    $text = Set-TopLevelNumber $text "tool_output_token_limit" 4000
    $text = Upsert-ProviderSection $text
    $text = Upsert-WindowsSandbox $text "unelevated"
    return $text
}

function Enable-LocalModeMarker {
    Ensure-Runtime
    [System.IO.File]::WriteAllText($LocalModeMarkerPath, ([DateTime]::UtcNow.ToString("o")), [System.Text.Encoding]::ASCII)
}

function Disable-LocalModeMarker {
    Remove-Item $LocalModeMarkerPath -Force -ErrorAction SilentlyContinue
}

function Switch-ToLocalCodex {
    Ensure-Runtime
    if ($Model) {
        Save-ActiveModel $Model
        Stop-LocalServer
    } else {
        Save-ActiveModel $GeminiModel
    }
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    if (-not (Test-Path $ConfigPath)) { Write-ConfigText "" }
    if (-not (Test-Path $BackupPath)) { Copy-Item $ConfigPath $BackupPath -Force }
    Start-LocalServer
    Write-ZhudaModelCatalog
    Enable-LocalModeMarker
    Write-ConfigText (Set-LocalCodexConfigText (Read-ConfigText))
    Restart-Codex
    Write-Host "Switched Codex to local Gemini adapter." -ForegroundColor Green
}

function Switch-ActiveModelOnly {
    Ensure-Runtime
    if (-not $Model) {
        Write-Host "Current upstream model: $GeminiModel" -ForegroundColor Cyan
        Write-Host "Pass -Model gemma-31b, gemma-26b, flash-lite, flash-3.5, or flash-3." -ForegroundColor DarkGray
        return
    }
    Save-ActiveModel $Model
    Stop-LocalServer
    Start-LocalServer
    Write-ZhudaModelCatalog
    Enable-LocalModeMarker
    Write-ConfigText (Set-LocalCodexConfigText (Read-ConfigText))
    Restart-Codex
    Write-Host "Switched active upstream model to $GeminiModel." -ForegroundColor Green
}

function Switch-ToWindowsFallbackSandbox {
    Ensure-Runtime
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    if (-not (Test-Path $ConfigPath)) { Write-ConfigText "" }
    $text = Repair-ConfigText (Read-ConfigText)
    $text = Upsert-WindowsSandbox $text "unelevated"
    Write-ConfigText $text
    Restart-Codex
    Write-Host "Set Windows sandbox to unelevated fallback." -ForegroundColor Green
}

function Switch-ToOfficialCodex {
    Disable-LocalModeMarker
    if (Test-Path $ModelCacheBackupPath) {
        Copy-Item $ModelCacheBackupPath $ModelCachePath -Force
        Write-Host "Restored Codex models_cache backup." -ForegroundColor Green
    }
    if (Test-Path $BackupPath) {
        $text = [System.IO.File]::ReadAllText($BackupPath)
        Write-ConfigText (Repair-ConfigText $text)
        Write-Host "Restored Codex config backup." -ForegroundColor Green
    } else {
        $text = Repair-ConfigText (Read-ConfigText)
        $text = Remove-TopLevelKey $text "model"
        $text = Remove-TopLevelKey $text "model_provider"
        $text = Remove-TopLevelKey $text "model_catalog_json"
        Write-ConfigText $text
        Write-Host "No backup found; removed custom top-level model/model_provider." -ForegroundColor Yellow
    }
    Stop-LocalServer
    Restart-Codex
}

function Repair-CodexConfig {
    Ensure-Runtime
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    if (-not (Test-Path $ConfigPath)) { Write-ConfigText "" }
    $text = Repair-ConfigText (Read-ConfigText)
    Write-ConfigText $text
    Restart-Codex
    Write-Host "Repaired config.toml and wrote it as UTF-8 without BOM." -ForegroundColor Green
}

function Get-CodexExeCandidate {
    $runningDesktop = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -eq "Codex" -and $_.Path -and $_.Path -match "\\app\\Codex\.exe$" } |
        Select-Object -First 1
    if ($runningDesktop -and $runningDesktop.Path) { return $runningDesktop.Path }
    try {
        $pkg = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation) {
            $path = Join-Path $pkg.InstallLocation "app\Codex.exe"
            if (Test-Path $path) { return $path }
        }
    } catch {}
    foreach ($path in @(
        "$env:LOCALAPPDATA\Programs\Codex\Codex.exe",
        "$env:LOCALAPPDATA\OpenAI\Codex\Codex.exe",
        "$env:ProgramFiles\Codex\Codex.exe",
        "$env:ProgramFiles\OpenAI\Codex\Codex.exe"
    )) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Restart-Codex {
    $exe = Get-CodexExeCandidate
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^Codex$|^codex$' } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if ($exe -and (Test-Path $exe)) {
        Start-Process $exe | Out-Null
        Write-Host "Codex restarted." -ForegroundColor Green
    } else {
        Write-Host "Codex config changed. Please reopen Codex Desktop manually." -ForegroundColor Yellow
    }
}

function Test-LocalResponses {
    Start-LocalServer
    $body = @{ model = "gemini-codex"; stream = $false; input = "Reply exactly: hi" } | ConvertTo-Json -Compress
    $headers = @{ Authorization = "Bearer $LocalBearer" }
    $resp = Invoke-RestMethod -Method Post -Uri "$BaseUrl/v1/responses" -Headers $headers -ContentType "application/json" -Body $body -TimeoutSec 30
    $message = @($resp.output)[0]
    $content = @($message.content)[0]
    $text = $content.text
    Write-Host "Local test response: $text" -ForegroundColor Green
}

function Show-Menu {
    Ensure-Runtime
    while ($true) {
        Write-Host ""
        Write-Host "Zhuda Codex Win11 Switcher" -ForegroundColor Cyan
        Write-Host "Current upstream model: $GeminiModel"
        Write-Host "Current rate profile: $(Get-RateProfile)"
        Write-Host "1. Switch to Local Codex (one Gemini API key)"
        Write-Host "2. Switch to Official Codex"
        Write-Host "3. Start local adapter server"
        Write-Host "4. Stop local adapter server"
        Write-Host "5. Open log dashboard"
        Write-Host "6. Test local adapter"
        Write-Host "7. Fix Windows sandbox error (use unelevated fallback)"
        Write-Host "8. Repair config.toml only"
        Write-Host "9. Switch upstream model"
        Write-Host "10. Switch rate profile (free/tier1/off)"
        Write-Host "0. Exit"
        $choice = Read-Host "Choose"
        switch ($choice) {
            "1" { Switch-ToLocalCodex }
            "2" { Switch-ToOfficialCodex }
            "3" { Start-LocalServer }
            "4" { Stop-LocalServer }
            "5" { Start-LocalServer; Start-Process "$BaseUrl/logs" }
            "6" { Test-LocalResponses }
            "7" { Switch-ToWindowsFallbackSandbox }
            "8" { Repair-CodexConfig }
            "9" {
                $picked = Read-Host "Model alias (gemma-31b/gemma-26b/flash-lite/flash-3.5/flash-3)"
                if ($picked) {
                    $script:Model = $picked
                    Switch-ActiveModelOnly
                    $script:Model = ""
                }
            }
            "10" {
                $picked = Read-Host "Rate profile (free/tier1/off)"
                if ($picked) { Save-RateProfile $picked }
            }
            "0" { return }
            default { Write-Host "Unknown option." -ForegroundColor Yellow }
        }
    }
}

Load-RuntimeConfig
if ($RateProfile) { Save-RateProfile $RateProfile }

if ($Server -or $ServeOnly) {
    Start-ServerMode
} elseif ($Local) {
    Switch-ToLocalCodex
} elseif ($Official) {
    Switch-ToOfficialCodex
} elseif ($SetModel) {
    Switch-ActiveModelOnly
} elseif ($SetRateProfile) {
    Save-RateProfile $RateProfile
} elseif ($RepairConfig) {
    Repair-CodexConfig
} elseif ($SandboxFallback) {
    Switch-ToWindowsFallbackSandbox
} else {
    Show-Menu
}
