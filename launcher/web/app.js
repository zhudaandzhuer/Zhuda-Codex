const state = {
  manifest: null,
  selectedProviderId: null,
  selectedModels: {},
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

function defaultModelFor(provider) {
  const models = providerModels(provider);
  return provider?.default_model || models.find((model) => model.default)?.id || models[0]?.id || "";
}

function selectedModelFor(provider) {
  return state.selectedModels[provider.id] || defaultModelFor(provider);
}

function upstreamByModelId(provider, modelId) {
  const model = providerModels(provider).find((item) => item.id === modelId || item.upstream === modelId);
  return model?.upstream || modelId || "";
}

function modelLabel(model) {
  return `${model.label || model.id} (${model.upstream || model.id})`;
}

function ensureProviderState(provider) {
  if (!provider) return;
  if (!state.selectedModels[provider.id]) {
    state.selectedModels[provider.id] = defaultModelFor(provider);
  }
  if (!state.endpoints[provider.id] && providerEndpoints(provider).length) {
    state.endpoints[provider.id] = defaultEndpointFor(provider);
  }
}

function renderProviderCard(provider) {
  ensureProviderState(provider);
  const active = provider.id === state.selectedProviderId;
  const disabled = !provider.enabled;
  const card = document.createElement("section");
  card.className = `provider-card ${active ? "active" : ""} ${disabled ? "disabled" : ""}`;
  const selectedModel = providerModels(provider).find((item) => item.id === selectedModelFor(provider));
  card.innerHTML = `
    <button class="provider-head" type="button">
      <span>
        <strong>${escapeHtml(provider.name)}</strong>
        <small>${provider.enabled ? `${providerModels(provider).length} 个模型 · ${escapeHtml(selectedModel?.label || selectedModelFor(provider))}` : "不可用"}</small>
      </span>
      <span class="provider-badge">${provider.enabled ? (active ? "已选" : "选择") : "停用"}</span>
    </button>
  `;
  card.querySelector(".provider-head").addEventListener("click", () => {
    if (disabled) return;
    state.selectedProviderId = provider.id;
    ensureProviderState(provider);
    renderProviders();
  });
  return card;
}

function providerDescription(provider) {
  if (!provider.enabled) return provider.note || "Reserved for later.";
  const endpoint = selectedEndpointOption(provider);
  const model = providerModels(provider).find((item) => item.id === selectedModelFor(provider));
  const parts = [
    `${providerModels(provider).length} 个上游模型可注入本次 Codex 会话。`,
  ];
  if (endpoint?.label) parts.push(`接口：${endpoint.label}`);
  if (model) parts.push(`默认：${model.label} / ${model.upstream || model.id}`);
  return parts.join(" ");
}

function renderProviderDetail() {
  const provider = selectedProvider();
  const box = $("providerDetail");
  box.innerHTML = "";
  if (!provider) return;
  ensureProviderState(provider);

  const card = document.createElement("section");
  card.className = `detail-card ${provider.enabled ? "" : "disabled"}`;
  card.innerHTML = `
    <div class="detail-head">
      <div>
        <p class="eyebrow">Selected provider</p>
        <h3>${escapeHtml(provider.name)}</h3>
      </div>
      <span class="provider-badge">${provider.enabled ? "可用" : "停用"}</span>
    </div>
    <p class="provider-note">${escapeHtml(providerDescription(provider))}</p>
  `;

  if (provider.enabled) {
    const endpointRow = renderEndpointRow(provider);
    if (endpointRow) card.appendChild(endpointRow);
    card.appendChild(renderModelPicker(provider));
    card.appendChild(renderKeyRow(provider));
    card.appendChild(renderActions(provider));
  }
  box.appendChild(card);
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
  const selected = selectedEndpointOption(provider);
  wrap.innerHTML = `<label for="endpointInput-${escapeHtml(provider.id)}">接口</label>`;
  wrap.appendChild(select);
  const hint = document.createElement("small");
  hint.className = "field-hint";
  hint.textContent = selected?.description || "";
  select.addEventListener("change", () => {
    state.endpoints[provider.id] = select.value;
    const next = selectedEndpointOption(provider);
    hint.textContent = next?.description || "";
    renderProviderDetail();
  });
  if (hint.textContent) wrap.appendChild(hint);
  return wrap;
}

function renderModelPicker(provider) {
  const wrap = document.createElement("div");
  wrap.className = "model-box";
  wrap.innerHTML = `<div class="panel-title">默认模型</div>`;

  const picker = document.createElement("label");
  picker.className = "field-row compact";
  picker.innerHTML = `<span>本次 Codex 默认使用</span>`;
  const select = document.createElement("select");
  select.id = `modelInput-${provider.id}`;
  for (const model of providerModels(provider)) {
    const option = document.createElement("option");
    option.value = model.id;
    option.textContent = modelLabel(model);
    select.appendChild(option);
  }
  select.value = selectedModelFor(provider);
  select.addEventListener("change", () => {
    state.selectedModels[provider.id] = select.value;
    renderProviders();
  });
  picker.appendChild(select);
  wrap.appendChild(picker);

  const list = document.createElement("div");
  list.className = "real-model-list";
  for (const model of providerModels(provider)) {
    const item = document.createElement("button");
    item.type = "button";
    item.className = `real-model-chip ${model.id === selectedModelFor(provider) ? "active" : ""}`;
    item.textContent = model.upstream || model.id;
    item.addEventListener("click", () => {
      state.selectedModels[provider.id] = model.id;
      renderProviders();
    });
    list.appendChild(item);
  }
  wrap.appendChild(list);
  return wrap;
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
  `;
  wrap.querySelector(".primary-button").addEventListener("click", () => launch(provider));
  return wrap;
}

function renderProviders() {
  const box = $("providerList");
  box.innerHTML = "";
  for (const provider of providers()) {
    box.appendChild(renderProviderCard(provider));
  }
  renderProviderDetail();
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
  if (!apiKey) return setResult("请贴上这次要注入的 API key。", "bad");
  state.launching = true;
  setResult("正在注入并启动...", "");
  try {
    const data = await api("/api/launch", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        provider_id: provider.id,
        endpoint_id: selectedEndpointFor(provider),
        model_id: selectedModelFor(provider),
        api_key: apiKey,
      }),
    });
    const input = document.getElementById(`apiKeyInput-${provider.id}`);
    if (input) input.value = "";
    setResult(data.message || "Zhuda-Codex 已启动。", "ok");
    if (data.launcherWillExit) {
      if (state.statusTimer) window.clearInterval(state.statusTimer);
      setStatus("Codex 已启动，可以关闭此页", "ok");
      $("logBox").textContent = `${data.message || "Zhuda-Codex 已启动。"}\n\n已尝试自动关闭 Launcher；如果浏览器阻挡关闭，直接关闭此页即可。Codex 和 adapter 会继续运行。`;
      window.setTimeout(() => {
        window.open("", "_self");
        window.close();
      }, Number(data.shutdownDelaySeconds || 1) * 1000);
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
$("stopButton").addEventListener("click", stopAdapter);

loadManifest()
  .then(refreshStatus)
  .catch((error) => {
    setStatus(error.message, "bad");
    $("logBox").textContent = error.stack || error.message;
  });

state.statusTimer = setInterval(refreshStatus, 5000);
