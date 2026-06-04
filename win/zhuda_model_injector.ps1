#requires -version 5.1
param(
    [int]$Port = 9233,
    [string]$Models = "",
    [string]$DefaultModel = "",
    [string]$ProviderName = "Zhuda-Codex",
    [int]$DurationSeconds = 75,
    [int]$IntervalMilliseconds = 1200,
    [int]$IdleExitSeconds = 300,
    [switch]$Preload,
    [switch]$ReloadOnce
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

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

function ConvertTo-JsonLiteral {
    param($Value)
    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Get-DevToolsTargets {
    param([int]$DevToolsPort)
    foreach ($devHost in @("127.0.0.1", "localhost")) {
        foreach ($path in @("/json/list", "/json")) {
            try {
                $targets = Invoke-RestMethod -UseBasicParsing -Uri "http://${devHost}:$DevToolsPort$path" -TimeoutSec 1
                if ($targets) { return @($targets) }
            } catch {}
        }
    }
    return @()
}

function Send-CdpCommand {
    param([string]$WebSocketUrl, [string]$Method, $Params, [int]$Id)
    $payload = @{
        id = $Id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 20 -Compress

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $uri = New-Object System.Uri($WebSocketUrl)
    $connect = $ws.ConnectAsync($uri, [Threading.CancellationToken]::None)
    if (-not $connect.Wait(2500)) {
        try { $ws.Dispose() } catch {}
        throw "websocket connect timeout"
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $segment = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
    $send = $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None)
    if (-not $send.Wait(2500)) {
        try { $ws.Dispose() } catch {}
        throw "websocket send timeout"
    }
    try {
        $buffer = New-Object byte[] 4096
        $recvSegment = New-Object System.ArraySegment[byte] -ArgumentList @(,$buffer)
        $recv = $ws.ReceiveAsync($recvSegment, [Threading.CancellationToken]::None)
        [void]$recv.Wait(500)
    } catch {}
    try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [Threading.CancellationToken]::None).Wait(200) | Out-Null } catch {}
    try { $ws.Dispose() } catch {}
}

function Send-CdpEvaluate {
    param([string]$WebSocketUrl, [string]$Expression, [int]$Id)
    Send-CdpCommand $WebSocketUrl "Runtime.evaluate" @{
        expression = $Expression
        awaitPromise = $false
        returnByValue = $true
    } $Id
}

function Send-CdpPreload {
    param([string]$WebSocketUrl, [string]$Expression, [int]$Id)
    Send-CdpCommand $WebSocketUrl "Page.addScriptToEvaluateOnNewDocument" @{
        source = $Expression
    } $Id
}

function Send-CdpReload {
    param([string]$WebSocketUrl, [int]$Id)
    Send-CdpCommand $WebSocketUrl "Page.reload" @{
        ignoreCache = $true
    } $Id
}

function New-InjectionExpression {
    param([string[]]$ModelNames, [string]$SelectedModel, [string]$Provider)
    $modelsJson = ConvertTo-JsonLiteral $ModelNames
    $defaultJson = ConvertTo-JsonLiteral $SelectedModel
    $providerJson = ConvertTo-JsonLiteral $Provider
    $script = @'
(() => {
  const catalog = {
    models: __MODELS_JSON__,
    defaultModel: __DEFAULT_JSON__,
    providerName: __PROVIDER_JSON__,
    installedAt: Date.now()
  };
  const rootKey = "__zhudaCodexModelInjection";
  const previous = window[rootKey] || {};
  window[rootKey] = Object.assign(previous, catalog, {
    version: "win-1",
    hits: (previous.hits || 0) + 1
  });

  const legacyModelNames = new Set([
    "gpt-5.5",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.3-codex",
    "gpt-5.2",
    "zhuda-codex",
    "gemini-codex"
  ]);

  const effortObjects = ["minimal", "low", "medium", "high", "xhigh"].map((reasoningEffort) => ({
    reasoningEffort,
    description: reasoningEffort + " effort"
  }));

  function isObject(value) {
    return value && typeof value === "object";
  }

  function normalizeModelName(value) {
    return String(value || "").trim().replace(/[\u2010-\u2015]/g, "-").toLowerCase();
  }

  function modelNames() {
    const names = [window[rootKey].defaultModel].concat(window[rootKey].models || []);
    return Array.from(new Set(names.filter((name) => typeof name === "string" && name.trim())));
  }

  function allowedModelSet() {
    return new Set(modelNames().map(normalizeModelName));
  }

  function isLegacyModelName(value) {
    const normalized = normalizeModelName(value);
    if (!normalized || allowedModelSet().has(normalized)) return false;
    return legacyModelNames.has(normalized) || /^gpt-5(?:\.|-)/.test(normalized);
  }

  function modelKey(item) {
    if (!isObject(item)) return "";
    return item.model || item.id || item.slug || item.name || item.label || item.title || item.displayName || item.display_name || "";
  }

  function descriptor(name) {
    return {
      id: name,
      model: name,
      slug: name,
      name: name,
      label: name,
      title: name,
      displayName: name,
      display_name: name,
      description: window[rootKey].providerName || "Zhuda-Codex model",
      hidden: false,
      disabled: false,
      isAvailable: true,
      isDefault: name === window[rootKey].defaultModel,
      defaultReasoningEffort: "medium",
      default_reasoning_effort: "medium",
      supportedReasoningEfforts: effortObjects,
      supported_reasoning_efforts: effortObjects
    };
  }

  function patchStringArray(items) {
    if (!Array.isArray(items) || !items.every((item) => typeof item === "string")) return false;
    let changed = false;
    for (let index = items.length - 1; index >= 0; index--) {
      if (isLegacyModelName(items[index])) {
        items.splice(index, 1);
        changed = true;
      }
    }
    for (const name of modelNames()) {
      if (!items.includes(name)) {
        items.push(name);
        changed = true;
      }
    }
    return changed;
  }

  function patchModelObjectArray(items, allowEmpty) {
    if (!Array.isArray(items)) return false;
    if (!allowEmpty && items.length === 0) return false;
    if (!items.every((item) => isObject(item))) return false;
    const hasModelShape = items.length === 0 || items.some((item) =>
      typeof item.model === "string" ||
      typeof item.id === "string" ||
      typeof item.slug === "string" ||
      typeof item.name === "string"
    );
    if (!hasModelShape) return false;
    let changed = false;
    for (let index = items.length - 1; index >= 0; index--) {
      if (isLegacyModelName(modelKey(items[index]))) {
        items.splice(index, 1);
        changed = true;
      }
    }
    const known = new Set(items.map(modelKey).filter(Boolean));
    for (const item of items) {
      const key = modelKey(item);
      if (modelNames().includes(key)) {
        item.hidden = false;
        item.disabled = false;
        item.isAvailable = true;
        changed = true;
      }
    }
    for (const name of modelNames()) {
      if (!known.has(name)) {
        items.push(descriptor(name));
        changed = true;
      }
    }
    return changed;
  }

  function addNamesToSet(value) {
    if (!(value instanceof Set)) return false;
    let changed = false;
    for (const name of modelNames()) {
      if (!value.has(name)) {
        value.add(name);
        changed = true;
      }
    }
    return changed;
  }

  function patchContainer(value) {
    if (!isObject(value)) return false;
    let changed = false;
    if (patchStringArray(value.models)) changed = true;
    if (patchModelObjectArray(value.models, "defaultModel" in value || "availableModels" in value || "available_models" in value)) changed = true;
    for (const key of ["data", "result", "availableModels", "available_models", "modelList", "model_list"]) {
      if (patchStringArray(value[key])) changed = true;
      if (patchModelObjectArray(value[key], key === "availableModels" || key === "available_models")) changed = true;
    }
    for (const key of ["availableModels", "available_models"]) {
      if (addNamesToSet(value[key])) changed = true;
    }
    for (const key of ["hiddenModels", "hidden_models"]) {
      if (Array.isArray(value[key])) {
        const before = value[key].length;
        value[key] = value[key].filter((name) => !modelNames().includes(name) && !isLegacyModelName(name));
        if (value[key].length !== before) changed = true;
      }
    }
    if (typeof value.defaultModel === "string" && !modelNames().includes(value.defaultModel)) {
      value.defaultModel = window[rootKey].defaultModel || modelNames()[0] || value.defaultModel;
      changed = true;
    }
    if (typeof value.default_model === "string" && !modelNames().includes(value.default_model)) {
      value.default_model = window[rootKey].defaultModel || modelNames()[0] || value.default_model;
      changed = true;
    }
    return changed;
  }

  function patchGraph(root, visited, depth) {
    if (!isObject(root) || visited.has(root) || depth > 5) return false;
    visited.add(root);
    let changed = patchContainer(root);
    if (root === window || root === document || root instanceof Element) return changed;
    for (const key of Object.keys(root)) {
      if (key === "ownerDocument" || key === "parentNode" || key === "parentElement" || key === "children" || key === "childNodes") continue;
      try {
        const child = root[key];
        if (isObject(child) && patchGraph(child, visited, depth + 1)) changed = true;
      } catch {}
    }
    return changed;
  }

  function patchStatsigClient(client) {
    if (!isObject(client) || typeof client.getDynamicConfig !== "function") return;
    if (!client.__zhudaModelConfigPatch) {
      const original = client.getDynamicConfig.bind(client);
      client.getDynamicConfig = function(name, options) {
        const config = original(name, options);
        try {
          if (isObject(config && config.value)) {
            const available = Array.isArray(config.value.available_models) ? config.value.available_models : [];
            for (const model of modelNames()) {
              if (!available.includes(model)) available.push(model);
            }
            config.value.available_models = available;
            config.value.default_model = window[rootKey].defaultModel || available[0] || config.value.default_model;
          }
        } catch {}
        return config;
      };
      client.__zhudaModelConfigPatch = true;
    }
  }

  function patchStatsig() {
    const statsig = window.__STATSIG__ || globalThis.__STATSIG__;
    if (!isObject(statsig)) return;
    const clients = [statsig.firstInstance];
    try {
      if (typeof statsig.instance === "function") clients.push(statsig.instance());
    } catch {}
    if (isObject(statsig.instances)) clients.push(...Object.values(statsig.instances));
    for (const client of clients) patchStatsigClient(client);
  }

  function reactKeys(node) {
    return Object.keys(node || {}).filter((key) =>
      key.startsWith("__reactFiber") ||
      key.startsWith("__reactInternalInstance") ||
      key.startsWith("__reactProps")
    );
  }

  function patchReactState() {
    const nodes = [document.body]
      .concat(Array.from(document.querySelectorAll("button,[role='menu'],[role='dialog'],[data-radix-popper-content-wrapper]")))
      .filter(Boolean)
      .slice(0, 260);
    let changed = false;
    for (const node of nodes) {
      for (const key of reactKeys(node)) {
        if (patchGraph(node[key], new WeakSet(), 0)) changed = true;
      }
    }
    return changed;
  }

  function textLooksExactlyLikeLegacyModel(text) {
    return isLegacyModelName(normalizeModelName(text));
  }

  function pruneLegacyModelDom() {
    const selectors = [
      "[role='menuitem']",
      "[role='menuitemradio']",
      "[role='option']",
      "[data-radix-collection-item]",
      "[cmdk-item]",
      "button"
    ].join(",");
    let removed = 0;
    for (const node of Array.from(document.querySelectorAll(selectors))) {
      const text = String(node.innerText || node.textContent || "").trim();
      if (!text || text.length > 80) continue;
      if (!textLooksExactlyLikeLegacyModel(text)) continue;
      node.setAttribute("aria-hidden", "true");
      node.setAttribute("data-zhuda-hidden-legacy-model", "true");
      node.style.display = "none";
      removed += 1;
    }
    return removed;
  }

  function patchMcpMessage(data) {
    try {
      if (!isObject(data)) return false;
      return patchGraph(data, new WeakSet(), 0);
    } catch {
      return false;
    }
  }

  if (!window.__zhudaModelResponsePatchInstalled) {
    window.__zhudaModelResponsePatchInstalled = true;
    const originalJson = Response.prototype.json;
    Response.prototype.json = async function(...args) {
      const payload = await originalJson.apply(this, args);
      try { patchGraph(payload, new WeakSet(), 0); } catch {}
      return payload;
    };

    const originalDispatch = window.dispatchEvent;
    window.dispatchEvent = function(event) {
      try {
        const request = event && event.detail && event.detail.request;
        if (event && event.type === "codex-message-from-view" && request && /model\/list|list-models-for-host/.test(String(request.method || ""))) {
          request.params = Object.assign({}, request.params || {}, { includeHidden: true });
        }
        if (event && event.type === "message") patchMcpMessage(event.data);
      } catch {}
      return originalDispatch.apply(this, arguments);
    };

    window.addEventListener("message", (event) => patchMcpMessage(event && event.data), true);
    document.addEventListener("click", () => setTimeout(() => window.__zhudaPatchModels && window.__zhudaPatchModels(), 40), true);
  }

  window.__zhudaPatchModels = function() {
    try { patchStatsig(); } catch {}
    try { patchReactState(); } catch {}
    try { patchGraph(window, new WeakSet(), 0); } catch {}
    try { pruneLegacyModelDom(); } catch {}
    return modelNames();
  };

  window.__zhudaPatchModels();
  if (!window.__zhudaModelPatchTimer) {
    window.__zhudaModelPatchTimer = setInterval(() => {
      if (document && !document.hidden) window.__zhudaPatchModels();
    }, 700);
  }
  if (!window.__zhudaModelPatchObserver && window.MutationObserver) {
    window.__zhudaModelPatchObserver = new MutationObserver(() => {
      try { window.__zhudaPatchModels && window.__zhudaPatchModels(); } catch {}
    });
    window.__zhudaModelPatchObserver.observe(document.documentElement || document.body, {
      childList: true,
      subtree: true
    });
  }
  return { ok: true, models: modelNames(), defaultModel: window[rootKey].defaultModel };
})();
'@
    return $script.Replace("__MODELS_JSON__", $modelsJson).Replace("__DEFAULT_JSON__", $defaultJson).Replace("__PROVIDER_JSON__", $providerJson)
}

$modelNames = @(Get-UniqueCsvItems $Models)
if ($modelNames.Count -eq 0) {
    Write-Output "no models to inject"
    exit 0
}
if (-not $DefaultModel) { $DefaultModel = [string]$modelNames[0] }
if (-not ($modelNames -contains $DefaultModel)) {
    $modelNames = @($DefaultModel) + $modelNames
}

$expression = New-InjectionExpression $modelNames $DefaultModel $ProviderName
$runForever = $DurationSeconds -le 0
$deadline = if ($runForever) { [DateTime]::MaxValue } else { [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $DurationSeconds)) }
$startedAt = [DateTime]::UtcNow
$lastSeenAt = $null
$lastLogAt = [DateTime]::MinValue
$lastMissLogAt = [DateTime]::MinValue
$preloadedTargets = @{}
$reloadedTargets = @{}
$seq = 1
$total = 0
while ($runForever -or [DateTime]::UtcNow -lt $deadline) {
    $now = [DateTime]::UtcNow
    $count = 0
    $targetCount = 0
    foreach ($target in (Get-DevToolsTargets $Port)) {
        $wsUrl = [string]$target.webSocketDebuggerUrl
        $type = [string]$target.type
        if (-not $wsUrl -or @("page", "webview", "other") -notcontains $type) { continue }
        $targetKey = [string]$target.id
        if (-not $targetKey) { $targetKey = $wsUrl }
        $targetCount += 1
        if ($Preload -and -not $preloadedTargets.ContainsKey($targetKey)) {
            try {
                Send-CdpPreload $wsUrl $expression $seq
                $preloadedTargets[$targetKey] = $true
                $seq += 1
            } catch {}
            if ($ReloadOnce -and @("page", "webview") -contains $type -and -not $reloadedTargets.ContainsKey($targetKey)) {
                $reloadedTargets[$targetKey] = $true
                try {
                    Send-CdpReload $wsUrl $seq
                    $seq += 1
                } catch {}
            }
        }
        try {
            Send-CdpEvaluate $wsUrl $expression $seq
            $count += 1
        } catch {}
        $seq += 1
    }
    if ($targetCount -gt 0) {
        $lastSeenAt = $now
    }
    if ($count -gt 0) {
        $shouldLog = ($total -eq 0) -or (($now - $lastLogAt).TotalSeconds -ge 30)
        $total += $count
        if ($shouldLog) {
            Write-Output ("injected models into {0} target(s): {1}" -f $count, ($modelNames -join ", "))
            $lastLogAt = $now
        }
    } elseif ($runForever) {
        $reference = if ($lastSeenAt) { $lastSeenAt } else { $startedAt }
        if (($now - $reference).TotalSeconds -ge [Math]::Max(60, $IdleExitSeconds)) {
            Write-Output ("no DevTools target for {0}s; stopping model injector" -f [Math]::Max(60, $IdleExitSeconds))
            break
        }
        if (($now - $lastMissLogAt).TotalSeconds -ge 60) {
            Write-Output ("waiting for DevTools target on port {0}" -f $Port)
            $lastMissLogAt = $now
        }
    }
    Start-Sleep -Milliseconds ([Math]::Max(250, $IntervalMilliseconds))
}
Write-Output ("done; injection attempts succeeded for {0} target(s)" -f $total)
