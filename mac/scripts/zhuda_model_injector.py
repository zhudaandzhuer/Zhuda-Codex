#!/usr/bin/env python3
"""Inject Zhuda-Codex model names into the Codex Desktop renderer.

This is a dependency-free Chrome DevTools Protocol helper. It does not modify
Codex app files; it evaluates a small patch script in renderer pages while the
launcher session starts.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import struct
import time
import urllib.parse
import urllib.request
from typing import Any


def unique(values: list[str]) -> list[str]:
    out: list[str] = []
    seen = set()
    for value in values:
        value = value.strip()
        if value and value not in seen:
            out.append(value)
            seen.add(value)
    return out


def http_json(url: str, timeout: float = 1.0) -> Any:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8", errors="replace"))


def bracket_ipv6_host(host: str) -> str:
    if ":" in host and not host.startswith("["):
        return f"[{host}]"
    return host


def devtools_url(host: str, port: int, path: str) -> str:
    return f"http://{bracket_ipv6_host(host)}:{port}{path}"


def devtools_targets(port: int, hosts: list[str]) -> list[dict[str, Any]]:
    for host in hosts:
        for path in ("/json/list", "/json"):
            try:
                payload = http_json(devtools_url(host, port, path))
            except Exception:
                continue
            if isinstance(payload, list):
                return [item for item in payload if isinstance(item, dict)]
    return []


def websocket_send_json(ws_url: str, payload: dict[str, Any], timeout: float = 3.0) -> None:
    parsed = urllib.parse.urlparse(ws_url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 80
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    host_header = bracket_ipv6_host(host)

    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host_header}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    ).encode("ascii")

    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(request)
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response += chunk
        if b" 101 " not in response.split(b"\r\n", 1)[0]:
            raise RuntimeError(f"DevTools websocket handshake failed: {response[:120]!r}")
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        frame = bytearray([0x81])
        length = len(data)
        if length < 126:
            frame.append(0x80 | length)
        elif length < 65536:
            frame.append(0x80 | 126)
            frame.extend(struct.pack("!H", length))
        else:
            frame.append(0x80 | 127)
            frame.extend(struct.pack("!Q", length))
        mask = os.urandom(4)
        frame.extend(mask)
        frame.extend(byte ^ mask[index % 4] for index, byte in enumerate(data))
        sock.sendall(frame)
        try:
            sock.recv(4096)
        except Exception:
            pass


def injection_expression(models: list[str], default_model: str, provider_name: str) -> str:
    models_json = json.dumps(models, ensure_ascii=True)
    default_json = json.dumps(default_model or (models[0] if models else ""), ensure_ascii=True)
    provider_json = json.dumps(provider_name or "Zhuda-Codex", ensure_ascii=True)
    return f"""
(() => {{
  const catalog = {{
    models: {models_json},
    defaultModel: {default_json},
    providerName: {provider_json},
    installedAt: Date.now()
  }};
  const rootKey = "__zhudaCodexModelInjection";
  const previous = window[rootKey] || {{}};
  window[rootKey] = Object.assign(previous, catalog, {{
      version: "3",
    hits: (previous.hits || 0) + 1
  }});

  const legacyModelNames = new Set([
    "gpt-5.5",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.3-codex",
    "gpt-5.2",
    "zhuda-codex",
    "gemini-codex"
  ]);

  const effortObjects = ["minimal", "low", "medium", "high", "xhigh"].map((reasoningEffort) => ({{
    reasoningEffort,
    description: reasoningEffort + " effort"
  }}));

  function normalizeModelName(value) {{
    return String(value || "")
      .trim()
      .replace(/[\\u2010-\\u2015]/g, "-")
      .toLowerCase();
  }}

  function modelNames() {{
    const names = [window[rootKey].defaultModel].concat(window[rootKey].models || []);
    return Array.from(new Set(names.filter((name) => typeof name === "string" && name.trim())));
  }}

  function allowedModelSet() {{
    return new Set(modelNames().map(normalizeModelName));
  }}

  function isLegacyModelName(value) {{
    const normalized = normalizeModelName(value);
    if (!normalized || allowedModelSet().has(normalized)) return false;
    return legacyModelNames.has(normalized) || /^gpt-5(?:\\.|-)/.test(normalized);
  }}

  function modelKey(item) {{
    if (!isObject(item)) return "";
    return item.model || item.id || item.slug || item.name || item.label || item.title || item.displayName || item.display_name || "";
  }}

  function descriptor(name) {{
    return {{
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
      isDefault: name === window[rootKey].defaultModel,
      defaultReasoningEffort: "medium",
      default_reasoning_effort: "medium",
      supportedReasoningEfforts: effortObjects,
      supported_reasoning_efforts: effortObjects
    }};
  }}

  function isObject(value) {{
    return value && typeof value === "object";
  }}

  function patchStringArray(items) {{
    if (!Array.isArray(items) || !items.every((item) => typeof item === "string")) return false;
    let changed = false;
    for (let index = items.length - 1; index >= 0; index--) {{
      if (isLegacyModelName(items[index])) {{
        items.splice(index, 1);
        changed = true;
      }}
    }}
    for (const name of modelNames()) {{
      if (!items.includes(name)) {{
        items.push(name);
        changed = true;
      }}
    }}
    return changed;
  }}

  function patchModelObjectArray(items, allowEmpty) {{
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
    for (let index = items.length - 1; index >= 0; index--) {{
      if (isLegacyModelName(modelKey(items[index]))) {{
        items.splice(index, 1);
        changed = true;
      }}
    }}
    const known = new Set(items.map(modelKey).filter(Boolean));
    for (const item of items) {{
      const key = modelKey(item);
      if (modelNames().includes(key)) {{
        item.hidden = false;
        item.disabled = false;
        item.isAvailable = true;
        changed = true;
      }}
    }}
    for (const name of modelNames()) {{
      if (!known.has(name)) {{
        items.push(descriptor(name));
        changed = true;
      }}
    }}
    return changed;
  }}

  function addNamesToSet(value) {{
    if (!(value instanceof Set)) return false;
    let changed = false;
    for (const name of modelNames()) {{
      if (!value.has(name)) {{
        value.add(name);
        changed = true;
      }}
    }}
    return changed;
  }}

  function patchContainer(value) {{
    if (!isObject(value)) return false;
    let changed = false;
    if (patchStringArray(value.models)) changed = true;
    if (patchModelObjectArray(value.models, "defaultModel" in value || "availableModels" in value || "available_models" in value)) changed = true;
    for (const key of ["data", "result", "availableModels", "available_models", "modelList", "model_list"]) {{
      if (patchStringArray(value[key])) changed = true;
      if (patchModelObjectArray(value[key], key === "availableModels" || key === "available_models")) changed = true;
    }}
    for (const key of ["availableModels", "available_models"]) {{
      if (addNamesToSet(value[key])) changed = true;
    }}
    for (const key of ["hiddenModels", "hidden_models"]) {{
      if (Array.isArray(value[key])) {{
        const before = value[key].length;
        value[key] = value[key].filter((name) => !modelNames().includes(name) && !isLegacyModelName(name));
        if (value[key].length !== before) changed = true;
      }}
    }}
    if (typeof value.defaultModel === "string" && !modelNames().includes(value.defaultModel)) {{
      value.defaultModel = window[rootKey].defaultModel || modelNames()[0] || value.defaultModel;
      changed = true;
    }}
    if (typeof value.default_model === "string" && !modelNames().includes(value.default_model)) {{
      value.default_model = window[rootKey].defaultModel || modelNames()[0] || value.default_model;
      changed = true;
    }}
    return changed;
  }}

  function textLooksExactlyLikeLegacyModel(text) {{
    const normalized = normalizeModelName(text);
    return isLegacyModelName(normalized);
  }}

  function pruneLegacyModelDom() {{
    const selectors = [
      "[role='menuitem']",
      "[role='menuitemradio']",
      "[role='option']",
      "[data-radix-collection-item]",
      "[cmdk-item]",
      "button"
    ].join(",");
    let removed = 0;
    for (const node of Array.from(document.querySelectorAll(selectors))) {{
      const text = String(node.innerText || node.textContent || "").trim();
      if (!text || text.length > 80) continue;
      if (!textLooksExactlyLikeLegacyModel(text)) continue;
      node.setAttribute("aria-hidden", "true");
      node.setAttribute("data-zhuda-hidden-legacy-model", "true");
      node.style.display = "none";
      removed += 1;
    }}
    return removed;
  }}

  function patchGraph(root, visited, depth) {{
    if (!isObject(root) || visited.has(root) || depth > 5) return false;
    visited.add(root);
    let changed = patchContainer(root);
    if (root === window || root === document || root instanceof Element) return changed;
    for (const key of Object.keys(root)) {{
      if (key === "ownerDocument" || key === "parentNode" || key === "parentElement" || key === "children" || key === "childNodes") continue;
      try {{
        const child = root[key];
        if (isObject(child) && patchGraph(child, visited, depth + 1)) changed = true;
      }} catch {{}}
    }}
    return changed;
  }}

  function patchStatsigClient(client) {{
    if (!isObject(client) || typeof client.getDynamicConfig !== "function") return;
    if (!client.__zhudaModelConfigPatch) {{
      const original = client.getDynamicConfig.bind(client);
      client.getDynamicConfig = function(name, options) {{
        const config = original(name, options);
        try {{
          if (isObject(config && config.value)) {{
            const available = Array.isArray(config.value.available_models) ? config.value.available_models : [];
            for (const model of modelNames()) {{
              if (!available.includes(model)) available.push(model);
            }}
            config.value.available_models = available;
            config.value.default_model = window[rootKey].defaultModel || available[0] || config.value.default_model;
          }}
        }} catch {{}}
        return config;
      }};
      client.__zhudaModelConfigPatch = true;
    }}
  }}

  function patchStatsig() {{
    const statsig = window.__STATSIG__ || globalThis.__STATSIG__;
    if (!isObject(statsig)) return;
    const clients = [statsig.firstInstance];
    try {{
      if (typeof statsig.instance === "function") clients.push(statsig.instance());
    }} catch {{}}
    if (isObject(statsig.instances)) clients.push(...Object.values(statsig.instances));
    for (const client of clients) patchStatsigClient(client);
  }}

  function reactKeys(node) {{
    return Object.keys(node || {{}}).filter((key) =>
      key.startsWith("__reactFiber") ||
      key.startsWith("__reactInternalInstance") ||
      key.startsWith("__reactProps")
    );
  }}

  function patchReactState() {{
    const nodes = [document.body]
      .concat(Array.from(document.querySelectorAll("button,[role='menu'],[role='dialog'],[data-radix-popper-content-wrapper]")))
      .filter(Boolean)
      .slice(0, 260);
    let changed = false;
    for (const node of nodes) {{
      for (const key of reactKeys(node)) {{
        if (patchGraph(node[key], new WeakSet(), 0)) changed = true;
      }}
    }}
    return changed;
  }}

  function patchMcpMessage(data) {{
    try {{
      if (!isObject(data)) return false;
      return patchGraph(data, new WeakSet(), 0);
    }} catch {{
      return false;
    }}
  }}

  if (!window.__zhudaModelResponsePatchInstalled) {{
    window.__zhudaModelResponsePatchInstalled = true;
    const originalJson = Response.prototype.json;
    Response.prototype.json = async function(...args) {{
      const payload = await originalJson.apply(this, args);
      try {{ patchGraph(payload, new WeakSet(), 0); }} catch {{}}
      return payload;
    }};

    const originalDispatch = window.dispatchEvent;
    window.dispatchEvent = function(event) {{
      try {{
        const request = event && event.detail && event.detail.request;
        if (event && event.type === "codex-message-from-view" && request && /model\\/list|list-models-for-host/.test(String(request.method || ""))) {{
          request.params = Object.assign({{}}, request.params || {{}}, {{ includeHidden: true }});
        }}
        if (event && event.type === "message") patchMcpMessage(event.data);
      }} catch {{}}
      return originalDispatch.apply(this, arguments);
    }};

    window.addEventListener("message", (event) => patchMcpMessage(event && event.data), true);
    document.addEventListener("click", () => setTimeout(() => window.__zhudaPatchModels && window.__zhudaPatchModels(), 40), true);
  }}

  window.__zhudaPatchModels = function() {{
    try {{ patchStatsig(); }} catch {{}}
    try {{ patchReactState(); }} catch {{}}
    try {{ patchGraph(window, new WeakSet(), 0); }} catch {{}}
    try {{ pruneLegacyModelDom(); }} catch {{}}
    return modelNames();
  }};

  window.__zhudaPatchModels();
  if (!window.__zhudaModelPatchTimer) {{
    window.__zhudaModelPatchTimer = setInterval(() => {{
      if (document && !document.hidden) window.__zhudaPatchModels();
    }}, 700);
  }}
  if (!window.__zhudaModelPatchObserver && window.MutationObserver) {{
    window.__zhudaModelPatchObserver = new MutationObserver(() => {{
      try {{ window.__zhudaPatchModels && window.__zhudaPatchModels(); }} catch {{}}
    }});
    window.__zhudaModelPatchObserver.observe(document.documentElement || document.body, {{
      childList: true,
      subtree: true
    }});
  }}
  return {{ ok: true, models: modelNames(), defaultModel: window[rootKey].defaultModel }};
}})();
"""


def inject_once(port: int, hosts: list[str], expression: str, seq: int) -> int:
    count = 0
    for target in devtools_targets(port, hosts):
        ws_url = target.get("webSocketDebuggerUrl")
        target_type = str(target.get("type") or "")
        if not ws_url or target_type not in {"page", "webview", "other"}:
            continue
        payload = {
            "id": seq,
            "method": "Runtime.evaluate",
            "params": {
                "expression": expression,
                "awaitPromise": False,
                "returnByValue": True,
            },
        }
        try:
            websocket_send_json(ws_url, payload)
            count += 1
        except Exception:
            continue
    return count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--models", required=True)
    parser.add_argument("--default-model", default="")
    parser.add_argument("--provider-name", default="Zhuda-Codex")
    parser.add_argument("--duration", type=float, default=75.0)
    parser.add_argument("--interval", type=float, default=1.5)
    parser.add_argument("--host", action="append", default=[])
    args = parser.parse_args()

    hosts = unique(args.host or ["127.0.0.1", "::1", "localhost"])
    models = unique([item for item in args.models.split(",")])
    if not models:
        print("no models to inject", flush=True)
        return 0
    default_model = args.default_model.strip() or models[0]
    if default_model not in models:
        models.insert(0, default_model)
    expression = injection_expression(models, default_model, args.provider_name)

    deadline = time.monotonic() + max(1.0, args.duration)
    seq = 1
    injected = 0
    while time.monotonic() < deadline:
        count = inject_once(args.port, hosts, expression, seq)
        if count:
            injected += count
            print(f"injected models into {count} target(s): {', '.join(models)}", flush=True)
        seq += 1
        time.sleep(max(0.2, args.interval))
    print(f"done; injection attempts succeeded for {injected} target(s)", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
