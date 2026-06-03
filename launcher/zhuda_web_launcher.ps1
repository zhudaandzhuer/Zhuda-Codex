#requires -version 5.1
param(
    [string]$ProjectRoot = "",
    [string]$LaunchScript = "",
    [int]$Port = 4111
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $ProjectRoot) {
    $ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
if (-not $LaunchScript) {
    $LaunchScript = Join-Path $ProjectRoot "win\Zhuda-Codex-Launcher.ps1"
}

$WebRoot = Join-Path $ProjectRoot "launcher\web"
$AssetsRoot = Join-Path $ProjectRoot "assets"
$ProvidersPath = Join-Path $ProjectRoot "providers.json"
$script:ShouldStopLauncher = $false

function ConvertTo-JsonBytes {
    param($Value)
    $text = $Value | ConvertTo-Json -Depth 20 -Compress
    return [Text.Encoding]::UTF8.GetBytes($text)
}

function Send-Bytes {
    param($Context, [int]$StatusCode, [string]$ContentType, [byte[]]$Bytes)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-Json {
    param($Context, [int]$StatusCode, $Value)
    Send-Bytes $Context $StatusCode "application/json; charset=utf-8" (ConvertTo-JsonBytes $Value)
}

function Get-RequestJson {
    param($Context)
    $reader = New-Object IO.StreamReader($Context.Request.InputStream, [Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    if (-not $body) { return @{} }
    return $body | ConvertFrom-Json
}

function Get-ContentType {
    param([string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".html" { "text/html; charset=utf-8"; break }
        ".css" { "text/css; charset=utf-8"; break }
        ".js" { "application/javascript; charset=utf-8"; break }
        ".png" { "image/png"; break }
        ".ico" { "image/x-icon"; break }
        ".jpg" { "image/jpeg"; break }
        ".jpeg" { "image/jpeg"; break }
        ".svg" { "image/svg+xml"; break }
        default { "application/octet-stream" }
    }
}

function Resolve-SafeFile {
    param([string]$Root, [string]$Relative)
    $relative = [Uri]::UnescapeDataString($Relative).Replace("\", "/").TrimStart("/")
    $candidate = [IO.Path]::GetFullPath((Join-Path $Root $relative))
    $rootFull = [IO.Path]::GetFullPath($Root)
    if (-not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return $candidate
}

function Send-File {
    param($Context, [string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) {
        Send-Json $Context 404 @{ error = "not found" }
        return
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    Send-Bytes $Context 200 (Get-ContentType $Path) $bytes
}

function Get-FreePort {
    param([int]$Start)
    for ($p = $Start; $p -lt ($Start + 40); $p++) {
        $listener = $null
        try {
            $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse("127.0.0.1"), $p)
            $listener.Start()
            $listener.Stop()
            return $p
        } catch {
            if ($listener) { $listener.Stop() }
        }
    }
    throw "No free localhost port from $Start"
}

function Get-Provider {
    param($Manifest, [string]$Id)
    @($Manifest.providers | Where-Object { $_.id -eq $Id } | Select-Object -First 1)[0]
}

function Get-ProviderEndpoint {
    param($Provider, [string]$EndpointId)
    if (-not $Provider.PSObject.Properties["endpoint_options"]) { return $null }
    $options = @($Provider.endpoint_options)
    if ($options.Count -le 0) { return $null }
    $selected = $EndpointId
    if (-not $selected -and $Provider.PSObject.Properties["default_endpoint"]) {
        $selected = [string]$Provider.default_endpoint
    }
    if (-not $selected) { $selected = [string]$options[0].id }
    $found = @($options | Where-Object { $_.id -eq $selected } | Select-Object -First 1)
    if ($found.Count -gt 0) { return $found[0] }
    return $options[0]
}

function Get-ProviderBaseUrl {
    param($Provider, [string]$EndpointId)
    $endpoint = Get-ProviderEndpoint $Provider $EndpointId
    if ($endpoint -and $endpoint.PSObject.Properties["base_url"] -and $endpoint.base_url) {
        return [string]$endpoint.base_url
    }
    if ($Provider.PSObject.Properties["base_url"] -and $Provider.base_url) {
        return [string]$Provider.base_url
    }
    return ""
}

function Get-Model {
    param($Provider, [string]$Id)
    $models = @($Provider.models)
    $found = @($models | Where-Object { $_.id -eq $Id -or $_.codex_slug -eq $Id -or $_.upstream -eq $Id } | Select-Object -First 1)
    if ($found.Count -gt 0) { return $found[0] }
    $default = @($models | Where-Object { $_.default } | Select-Object -First 1)
    if ($default.Count -gt 0) { return $default[0] }
    return @($models | Select-Object -First 1)[0]
}

function Get-UpstreamModels {
    param($Provider)
    if ($Provider.PSObject.Properties["upstream_models"]) { return @($Provider.upstream_models) }
    return @($Provider.models)
}

function Resolve-Mapping {
    param($Manifest, $Provider, $Mappings)
    $out = [ordered]@{}
    $models = Get-UpstreamModels $Provider
    $first = if ($models.Count -gt 0) { [string]$models[0].upstream } else { "" }
    foreach ($codex in @($Manifest.codex_models)) {
        $codexId = [string]$codex.id
        $selected = ""
        if ($Mappings -and $Mappings.PSObject.Properties[$codexId]) { $selected = [string]$Mappings.$codexId }
        if (-not $selected -and $Provider.PSObject.Properties["default_mappings"] -and $Provider.default_mappings.PSObject.Properties[$codexId]) {
            $selected = [string]$Provider.default_mappings.$codexId
        }
        $upstream = $first
        foreach ($model in $models) {
            if ($model.id -eq $selected -or $model.upstream -eq $selected) {
                $upstream = [string]$model.upstream
                break
            }
        }
        if ($codexId -and $upstream) { $out[$codexId] = $upstream }
    }
    return $out
}

function Quote-Arg {
    param([string]$Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Start-HeadlessLaunch {
    param($Provider, $Mappings, [string]$ApiKey, [string]$EndpointId, [string]$BaseUrl)
    if (-not (Test-Path $LaunchScript)) {
        throw "Missing launch script: $LaunchScript"
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $LaunchScript,
        "-Headless",
        "-Provider", [string]$Provider.id,
        "-Model", "zhuda-codex"
    )
    $psi.Arguments = ($args | ForEach-Object { Quote-Arg $_ }) -join " "
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables["ZHUDA_WEB_LAUNCH_API_KEY"] = $ApiKey
    $psi.EnvironmentVariables["ZHUDA_WEB_LAUNCH_MAPPINGS"] = ($Mappings | ConvertTo-Json -Depth 20 -Compress)
    if ($EndpointId) { $psi.EnvironmentVariables["ZHUDA_WEB_LAUNCH_ENDPOINT_ID"] = $EndpointId }
    if ($BaseUrl) { $psi.EnvironmentVariables["ZHUDA_WEB_LAUNCH_BASE_URL"] = $BaseUrl }
    [Diagnostics.Process]::Start($psi) | Out-Null
}

function Handle-Request {
    param($Context)
    $path = $Context.Request.Url.AbsolutePath
    if ($Context.Request.HttpMethod -eq "GET") {
        if ($path -eq "/" -or $path -eq "/launcher") {
            Send-File $Context (Join-Path $WebRoot "index.html")
            return
        }
        if ($path -eq "/api/manifest") {
            $manifest = Get-Content $ProvidersPath -Raw | ConvertFrom-Json
            $manifest | Add-Member -Force -NotePropertyName launcher -NotePropertyValue @{ platform = "win"; session_only_keys = $true }
            Send-Json $Context 200 $manifest
            return
        }
        if ($path -eq "/api/status") {
            Send-Json $Context 200 @{
                platform = "win"
                projectRoot = $ProjectRoot
                adapter = @{ ok = $false; port = 4000 }
                lastLaunch = ""
            }
            return
        }
        if ($path.StartsWith("/web/")) {
            Send-File $Context (Resolve-SafeFile $WebRoot $path.Substring(5))
            return
        }
        if ($path.StartsWith("/assets/")) {
            Send-File $Context (Resolve-SafeFile $AssetsRoot $path.Substring(8))
            return
        }
        Send-Json $Context 404 @{ error = "not found" }
        return
    }

    if ($Context.Request.HttpMethod -eq "POST") {
        if ($path -eq "/api/launch") {
            $payload = Get-RequestJson $Context
            $manifest = Get-Content $ProvidersPath -Raw | ConvertFrom-Json
            $provider = Get-Provider $manifest ([string]$payload.provider_id)
            if (-not $provider) { throw "Provider not found." }
            if (-not $provider.enabled) { throw "$($provider.name) is reserved for later." }
            $apiKey = ([string]$payload.api_key).Trim()
            if (-not $apiKey) { throw "API key is empty." }
            $endpointId = ""
            if ($payload.PSObject.Properties["endpoint_id"]) { $endpointId = [string]$payload.endpoint_id }
            $baseUrl = Get-ProviderBaseUrl $provider $endpointId
            $resolvedMappings = Resolve-Mapping $manifest $provider $payload.mappings
            if ($resolvedMappings.Count -le 0) { throw "No model mappings were selected." }
            Start-HeadlessLaunch $provider $resolvedMappings $apiKey $endpointId $baseUrl
            Send-Json $Context 200 @{
                ok = $true
                message = "已啟動 $($provider.name)，$($resolvedMappings.Count) 個 Codex 模型映射已注入。"
                endpoint = $endpointId
                launcherWillExit = $true
                shutdownDelaySeconds = 1.2
            }
            $script:ShouldStopLauncher = $true
            return
        }
        if ($path -eq "/api/stop") {
            Send-Json $Context 200 @{ ok = $true; message = "Windows adapter stop is handled by Codex switch scripts." }
            return
        }
    }

    Send-Json $Context 404 @{ error = "not found" }
}

$Port = Get-FreePort $Port
$prefix = "http://127.0.0.1:$Port/"
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()
Start-Process $prefix | Out-Null
Write-Host "Zhuda-Codex Web Launcher: $prefix" -ForegroundColor Cyan
try {
    while ($listener.IsListening -and -not $script:ShouldStopLauncher) {
        $context = $listener.GetContext()
        try {
            Handle-Request $context
        } catch {
            Send-Json $context 400 @{ error = $_.Exception.Message }
        }
    }
    if ($script:ShouldStopLauncher) {
        Start-Sleep -Milliseconds 1200
    }
} finally {
    $listener.Stop()
}
