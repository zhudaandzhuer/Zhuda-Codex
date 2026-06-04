#requires -version 5.1
param(
    [string]$ReceiverUrl = "__ZHUDA_RECEIVER_URL__",
    [string]$Model = "gemma-31b",
    [string]$OutputRoot = "",
    [switch]$IncludeUserSkills,
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
$Injector = Join-Path $ToolsDir "zhuda_model_injector.ps1"
$ProfileRoot = Join-Path $Root "profile"
$CodexHome = Join-Path $ProfileRoot ".codex"
$CodexSkills = Join-Path $CodexHome "skills"
$AppData = Join-Path $ProfileRoot "AppData\Roaming"
$LocalAppData = Join-Path $ProfileRoot "AppData\Local"
$ElectronData = Join-Path $ProfileRoot "ElectronUserData"
$AdapterLogDir = Join-Path $ProfileRoot "logs"
$ModelInjectorLogPath = Join-Path $AdapterLogDir "model-injector.log"
$ModelInjectorErrPath = Join-Path $AdapterLogDir "model-injector.err.log"
$BundledSkills = Join-Path $Root "skills"
$RealUserProfile = $env:USERPROFILE
$RealUserSkills = Join-Path $RealUserProfile ".codex\skills"

function Ensure-Dir { param([string]$Path) New-Item -ItemType Directory -Force -Path $Path | Out-Null }

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $enc)
}

function Ensure-PortableKnownFolders {
    $known = @(
        @{ name = "Desktop"; target = [Environment]::GetFolderPath("Desktop") },
        @{ name = "Documents"; target = [Environment]::GetFolderPath("MyDocuments") },
        @{ name = "Downloads"; target = (Join-Path $env:USERPROFILE "Downloads") },
        @{ name = "Pictures"; target = [Environment]::GetFolderPath("MyPictures") },
        @{ name = "Music"; target = [Environment]::GetFolderPath("MyMusic") },
        @{ name = "Videos"; target = [Environment]::GetFolderPath("MyVideos") }
    )
    foreach ($item in $known) {
        $link = Join-Path $ProfileRoot $item.name
        if (Test-Path $link) { continue }
        $target = [string]$item.target
        if ($target -and (Test-Path $target)) {
            try {
                New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
                continue
            } catch {}
        }
        Ensure-Dir $link
    }
}

function Sync-TreeRobust {
    param([string]$Source, [string]$Dest)
    if (-not (Test-Path $Source)) { return }
    Ensure-Dir $Dest
    $null = robocopy $Source $Dest /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed while syncing $Source to $Dest with exit code $LASTEXITCODE"
    }
}

function Test-SkillsRoot {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $found = Get-ChildItem -Path $Path -Filter "SKILL.md" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    return ($null -ne $found)
}

function Sync-PortableSkills {
    $source = ""
    $importSetting = [string]$env:ZHUDA_CODEX_IMPORT_USER_SKILLS
    if ($importSetting -eq "1" -and (Test-SkillsRoot $RealUserSkills)) {
        $source = $RealUserSkills
    } elseif (Test-SkillsRoot $BundledSkills) {
        $source = $BundledSkills
    } elseif ($importSetting -ne "0" -and (Test-SkillsRoot $RealUserSkills)) {
        $source = $RealUserSkills
    } elseif (Test-Path $BundledSkills) {
        $source = $BundledSkills
    }
    if ($source) {
        Sync-TreeRobust $source $CodexSkills
    }
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

function Test-TcpPortOpen {
    param([int]$TcpPort)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect("127.0.0.1", $TcpPort, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(250, $false)
        if ($ok) { $client.EndConnect($iar) }
        $client.Close()
        return $ok
    } catch {
        return $false
    }
}

function Get-FreeCdpPort {
    $port = 9233
    while (Test-TcpPortOpen $port) {
        $port += 1
        if ($port -gt 9313) { return 9233 }
    }
    return $port
}

function Join-CommandLine {
    param([string[]]$Items)
    $quoted = @()
    foreach ($item in $Items) {
        if ($null -eq $item) { $item = "" }
        $quoted += '"' + ([string]$item).Replace('"', '\"') + '"'
    }
    return ($quoted -join " ")
}

function Start-DetachedProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$WindowStyle = 0
    )
    $commandLine = Join-CommandLine (@($FilePath) + @($ArgumentList))
    try {
        $shell = New-Object -ComObject WScript.Shell
        [void]$shell.Run($commandLine, $WindowStyle, $false)
    } catch {
        Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WindowStyle Hidden | Out-Null
    }
}

function Start-ModelInjector {
    param([int]$CdpPort, [string]$SelectedModel)
    if (-not (Test-Path $Injector)) { return }
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -and
                $_.CommandLine -match "zhuda_model_injector\.ps1"
            } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 200
    } catch {}
    $models = [string]$env:ZHUDA_VISIBLE_MODELS
    if (-not $models) { $models = $SelectedModel }
    Remove-Item $ModelInjectorLogPath, $ModelInjectorErrPath -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Injector,
        "-Port", "$CdpPort",
        "-Models", $models,
        "-DefaultModel", $SelectedModel,
        "-ProviderName", "Zhuda-Codex",
        "-DurationSeconds", "0",
        "-IntervalMilliseconds", "250",
        "-IdleExitSeconds", "300",
        "-Preload",
        "-ReloadOnce"
    ) -WindowStyle Hidden -RedirectStandardOutput $ModelInjectorLogPath -RedirectStandardError $ModelInjectorErrPath | Out-Null
}

function Get-UniqueCsvItems {
    param([string]$Text)
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($item in ($Text -split ",")) {
        $value = $item.Trim()
        if ($value -and -not $seen.ContainsKey($value)) {
            $seen[$value] = $true
            $out.Add($value) | Out-Null
        }
    }
    return @($out.ToArray())
}

function New-ZhudaModelDescriptor {
    param([string]$Name, [int]$Priority, [string]$ProviderName)
    return [ordered]@{
        slug = $Name
        display_name = $Name
        description = "$ProviderName upstream model"
        default_reasoning_level = "medium"
        supported_reasoning_levels = @(
            [ordered]@{ effort = "low"; description = "Fast responses" },
            [ordered]@{ effort = "medium"; description = "Balanced reasoning" },
            [ordered]@{ effort = "high"; description = "More deliberate reasoning" },
            [ordered]@{ effort = "xhigh"; description = "Maximum reasoning" }
        )
        shell_type = "shell_command"
        visibility = "list"
        supported_in_api = $true
        priority = $Priority
        additional_speed_tiers = @()
        service_tiers = @()
        availability_nux = $null
        upgrade = $null
        base_instructions = "You are Codex, a coding agent."
        supports_reasoning_summaries = $false
        default_reasoning_summary = "auto"
        support_verbosity = $false
        default_verbosity = $null
        apply_patch_tool_type = $null
        web_search_tool_type = "text"
        truncation_policy = [ordered]@{ mode = "tokens"; limit = 10000 }
        supports_parallel_tool_calls = $false
        supports_image_detail_original = $false
        effective_context_window_percent = 95
        experimental_supported_tools = @()
        input_modalities = @("text", "image")
        supports_search_tool = $false
    }
}

function Write-ModelCache {
    param([string]$SelectedModel)
    $modelsText = [string]$env:ZHUDA_VISIBLE_MODELS
    if (-not $modelsText) { $modelsText = $SelectedModel }
    $models = @(Get-UniqueCsvItems $modelsText)
    if ($SelectedModel -and -not ($models -contains $SelectedModel)) {
        $models = @($SelectedModel) + $models
    }
    if ($models.Count -le 0) { return }

    $providerName = [string]$env:ZHUDA_PROVIDER
    if (-not $providerName) { $providerName = "Zhuda-Codex" }
    $items = @()
    for ($i = 0; $i -lt $models.Count; $i++) {
        $items += New-ZhudaModelDescriptor ([string]$models[$i]) (9 + ($i * 7)) $providerName
    }
    $payload = [ordered]@{
        fetched_at = [DateTime]::UtcNow.ToString("o")
        etag = "zhuda-$providerName"
        client_version = "zhuda-local"
        models = $items
    }
    Write-Utf8NoBom (Join-Path $CodexHome "models_cache.json") ($payload | ConvertTo-Json -Depth 30)
}

Ensure-Dir $ProfileRoot
Ensure-PortableKnownFolders
Ensure-Dir $CodexHome
Sync-PortableSkills
Ensure-Dir $AppData
Ensure-Dir $LocalAppData
Ensure-Dir $ElectronData
Ensure-Dir $AdapterLogDir

$env:USERPROFILE = $ProfileRoot
$env:APPDATA = $AppData
$env:LOCALAPPDATA = $LocalAppData
$env:CODEX_HOME = $CodexHome
$env:ZHUDA_CODEX_PORTABLE = "1"
$env:ELECTRON_NO_UPDATER = "1"
$env:NO_UPDATE_NOTIFIER = "1"
$env:SQUIRREL_UPDATES_DISABLED = "1"
$env:OPENAI_DISABLE_AUTO_UPDATE = "1"

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
Write-ModelCache $codexModel

if ($DryRun) {
    Write-Output "root=$Root"
    Write-Output "app=$AppExe"
    Write-Output "profile=$ProfileRoot"
    Write-Output "codex_home=$CodexHome"
    Write-Output "codex_skills=$CodexSkills"
    Write-Output "bundled_skills=$(Test-Path $BundledSkills)"
    Write-Output "skills_ready=$(Test-Path $CodexSkills)"
    Write-Output "model_cache=$(Join-Path $CodexHome 'models_cache.json')"
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
    Start-DetachedProcess -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Adapter,
        "-ServeOnly", "-Model", $Model
    )
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 300
        if (Test-Adapter) { break }
    }
}

if (-not (Test-Adapter)) {
    Write-Warning "Adapter is not healthy yet; launching Codex anyway."
}

if (-not $NoLaunch) {
    $cdpPort = Get-FreeCdpPort
    Start-ModelInjector $cdpPort $codexModel
    Start-Sleep -Milliseconds 250
    Start-DetachedProcess -FilePath $AppExe -ArgumentList @("--user-data-dir=$ElectronData", "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=$cdpPort") -WindowStyle 1
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

function Find-AppAsar {
    param([string]$PortableRoot)
    foreach ($path in @(
        (Join-Path $PortableRoot "app\resources\app.asar"),
        (Join-Path $PortableRoot "app\Resources\app.asar"),
        (Join-Path $PortableRoot "app\app.asar")
    )) {
        if (Test-Path $path) { return $path }
    }
    $found = Get-ChildItem -Path (Join-Path $PortableRoot "app") -Filter "app.asar" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return ""
}

function Find-PythonCommand {
    foreach ($name in @("python.exe", "python3.exe", "py.exe", "python", "python3", "py")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    return ""
}

function Find-NpxCommand {
    foreach ($name in @("npx.cmd", "npx.exe", "npx")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    return ""
}

function Patch-AppAsarModelList {
    param([string]$PortableRoot)
    $asar = Find-AppAsar $PortableRoot
    if (-not $asar) {
        Write-Warning "app.asar not found; model menu will use model cache/injector fallback."
        return
    }
    $patcher = Join-Path $PortableRoot "tools\patch_codex_asar_models.py"
    if (-not (Test-Path $patcher)) {
        Write-Warning "Zhuda bundle patcher not found; model menu will use model cache/injector fallback."
        return
    }
    $python = Find-PythonCommand
    $npx = Find-NpxCommand
    if (-not $python -or -not $npx) {
        Write-Warning "Python or npx not found; app.asar model-list patch skipped."
        return
    }
    $env:PATH = (Split-Path -Parent $npx) + [IO.Path]::PathSeparator + $env:PATH
    if ((Split-Path -Leaf $python).ToLowerInvariant() -eq "py.exe" -or (Split-Path -Leaf $python).ToLowerInvariant() -eq "py") {
        & $python -3 $patcher --asar $asar | Out-Host
    } else {
        & $python $patcher --asar $asar | Out-Host
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "app.asar model-list patch failed with exit code $LASTEXITCODE; model cache/injector fallback remains available."
    }
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

    $sourceRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    $skillsSource = ""
    if ($IncludeUserSkills) {
        $candidate = Join-Path $env:USERPROFILE ".codex\skills"
        if (Test-Path $candidate) { $skillsSource = $candidate }
    }
    if (-not $skillsSource) {
        $candidate = Join-Path $sourceRoot "skills"
        if (Test-Path $candidate) { $skillsSource = $candidate }
    }
    if ($skillsSource) {
        Copy-Tree $skillsSource (Join-Path $tmpRoot "skills")
    }

    $toolNames = @(
        "windows_zhuda_local_adapter.ps1",
        "windows_zhuda_remote.ps1",
        "windows_zhuda_connect.ps1",
        "zhuda_model_injector.ps1"
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

    $patcherName = "patch_codex_asar_models.py"
    $patcherLocal = Join-Path $RuntimeDir $patcherName
    if ($receiver) {
        try { Download-File "$receiver/download/$patcherName" $patcherLocal } catch {}
    }
    if (-not (Test-Path $patcherLocal)) {
        $sourceRootForPatcher = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $candidate = Join-Path $sourceRootForPatcher "scripts\$patcherName"
        if (Test-Path $candidate) { $patcherLocal = $candidate }
    }
    if (Test-Path $patcherLocal) {
        Copy-Item $patcherLocal (Join-Path $tmpRoot "tools\$patcherName") -Force
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
    Patch-AppAsarModelList $tmpRoot

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
