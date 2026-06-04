#requires -version 5.1
param(
    [string]$Provider = "",
    [string]$Model = "",
    [string]$ApiKey = "",
    [switch]$Headless,
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $PSCommandPath
$PortableRoot = $ScriptRoot
$ProjectRoot = Split-Path -Parent $ScriptRoot

function Resolve-ManifestPath {
    foreach ($path in @(
        (Join-Path $ScriptRoot "providers.json"),
        (Join-Path $ProjectRoot "providers.json"),
        (Join-Path $ScriptRoot "..\providers.json")
    )) {
        if (Test-Path $path) { return (Resolve-Path $path).Path }
    }
    throw "providers.json not found near $ScriptRoot"
}

$ManifestPath = Resolve-ManifestPath
$Manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json

function Ensure-Dir {
    param([string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $enc)
}

function Join-ProcessArguments {
    param([string[]]$ArgumentList)
    $escaped = foreach ($arg in @($ArgumentList)) {
        if ($null -eq $arg) {
            '""'
        } else {
            '"' + ([string]$arg -replace '"', '\"') + '"'
        }
    }
    return ($escaped -join " ")
}

function Start-ProcessWithEnvironment {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [hashtable]$Environment
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = Join-ProcessArguments $ArgumentList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    foreach ($entry in $Environment.GetEnumerator()) {
        if ($null -ne $entry.Value -and [string]$entry.Value) {
            $psi.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
        }
    }
    [System.Diagnostics.Process]::Start($psi) | Out-Null
}

function Get-ProviderById {
    param([string]$Id)
    @($Manifest.providers | Where-Object { $_.id -eq $Id } | Select-Object -First 1)[0]
}

function Get-JsonProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $Default
}

function Get-DefaultProvider {
    $id = if ($Provider) { $Provider } else { [string]$Manifest.default_provider }
    $found = Get-ProviderById $id
    if ($found) { return $found }
    return @($Manifest.providers | Select-Object -First 1)[0]
}

function Get-ModelById {
    param($ProviderObject, [string]$Id)
    $models = @($ProviderObject.models)
    if ($Id) {
        $found = @($models | Where-Object { $_.id -eq $Id -or $_.codex_slug -eq $Id -or $_.upstream -eq $Id } | Select-Object -First 1)
        if ($found.Count -gt 0) { return $found[0] }
    }
    $default = @($models | Where-Object { [bool](Get-JsonProperty $_ "default" $false) } | Select-Object -First 1)
    if ($default.Count -gt 0) { return $default[0] }
    return @($models | Select-Object -First 1)[0]
}

function Get-UpstreamModels {
    param($ProviderObject)
    if ($ProviderObject.PSObject.Properties["upstream_models"]) { return @($ProviderObject.upstream_models) }
    return @($ProviderObject.models)
}

function Resolve-CodexModelSlug {
    param($ModelObject)
    $slug = [string](Get-JsonProperty $ModelObject "codex_slug" "")
    if ($slug) { return $slug }
    return [string](Get-JsonProperty $ModelObject "upstream" "")
}

function Get-RuntimeContext {
    $portableExe = Join-Path $PortableRoot "app\Codex.exe"
    if (Test-Path $portableExe) {
        $profileRoot = Join-Path $PortableRoot "profile"
        return @{
            portable = $true
            root = $PortableRoot
            profile = $profileRoot
            runtime = (Join-Path $profileRoot ".zhuda-codex-win")
            starter = (Join-Path $PortableRoot "Start-Zhuda-Codex-Local.ps1")
        }
    }
    return @{
        portable = $false
        root = $ScriptRoot
        profile = $env:USERPROFILE
        runtime = (Join-Path $env:USERPROFILE ".zhuda-codex-win")
        starter = ""
    }
}

function Convert-MappingsObjectToHashtable {
    param($Mappings)
    $table = [ordered]@{}
    if ($null -eq $Mappings) { return $table }
    if ($Mappings -is [string]) {
        if (-not $Mappings.Trim()) { return $table }
        $Mappings = $Mappings | ConvertFrom-Json
    }
    if ($Mappings -is [System.Collections.IDictionary]) {
        foreach ($key in $Mappings.Keys) {
            if ($key -and $Mappings[$key]) { $table[[string]$key] = [string]$Mappings[$key] }
        }
        return $table
    }
    foreach ($prop in $Mappings.PSObject.Properties) {
        if ($prop.Name -and $prop.Value) { $table[[string]$prop.Name] = [string]$prop.Value }
    }
    return $table
}

function Save-SelectedRuntimeMappings {
    param($ProviderObject, $Mappings, [string]$Secret)
    if (-not [bool](Get-JsonProperty $ProviderObject "enabled" $false)) { throw "Provider is not enabled yet: $($ProviderObject.name)" }
    $trimmedSecret = ""
    if ($Secret) { $trimmedSecret = $Secret.Trim() }
    if (-not $trimmedSecret) { throw "API key is empty." }

    $ctx = Get-RuntimeContext
    Ensure-Dir $ctx.runtime
    $mappingTable = Convert-MappingsObjectToHashtable $Mappings
    if ($mappingTable.Count -le 0) { throw "No model mappings were selected." }
    $selectedUpstream = if ($mappingTable.Contains("zhuda-codex")) { [string]$mappingTable["zhuda-codex"] } else { [string](@($mappingTable.Values)[0]) }

    [string]$ProviderObject.id | Set-Content -Path (Join-Path $ctx.runtime "active_provider.txt") -Encoding ASCII
    $selectedUpstream | Set-Content -Path (Join-Path $ctx.runtime "active_model.txt") -Encoding ASCII
    Write-Utf8NoBom (Join-Path $ctx.runtime "active_mappings.json") ($mappingTable | ConvertTo-Json -Depth 20 -Compress)
    Remove-Item (Join-Path $ctx.runtime "active_api_key.txt") -Force -ErrorAction SilentlyContinue

    $state = [ordered]@{
        provider = [string]$ProviderObject.id
        provider_name = [string]$ProviderObject.name
        endpoint = [string]$env:ZHUDA_WEB_LAUNCH_ENDPOINT_ID
        selected_upstream = $selectedUpstream
        mappings = $mappingTable
        portable = [bool]$ctx.portable
        api_key_storage = "process_environment_only"
        api_key_persisted = $false
        updated_at = [DateTime]::UtcNow.ToString("o")
    }
    Write-Utf8NoBom (Join-Path $ctx.runtime "launcher_state.json") ($state | ConvertTo-Json -Depth 20)
    return $ctx
}

function Start-ZhudaCodexMappings {
    param($Context, $ProviderObject, $Mappings, [string]$Secret)
    if ($NoLaunch) { return }
    $sessionKey = ""
    if ($Secret) { $sessionKey = $Secret.Trim() }
    $mappingTable = Convert-MappingsObjectToHashtable $Mappings
    $mappingJson = $mappingTable | ConvertTo-Json -Depth 20 -Compress
    $selectedUpstream = ""
    if ($mappingTable.Contains("zhuda-codex")) { $selectedUpstream = [string]$mappingTable["zhuda-codex"] }
    if (-not $selectedUpstream -and $env:ZHUDA_WEB_LAUNCH_MODEL_ID) { $selectedUpstream = [string]$env:ZHUDA_WEB_LAUNCH_MODEL_ID }
    if (-not $selectedUpstream -and $mappingTable.Count -gt 0) { $selectedUpstream = [string](@($mappingTable.Values)[0]) }
    if (-not $selectedUpstream) { $selectedUpstream = "zhuda-codex" }
    $visibleModels = [string]$env:ZHUDA_WEB_LAUNCH_VISIBLE_MODELS
    $launchEnv = @{
        ZHUDA_PROVIDER = [string]$ProviderObject.id
        ZHUDA_MODEL_MAPPINGS = $mappingJson
        ZHUDA_SELECTED_CODEX_MODEL = $selectedUpstream
        ZHUDA_SELECTED_UPSTREAM_MODEL = $selectedUpstream
        ZHUDA_VISIBLE_MODELS = $visibleModels
        ZHUDA_FORCE_UPSTREAM_MODEL = "0"
        ZHUDA_CODEX_LAUNCHER_SESSION = [DateTime]::UtcNow.ToString("o")
    }
    $injectorPath = Join-Path $ScriptRoot "zhuda_model_injector.ps1"
    if (Test-Path $injectorPath) {
        $launchEnv["ZHUDA_MODEL_INJECTOR_PATH"] = $injectorPath
    }
    if ($ProviderObject.id -eq "mimo") {
        $launchEnv["MIMO_API_KEY_1"] = $sessionKey
        $launchEnv["MIMO_API_KEY"] = $sessionKey
        $launchEnv["XIAOMI_MIMO_API_KEY"] = $sessionKey
        $launchEnv["ZHUDA_MIMO_VISIBLE_MODELS"] = $visibleModels
        $launchEnv["ZHUDA_MAX_INPUT_TOKENS"] = "12000"
        $launchEnv["ZHUDA_MAX_PINNED_TOKENS"] = "3500"
        $launchEnv["ZHUDA_MAX_HISTORY_ITEM_TOKENS"] = "1200"
        $launchEnv["ZHUDA_MAX_TOOL_OUTPUT_CHARS"] = "1200"
        $launchEnv["ZHUDA_MIMO_MAX_TOKENS"] = "2048"
        $launchEnv["ZHUDA_UPSTREAM_TIMEOUT_SECONDS"] = "90"
        $launchEnv["ZHUDA_TIMEOUT_COOLDOWN_SECONDS"] = "90"
        $launchEnv["ZHUDA_ERROR_COOLDOWN_SECONDS"] = "45"
        $launchEnv["ZHUDA_LARGE_PROMPT_TOKEN_THRESHOLD"] = "12000"
        $launchEnv["ZHUDA_LARGE_PROMPT_MIN_INTERVAL_MS"] = "25000"
        $launchEnv["ZHUDA_LARGE_PROMPT_RATE_LIMIT_COOLDOWN_SECONDS"] = "180"
        $launchEnv["ZHUDA_MODEL_MIN_INTERVALS_MS"] = "mimo-v2.5-pro:12000,mimo-v2.5:8000"
        $baseUrl = [string]$env:ZHUDA_WEB_LAUNCH_BASE_URL
        if (-not $baseUrl) { $baseUrl = Get-JsonProperty $ProviderObject "base_url" "" }
        if ($baseUrl) {
            $launchEnv["MIMO_BASE_URL"] = [string]$baseUrl
            $launchEnv["XIAOMI_MIMO_BASE_URL"] = [string]$baseUrl
        }
        if ($env:ZHUDA_WEB_LAUNCH_ENDPOINT_ID) {
            $launchEnv["ZHUDA_PROVIDER_ENDPOINT"] = [string]$env:ZHUDA_WEB_LAUNCH_ENDPOINT_ID
        }
    } elseif ($ProviderObject.id -eq "deepseek") {
        $launchEnv["DEEPSEEK_API_KEY_1"] = $sessionKey
        $launchEnv["DEEPSEEK_API_KEY"] = $sessionKey
        $launchEnv["ZHUDA_DEEPSEEK_API_KEY"] = $sessionKey
        $launchEnv["ZHUDA_DEEPSEEK_VISIBLE_MODELS"] = $visibleModels
        $launchEnv["ZHUDA_DEEPSEEK_MODELS"] = $mappingJson
        $launchEnv["ZHUDA_DEEPSEEK_FALLBACK_MODELS"] = "0"
        $launchEnv["ZHUDA_DEEPSEEK_ENABLE_TOOLS"] = "1"
        $launchEnv["ZHUDA_DEEPSEEK_MAX_TOKENS"] = "4096"
        $launchEnv["ZHUDA_UPSTREAM_TIMEOUT_SECONDS"] = "120"
        $launchEnv["ZHUDA_TIMEOUT_COOLDOWN_SECONDS"] = "120"
        $launchEnv["ZHUDA_ERROR_COOLDOWN_SECONDS"] = "45"
        $launchEnv["ZHUDA_MODEL_MIN_INTERVALS_MS"] = "deepseek-v4-pro:8000,deepseek-v4-flash:4000"
        $baseUrl = [string]$env:ZHUDA_WEB_LAUNCH_BASE_URL
        if (-not $baseUrl) { $baseUrl = Get-JsonProperty $ProviderObject "base_url" "" }
        if ($baseUrl) {
            $launchEnv["DEEPSEEK_BASE_URL"] = [string]$baseUrl
            $launchEnv["ZHUDA_DEEPSEEK_BASE_URL"] = [string]$baseUrl
        }
    } else {
        $launchEnv["ZHUDA_GEMINI_API_KEY"] = $sessionKey
        $launchEnv["GEMINI_API_KEY_1"] = $sessionKey
        $launchEnv["GEMINI_API_KEY"] = $sessionKey
        $launchEnv["ZHUDA_GEMINI_VISIBLE_MODELS"] = $visibleModels
    }
    if ($Context.portable) {
        if (-not (Test-Path $Context.starter)) { throw "Portable starter not found: $($Context.starter)" }
        Start-ProcessWithEnvironment -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Context.starter,
            "-Model", $selectedUpstream
        ) -Environment $launchEnv
        return
    }

    $adapter = Find-DesktopAdapter
    Start-ProcessWithEnvironment -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $adapter,
        "-Local", "-Model", $selectedUpstream
    ) -Environment $launchEnv
}

function Apply-And-LaunchMappings {
    param($ProviderObject, $Mappings, [string]$Secret)
    $ctx = Save-SelectedRuntimeMappings $ProviderObject $Mappings $Secret
    Start-ZhudaCodexMappings $ctx $ProviderObject $Mappings $Secret
    return $ctx
}

function Find-DesktopAdapter {
    $ctx = Get-RuntimeContext
    foreach ($path in @(
        (Join-Path $ctx.runtime "windows_zhuda_local_adapter.ps1"),
        (Join-Path $ScriptRoot "windows_zhuda_local_adapter.ps1"),
        (Join-Path $ScriptRoot "legacy\windows_zhuda_codex_switch.ps1")
    )) {
        if (Test-Path $path) { return $path }
    }
    throw "Could not find Windows Zhuda local adapter script."
}

function Save-SelectedRuntime {
    param($ProviderObject, $ModelObject, [string]$Secret)
    if (-not [bool](Get-JsonProperty $ProviderObject "enabled" $false)) { throw "Provider is not enabled yet: $($ProviderObject.name)" }
    $trimmedSecret = ""
    if ($Secret) { $trimmedSecret = $Secret.Trim() }
    if (-not $trimmedSecret) { throw "API key is empty." }
    if ($ProviderObject.id -ne "gemini") { throw "Only Gemini is implemented right now." }

    $ctx = Get-RuntimeContext
    Ensure-Dir $ctx.runtime
    [string]$ModelObject.upstream | Set-Content -Path (Join-Path $ctx.runtime "active_model.txt") -Encoding ASCII
    Remove-Item (Join-Path $ctx.runtime "active_api_key.txt") -Force -ErrorAction SilentlyContinue

    $state = [ordered]@{
        provider = [string]$ProviderObject.id
        provider_name = [string]$ProviderObject.name
        model = [string]$ModelObject.id
        codex_slug = [string]$ModelObject.codex_slug
        upstream = [string]$ModelObject.upstream
        portable = [bool]$ctx.portable
        api_key_storage = "process_environment_only"
        api_key_persisted = $false
        updated_at = [DateTime]::UtcNow.ToString("o")
    }
    Write-Utf8NoBom (Join-Path $ctx.runtime "launcher_state.json") ($state | ConvertTo-Json -Depth 10)
    return $ctx
}

function Start-ZhudaCodex {
    param($Context, $ModelObject, [string]$Secret)
    if ($NoLaunch) { return }
    $modelId = [string]$ModelObject.id
    $sessionKey = ""
    if ($Secret) { $sessionKey = $Secret.Trim() }
    $launchEnv = @{
        ZHUDA_GEMINI_API_KEY = $sessionKey
        GEMINI_API_KEY_1 = $sessionKey
        GEMINI_API_KEY = $sessionKey
        ZHUDA_CODEX_LAUNCHER_SESSION = [DateTime]::UtcNow.ToString("o")
    }
    if ($Context.portable) {
        if (-not (Test-Path $Context.starter)) { throw "Portable starter not found: $($Context.starter)" }
        Start-ProcessWithEnvironment -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Context.starter,
            "-Model", $modelId
        ) -Environment $launchEnv
        return
    }

    $adapter = Find-DesktopAdapter
    Start-ProcessWithEnvironment -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $adapter,
        "-Local", "-Model", $modelId
    ) -Environment $launchEnv
}

function Get-MappingPreview {
    param($ProviderObject, $ModelObject)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Provider: $($ProviderObject.name)") | Out-Null
    $lines.Add("Default: zhuda-codex -> $($ModelObject.upstream)") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($item in (Get-UpstreamModels $ProviderObject)) {
        $label = if ($item.label) { [string]$item.label } else { [string]$item.id }
        $lines.Add("$label -> $($item.upstream)") | Out-Null
    }
    return ($lines.ToArray() -join "`r`n")
}

function Resolve-AssetPath {
    param([string[]]$RelativePaths)
    $roots = @(
        $ScriptRoot,
        $ProjectRoot,
        (Join-Path $ScriptRoot "assets"),
        (Join-Path $ProjectRoot "assets"),
        (Join-Path $PortableRoot "assets")
    )
    foreach ($root in $roots) {
        foreach ($rel in $RelativePaths) {
            $path = Join-Path $root $rel
            if (Test-Path $path) { return (Resolve-Path $path).Path }
        }
    }
    return ""
}

function Apply-And-Launch {
    param($ProviderObject, $ModelObject, [string]$Secret)
    $upstream = if ($ModelObject.upstream) { [string]$ModelObject.upstream } else { [string]$ModelObject.id }
    $ctx = Save-SelectedRuntimeMappings $ProviderObject @{ "zhuda-codex" = $upstream } $Secret
    Start-ZhudaCodexMappings $ctx $ProviderObject @{ "zhuda-codex" = $upstream } $Secret
    return $ctx
}

if ($Headless -or ($Provider -and $Model -and $ApiKey)) {
    $p = Get-DefaultProvider
    $effectiveApiKey = if ($ApiKey) { $ApiKey } else { [string]$env:ZHUDA_WEB_LAUNCH_API_KEY }
    $mappingPayload = $env:ZHUDA_WEB_LAUNCH_MAPPINGS
    if (-not $mappingPayload) {
        $models = Get-UpstreamModels $p
        $first = if (@($models).Count -gt 0) { [string]$models[0].upstream } else { "" }
        $mappingPayload = (@{ "zhuda-codex" = $first } | ConvertTo-Json -Compress)
    }
    $mappingTable = Convert-MappingsObjectToHashtable $mappingPayload
    $ctx = Apply-And-LaunchMappings $p $mappingTable $effectiveApiKey
    $selectedUpstream = if ($mappingTable.Contains("zhuda-codex")) { [string]$mappingTable["zhuda-codex"] } else { [string](@($mappingTable.Values)[0]) }
    Write-Output "provider=$($p.id)"
    if ($env:ZHUDA_WEB_LAUNCH_ENDPOINT_ID) { Write-Output "endpoint=$($env:ZHUDA_WEB_LAUNCH_ENDPOINT_ID)" }
    Write-Output "mappings=$($mappingTable.Count)"
    Write-Output "upstream=$selectedUpstream"
    Write-Output "portable=$($ctx.portable)"
    Write-Output "runtime=$($ctx.runtime)"
    exit 0
}

$WebLauncher = Join-Path $ProjectRoot "launcher\zhuda_web_launcher.ps1"
$WebProjectRoot = $ProjectRoot
if (-not (Test-Path $WebLauncher)) {
    $WebLauncher = Join-Path $ScriptRoot "launcher\zhuda_web_launcher.ps1"
    $WebProjectRoot = $ScriptRoot
}
if (Test-Path $WebLauncher) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $WebLauncher -ProjectRoot $WebProjectRoot -LaunchScript $PSCommandPath
    exit $LASTEXITCODE
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$HeroImagePath = Resolve-AssetPath @(
    "brand\zhuda-codex-launcher-hero-533x300.png",
    "brand\zhuda-codex-launcher-hero.png",
    "assets\brand\zhuda-codex-launcher-hero-533x300.png",
    "assets\brand\zhuda-codex-launcher-hero.png"
)
$ProviderImagePath = Resolve-AssetPath @(
    "brand\zhuda-codex-provider-gemini-240x180.png",
    "brand\zhuda-codex-provider-gemini.png",
    "assets\brand\zhuda-codex-provider-gemini-240x180.png",
    "assets\brand\zhuda-codex-provider-gemini.png"
)

$form = New-Object Windows.Forms.Form
$form.Text = "Zhuda-Codex Launcher"
$form.StartPosition = "CenterScreen"
$form.Width = 860
$form.Height = 640
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$heroBox = New-Object Windows.Forms.PictureBox
$heroBox.Left = 20
$heroBox.Top = 18
$heroBox.Width = 360
$heroBox.Height = 204
$heroBox.SizeMode = "Zoom"
$heroBox.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
if ($HeroImagePath) {
    try { $heroBox.Image = [System.Drawing.Image]::FromFile($HeroImagePath) } catch {}
}
$form.Controls.Add($heroBox)

$brandTitle = New-Object Windows.Forms.Label
$brandTitle.Text = "Zhuda-Codex"
$brandTitle.Left = 420
$brandTitle.Top = 24
$brandTitle.Width = 390
$brandTitle.Height = 34
$brandTitle.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($brandTitle)

$brandSubtitle = New-Object Windows.Forms.Label
$brandSubtitle.Text = "Provider picker with one-session API key injection"
$brandSubtitle.Left = 422
$brandSubtitle.Top = 58
$brandSubtitle.Width = 390
$brandSubtitle.Height = 24
$brandSubtitle.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($brandSubtitle)

$providerLabel = New-Object Windows.Forms.Label
$providerLabel.Text = "Provider"
$providerLabel.Left = 420
$providerLabel.Top = 100
$providerLabel.Width = 120
$form.Controls.Add($providerLabel)

$providerCombo = New-Object Windows.Forms.ComboBox
$providerCombo.Left = 520
$providerCombo.Top = 96
$providerCombo.Width = 300
$providerCombo.DropDownStyle = "DropDownList"
$form.Controls.Add($providerCombo)

$modelLabel = New-Object Windows.Forms.Label
$modelLabel.Text = "Model"
$modelLabel.Left = 420
$modelLabel.Top = 148
$modelLabel.Width = 120
$form.Controls.Add($modelLabel)

$modelCombo = New-Object Windows.Forms.ComboBox
$modelCombo.Left = 520
$modelCombo.Top = 144
$modelCombo.Width = 300
$modelCombo.DropDownStyle = "DropDownList"
$form.Controls.Add($modelCombo)

$keyLabel = New-Object Windows.Forms.Label
$keyLabel.Text = "API key"
$keyLabel.Left = 420
$keyLabel.Top = 196
$keyLabel.Width = 120
$form.Controls.Add($keyLabel)

$keyBox = New-Object Windows.Forms.TextBox
$keyBox.Left = 520
$keyBox.Top = 192
$keyBox.Width = 300
$keyBox.UseSystemPasswordChar = $true
$form.Controls.Add($keyBox)

$previewLabel = New-Object Windows.Forms.Label
$previewLabel.Text = "Adapter mapping"
$previewLabel.Left = 20
$previewLabel.Top = 250
$previewLabel.Width = 140
$form.Controls.Add($previewLabel)

$providerArtBox = New-Object Windows.Forms.PictureBox
$providerArtBox.Left = 20
$providerArtBox.Top = 282
$providerArtBox.Width = 240
$providerArtBox.Height = 180
$providerArtBox.SizeMode = "Zoom"
$providerArtBox.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
if ($ProviderImagePath) {
    try { $providerArtBox.Image = [System.Drawing.Image]::FromFile($ProviderImagePath) } catch {}
}
$form.Controls.Add($providerArtBox)

$previewBox = New-Object Windows.Forms.TextBox
$previewBox.Left = 280
$previewBox.Top = 282
$previewBox.Width = 540
$previewBox.Height = 180
$previewBox.Multiline = $true
$previewBox.ReadOnly = $true
$previewBox.ScrollBars = "Vertical"
$form.Controls.Add($previewBox)

$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Left = 20
$statusLabel.Top = 482
$statusLabel.Width = 800
$statusLabel.Height = 36
$statusLabel.Text = "Gemini is ready. API keys are injected for this launch only and are not saved locally."
$form.Controls.Add($statusLabel)

$launchButton = New-Object Windows.Forms.Button
$launchButton.Text = "Inject Session and Launch"
$launchButton.Left = 630
$launchButton.Top = 535
$launchButton.Width = 190
$launchButton.Height = 32
$form.Controls.Add($launchButton)

$cancelButton = New-Object Windows.Forms.Button
$cancelButton.Text = "Cancel"
$cancelButton.Left = 520
$cancelButton.Top = 535
$cancelButton.Width = 90
$cancelButton.Height = 32
$cancelButton.Add_Click({ $form.Close() })
$form.Controls.Add($cancelButton)

$script:ProviderByDisplay = @{}
$script:ModelByDisplay = @{}

foreach ($p in @($Manifest.providers)) {
    $suffix = if ([bool](Get-JsonProperty $p "enabled" $false)) { "ready" } else { "coming soon" }
    $display = "$($p.name) [$($p.id)] - $suffix"
    $script:ProviderByDisplay[$display] = $p
    [void]$providerCombo.Items.Add($display)
}

function Refresh-Models {
    $script:ModelByDisplay = @{}
    $modelCombo.Items.Clear()
    $p = $script:ProviderByDisplay[[string]$providerCombo.SelectedItem]
    if (-not $p) { return }
    $defaultModel = Get-JsonProperty $p "default_model" ""
    foreach ($m in (Get-UpstreamModels $p)) {
        $display = "$($m.label) [$($m.id)] => $($m.upstream)"
        $script:ModelByDisplay[$display] = $m
        [void]$modelCombo.Items.Add($display)
        if ([bool](Get-JsonProperty $m "default" $false) -or ($defaultModel -and $m.id -eq $defaultModel)) {
            $modelCombo.SelectedItem = $display
        }
    }
    if ($modelCombo.SelectedIndex -lt 0 -and $modelCombo.Items.Count -gt 0) { $modelCombo.SelectedIndex = 0 }
    $launchButton.Enabled = [bool](Get-JsonProperty $p "enabled" $false)
    if (-not [bool](Get-JsonProperty $p "enabled" $false)) {
        $note = Get-JsonProperty $p "note" ""
        $previewBox.Text = if ($note) { [string]$note } else { "Reserved for later." }
    } else {
        Refresh-Preview
    }
}

function Refresh-Preview {
    $p = $script:ProviderByDisplay[[string]$providerCombo.SelectedItem]
    $m = $script:ModelByDisplay[[string]$modelCombo.SelectedItem]
    if ($p -and $m) {
        $previewBox.Text = Get-MappingPreview $p $m
    }
}

$providerCombo.Add_SelectedIndexChanged({ Refresh-Models })
$modelCombo.Add_SelectedIndexChanged({ Refresh-Preview })

$defaultProvider = Get-DefaultProvider
foreach ($display in $script:ProviderByDisplay.Keys) {
    if ($script:ProviderByDisplay[$display].id -eq $defaultProvider.id) {
        $providerCombo.SelectedItem = $display
        break
    }
}
if ($providerCombo.SelectedIndex -lt 0 -and $providerCombo.Items.Count -gt 0) { $providerCombo.SelectedIndex = 0 }

$launchButton.Add_Click({
    try {
        $p = $script:ProviderByDisplay[[string]$providerCombo.SelectedItem]
        $m = $script:ModelByDisplay[[string]$modelCombo.SelectedItem]
        if (-not $p -or -not $m) { throw "Select a provider and model." }
        $ctx = Apply-And-Launch $p $m $keyBox.Text
        [Windows.Forms.MessageBox]::Show(
            "Injected $($p.name): zhuda-codex -> $($m.upstream)`r`nAPI key was not saved locally.`r`nRuntime: $($ctx.runtime)",
            "Zhuda-Codex Launcher",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        $form.Close()
    } catch {
        [Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "Zhuda-Codex Launcher",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

[void]$form.ShowDialog()
