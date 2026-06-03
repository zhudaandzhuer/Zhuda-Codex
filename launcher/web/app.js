const state = {
  manifest: null,
  selectedProviderId: null,
  mappings: {},
  endpoints: {},
  launching: false,
  statusTimer: null,
};

const $ = (id) => document.getElementById(id);

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

async function api(path, options = {}) {
  const res = await fetch(path, options);
  const text = await res.text();
  let data = {};
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = { message: text };
    }
  }
  if (!res.ok) {
    throw new Error(data.error || data.message || `HTTP ${res.status}`);
  }
  return data;
}

function providers() {
  return state.manifest?.providers || [];
}

function codexModels() {
  return state.manifest?.codex_models || [];
}

function selectedProvider() {
  return providers().find((p) => p.id === state.selectedProviderId) || providers()[0];
}

function providerModels(provider) {
  return provider?.upstream_models || provider?.models || [];
}

function providerEndpoints(provider) {
  return provider?.endpoint_options || [];
}

function defaultEndpointFor(provider) {
  return provider?.default_endpoint || providerEndpoints(provider)[0]?.id || "";
}

function selectedEndpointFor(provider) {
  return state.endpoints[provider.id] || defaultEndpointFor(provider);
}

function selectedEndpointOption(provider) {
  const selected = selectedEndpointFor(provider);
  return providerEndpoints(provider).find((item) => item.id === selected) || providerEndpoints(provider)[0] || null;
}

function defaultsFor(provider) {
  const defaults = provider?.default_mappings || {};
  const models = providerModels(provider);
  const first = models[0]?.id || "";
  const result = {};
  for (const codex of codexModels()) {
    result[codex.id] = defaults[codex.id] || first;
  }
  return result;
}

function ensureProviderState(provider) {
  if (!provider) return;
  if (!state.mappings[provider.id]) {
    state.mappings[provider.id] = defaultsFor(provider);
  }
  if (!state.endpoints[provider.id] && providerEndpoints(provider).length) {
    state.endpoints[provider.id] = defaultEndpointFor(provider);
  }
}

function upstreamByModelId(provider, modelId) {
  const model = providerModels(provider).find((item) => item.id === modelId || item.upstream === modelId);
  return model?.upstream || modelId || "";
}

function renderProviderCard(provider) {
  ensureProviderState(provider);
  const active = provider.id === state.selectedProviderId;
  const disabled = !provider.enabled;
  const card = document.createElement("section");
  card.className = `provider-card ${active ? "active" : ""} ${disabled ? "disabled" : ""}`;
  card.innerHTML = `
    <button class="provider-head" type="button">
      <span>
        <strong>${escapeHtml(provider.name)}</strong>
        <small>${provider.enabled ? `${providerModels(provider).length} 個模型` : "不可用"}</small>
      </span>
      <span class="provider-badge">${provider.enabled ? (active ? "已選" : "選擇") : "停用"}</span>
    </button>
    <div class="provider-body"></div>
  `;
  card.querySelector(".provider-head").addEventListener("click", () => {
    if (disabled) return;
    state.selectedProviderId = provider.id;
    ensureProviderState(provider);
    renderProviders();
  });
  const body = card.querySelector(".provider-body");
  if (active && provider.enabled) {
    const endpointRow = renderEndpointRow(provider);
    if (endpointRow) body.appendChild(endpointRow);
    body.appendChild(renderMappingTable(provider));
    body.appendChild(renderKeyRow(provider));
    body.appendChild(renderActions(provider));
  } else if (active && !provider.enabled) {
    body.innerHTML = `<p class="provider-note">${escapeHtml(provider.note || "Reserved for later.")}</p>`;
  }
  return card;
}

function renderEndpointRow(provider) {
  const options = providerEndpoints(provider);
  if (!options.length) return null;
  const wrap = document.createElement("div");
  wrap.className = "field-row";
  const select = document.createElement("select");
  select.id = `endpointInput-${provider.id}`;
  for (const endpoint of options) {
    const option = document.createElement("option");
    option.value = endpoint.id;
    option.textContent = endpoint.label || endpoint.id;
    select.appendChild(option);
  }
  select.value = selectedEndpointFor(provider);
  select.addEventListener("change", () => {
    state.endpoints[provider.id] = select.value;
    renderSummary(provider);
  });
  const selected = selectedEndpointOption(provider);
  wrap.innerHTML = `<label for="endpointInput-${escapeHtml(provider.id)}">MiMo 接口</label>`;
  wrap.appendChild(select);
  const hint = document.createElement("small");
  hint.className = "field-hint";
  hint.id = `endpointHint-${provider.id}`;
  hint.textContent = selected?.description || "";
  select.addEventListener("change", () => {
    const next = selectedEndpointOption(provider);
    hint.textContent = next?.description || "";
  });
  if (hint.textContent) wrap.appendChild(hint);
  return wrap;
}

function renderMappingTable(provider) {
  const wrap = document.createElement("div");
  wrap.className = "mapping-box";
  wrap.innerHTML = `<div class="panel-title">Codex 模型映射</div>`;
  const list = document.createElement("div");
  list.className = "mapping-list";
  const selectedMappings = state.mappings[provider.id] || {};
  for (const codex of codexModels()) {
    const row = document.createElement("label");
    row.className = "mapping-row";
    const select = document.createElement("select");
    select.dataset.codexId = codex.id;
    for (const model of providerModels(provider)) {
      const option = document.createElement("option");
      option.value = model.id;
      option.textContent = `${model.label} (${model.upstream})`;
      select.appendChild(option);
    }
    select.value = selectedMappings[codex.id] || providerModels(provider)[0]?.id || "";
    select.addEventListener("change", () => {
      state.mappings[provider.id][codex.id] = select.value;
      renderSummary(provider);
    });
    row.innerHTML = `<span><b>${escapeHtml(codex.label)}</b><em>${escapeHtml(codex.id)}</em></span>`;
    row.appendChild(select);
    list.appendChild(row);
  }
  wrap.appendChild(list);
  const summary = document.createElement("pre");
  summary.className = "mapping-summary";
  summary.id = `summary-${provider.id}`;
  wrap.appendChild(summary);
  setTimeout(() => renderSummary(provider), 0);
  return wrap;
}

function renderSummary(provider) {
  const summary = document.getElementById(`summary-${provider.id}`);
  if (!summary) return;
  const selectedMappings = state.mappings[provider.id] || {};
  summary.textContent = codexModels()
    .map((codex) => `${codex.id} -> ${upstreamByModelId(provider, selectedMappings[codex.id])}`)
    .join("\n");
  const endpoint = selectedEndpointOption(provider);
  if (endpoint?.label) {
    summary.textContent = `endpoint -> ${endpoint.label}\n${summary.textContent}`;
  }
}

function renderKeyRow(provider) {
  const wrap = document.createElement("div");
  wrap.className = "field-row";
  wrap.innerHTML = `
    <label for="apiKeyInput-${escapeHtml(provider.id)}">${escapeHtml(provider.api_key_label || "API key")}</label>
    <input id="apiKeyInput-${escapeHtml(provider.id)}" class="api-key-input" type="password" autocomplete="off" spellcheck="false" placeholder="${escapeHtml(provider.api_key_hint || "Paste API key")}">
  `;
  return wrap;
}

function renderActions(provider) {
  const wrap = document.createElement("div");
  wrap.className = "actions";
  wrap.innerHTML = `
    <button class="primary-button" type="button">激活 ${escapeHtml(provider.name)}</button>
    <button id="stopButton" class="secondary-button" type="button">停止 Adapter</button>
  `;
  wrap.querySelector(".primary-button").addEventListener("click", () => launch(provider));
  wrap.querySelector(".secondary-button").addEventListener("click", stopAdapter);
  return wrap;
}

function renderProviders() {
  const box = $("providerList");
  box.innerHTML = "";
  for (const provider of providers()) {
    box.appendChild(renderProviderCard(provider));
  }
}

function setResult(text, kind = "") {
  const box = $("resultBox");
  box.textContent = text;
  box.className = `result-box ${kind}`;
}

function setStatus(text, kind = "") {
  $("statusText").textContent = text;
  $("statusDot").className = `dot ${kind}`;
}

function formatStatus(data) {
  const lines = [];
  lines.push(`platform: ${data.platform || "-"}`);
  lines.push(`project: ${data.projectRoot || "-"}`);
  if (data.adapter) {
    lines.push(`adapter: ${data.adapter.ok ? "ready" : "not running"}`);
    if (data.adapter.provider) lines.push(`provider: ${data.adapter.provider}`);
    if (data.adapter.port) lines.push(`port: ${data.adapter.port}`);
    if (data.adapter.timeoutSeconds) lines.push(`timeout: ${data.adapter.timeoutSeconds}s`);
    if (data.adapter.modelCount) lines.push(`models: ${data.adapter.modelCount}`);
  }
  if (data.lastLaunch) lines.push(`last launch: ${data.lastLaunch}`);
  return lines.join("\n");
}

async function refreshStatus() {
  try {
    const data = await api("/api/status");
    setStatus(data.adapter?.ok ? "Adapter is ready" : "Launcher is ready", data.adapter?.ok ? "ok" : "");
    $("logBox").textContent = formatStatus(data);
  } catch (error) {
    setStatus(error.message, "bad");
    $("logBox").textContent = error.stack || error.message;
  }
}

async function loadManifest() {
  state.manifest = await api("/api/manifest");
  state.selectedProviderId = state.manifest.default_provider || state.manifest.providers?.[0]?.id || "";
  for (const provider of providers()) ensureProviderState(provider);
  renderProviders();
}

async function launch(provider) {
  const apiKey = document.getElementById(`apiKeyInput-${provider.id}`)?.value.trim() || "";
  if (!apiKey) return setResult("請貼上這次要注入的 API key。", "bad");
  state.launching = true;
  setResult("正在注入並啟動...", "");
  try {
    const data = await api("/api/launch", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        provider_id: provider.id,
        endpoint_id: selectedEndpointFor(provider),
        api_key: apiKey,
        mappings: state.mappings[provider.id] || defaultsFor(provider),
      }),
    });
    const input = document.getElementById(`apiKeyInput-${provider.id}`);
    if (input) input.value = "";
    setResult(data.message || "Zhuda-Codex 已啟動。", "ok");
    if (data.launcherWillExit) {
      if (state.statusTimer) window.clearInterval(state.statusTimer);
      setStatus("Codex 已啟動，Launcher 即將關閉", "ok");
      $("logBox").textContent = `${data.message || "Zhuda-Codex 已啟動。"}\n\n這個啟動頁會自動結束；Codex 和 adapter 會繼續運行。`;
    } else {
      await refreshStatus();
    }
  } catch (error) {
    setResult(error.message, "bad");
  } finally {
    state.launching = false;
  }
}

async function stopAdapter() {
  setResult("正在停止 adapter...", "");
  try {
    const data = await api("/api/stop", { method: "POST" });
    setResult(data.message || "Adapter stopped.", "ok");
    await refreshStatus();
  } catch (error) {
    setResult(error.message, "bad");
  }
}

$("refreshButton").addEventListener("click", refreshStatus);

loadManifest()
  .then(refreshStatus)
  .catch((error) => {
    setStatus(error.message, "bad");
    $("logBox").textContent = error.stack || error.message;
  });

state.statusTimer = setInterval(refreshStatus, 5000);
