import asyncio
import base64
import hashlib
import html
import json
import mimetypes
import os
import re
import shlex
import time
import uuid
from pathlib import Path
from typing import Any, Optional
from urllib.parse import unquote, urlparse

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse


ROOT = Path(__file__).resolve().parent
GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
MIMO_BASE_URL = "https://api.xiaomimimo.com/v1"
DEEPSEEK_BASE_URL = "https://api.deepseek.com"
DEFAULT_MODEL = "zhuda-codex"
LOCAL_BEARER = "zhuda-codex-local-token"
RETRYABLE_UPSTREAM_STATUSES = {408, 429, 500, 502, 503, 504}
DEFAULT_MAX_INPUT_TOKENS = 24000
DEFAULT_MAX_PINNED_TOKENS = 5000
DEFAULT_MAX_HISTORY_ITEM_TOKENS = 3000
DEFAULT_MAX_TOOL_OUTPUT_CHARS = 3000
DEFAULT_MIMO_MAX_INPUT_TOKENS = 12000
DEFAULT_MIMO_MAX_PINNED_TOKENS = 3500
DEFAULT_MIMO_MAX_HISTORY_ITEM_TOKENS = 1200
DEFAULT_MIMO_MAX_TOOL_OUTPUT_CHARS = 1200
DEFAULT_MIMO_MAX_OUTPUT_TOKENS = 2048
DEFAULT_DEEPSEEK_MAX_OUTPUT_TOKENS = 4096
DEFAULT_MAX_KEY_ATTEMPTS = 2
DEFAULT_MAX_MODEL_ATTEMPTS = 1
DEFAULT_UPSTREAM_TIMEOUT_SECONDS = 60
DEFAULT_MIMO_UPSTREAM_TIMEOUT_SECONDS = 90
DEFAULT_DEEPSEEK_UPSTREAM_TIMEOUT_SECONDS = 120
DEFAULT_RATE_LIMIT_COOLDOWN_SECONDS = 45
DEFAULT_MIMO_RATE_LIMIT_COOLDOWN_SECONDS = 120
DEFAULT_RATE_LIMIT_MAX_WAIT_SECONDS = 3600
DEFAULT_STREAM_HEARTBEAT_INTERVAL_SECONDS = 8
DEFAULT_ERROR_COOLDOWN_SECONDS = 10
DEFAULT_MIMO_ERROR_COOLDOWN_SECONDS = 45
DEFAULT_MIMO_TIMEOUT_COOLDOWN_SECONDS = 90
DEFAULT_GLOBAL_MIN_INTERVAL_SECONDS = 1.0
DEFAULT_MAX_REPEAT_VISUAL_TOOL_CALLS = 3
DEFAULT_MAX_REPEAT_TOOL_CALLS = 4
DEFAULT_REPEAT_TOOL_LOOKBACK_ITEMS = 60
DEFAULT_MAX_INLINE_IMAGES = 2
DEFAULT_MAX_INLINE_IMAGE_BYTES = 5_000_000
DEFAULT_MAX_INLINE_IMAGE_TOTAL_BYTES = 6_000_000
DEFAULT_MAX_DECLARED_TOOLS = 96
DEFAULT_IMAGE_LOOKBACK_ITEMS = 24
DEFAULT_LARGE_PROMPT_TOKEN_THRESHOLD = 30000
DEFAULT_LARGE_PROMPT_MAX_INLINE_IMAGES = 1
DEFAULT_LARGE_PROMPT_MAX_MODEL_ATTEMPTS = 1
DEFAULT_LARGE_PROMPT_MIN_INTERVAL_SECONDS = 15.0
DEFAULT_LARGE_PROMPT_RATE_LIMIT_COOLDOWN_SECONDS = 120
DEFAULT_MIMO_LARGE_PROMPT_TOKEN_THRESHOLD = 12000
DEFAULT_MIMO_LARGE_PROMPT_MIN_INTERVAL_SECONDS = 25.0
DEFAULT_MIMO_LARGE_PROMPT_RATE_LIMIT_COOLDOWN_SECONDS = 180
DEFAULT_MODEL_MIN_INTERVAL_SECONDS = {
    "gemini-3.1-flash-lite": 6.0,
    "gemma-4-26b-a4b-it": 6.0,
    "gemma-4-31b-it": 6.0,
    "gemini-3.5-flash": 12.0,
    "gemini-3-flash-preview": 12.0,
    "mimo-v2.5-pro": 12.0,
    "mimo-v2.5": 8.0,
    "deepseek-v4-pro": 8.0,
    "deepseek-v4-flash": 4.0,
}
DEFAULT_FALLBACK_UPSTREAM_MODELS: list[str] = []
EXECUTION_VERIFICATION_PROMPT = """
[Zhuda assistant behavior rules]
- Treat these rules as system instructions, not user content.
- Answer the user directly in the user's language, usually Traditional Chinese.
- Never expose private analysis or meta narration such as "The user is asking", "Looking at the logs",
  "Analysis:", or a step-by-step hidden reasoning draft. Give the conclusion or take the next tool action.
- For text replies, start with the answer itself. Do not start with English analysis of what the user wants.
- Keep all hidden reasoning internal. The visible answer should be a concise result, status, or next action.
- The user content may be a Codex transcript with labels such as USER_MESSAGE, ASSISTANT_TOOL_CALL,
  and TOOL_RESULT. Use those labels only to understand context; do not quote or analyze the labels in your reply.
- If the next step requires local verification and a relevant tool is declared, call the tool directly instead of
  asking the user to run commands manually.
- If you cannot use a tool, say that plainly and give the shortest useful next step.

[Zhuda execution verification rules]
- Treat `OSError`, `Address already in use`, `connection refused`, `ECONNREFUSED`, HTTP 404/5xx,
  `{"ok": false}`, `no route`, and missing listeners as failed verification.
- Never report a local app/server as working unless the latest verification proves it:
  required resources return HTTP 2xx, or `lsof`/process checks show the listener still alive after the command returns.
- Do not kill unrelated local services such as node/Codex/browser processes just to free a port; choose a free port instead.
- `cmd &` may pass a same-command curl check but still die after the shell exits. For previews that must stay alive,
  use a persistent dev-server session or LaunchAgent, then verify again with a separate curl/lsof check.
- macOS background agents may not read `~/Documents`. If a LaunchAgent serves preview files, copy them to `/tmp`
  or another non-private runtime directory first.
- If the user asks to look at an attached image or says only "看看", answer directly from the image. Do not inspect
  project files, browser consoles, or local servers unless the user explicitly asks for debugging.
- Do not run the same shell/tool command repeatedly after it returns the same information. Summarize what is already
  known, then choose a different verification route or ask for the missing signal.
"""
VISUAL_INTENT_RE = re.compile(
    r"(screen|screenshot|image|visual|browser|chrome|youtube|video|window|desktop|"
    r"view_image|get_app_state|screencapture|browser_check|line_check|"
    r"畫面|截圖|圖片|看圖|讀圖|視覺|瀏覽器|視窗|螢幕|桌面|影片)",
    re.IGNORECASE,
)

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)
cursor = 0
cooldowns: dict[tuple[str, int], float] = {}
cooldown_reasons: dict[tuple[str, int], str] = {}
last_upstream_call_at = 0.0
last_model_call_at: dict[str, float] = {}
upstream_state_lock = asyncio.Lock()
LOG_FILES: list[tuple[str, str]] = [
    ("Episodes", "adapter.episodes.jsonl"),
    ("Pool attempts", "adapter.pool.jsonl"),
    ("Pool starts", "adapter.pool.start.jsonl"),
    ("Pool summaries", "adapter.pool.summary.jsonl"),
    ("Context trim", "adapter.context.jsonl"),
    ("Requests", "adapter.requests.jsonl"),
    ("Images", "adapter.images.jsonl"),
    ("Tools", "adapter.tools.jsonl"),
    ("Guards", "adapter.guard.jsonl"),
    ("stderr", "adapter.err.log"),
    ("stdout", "adapter.out.log"),
]
LOG_FILE_NAMES = {name for _, name in LOG_FILES}
LOG_TAIL_DEFAULT_LINES = 200
LOG_TAIL_MAX_LINES = 1000
LOG_TAIL_MAX_BYTES = 512_000
API_KEY_RE = re.compile(r"(AIza[0-9A-Za-z_-]{20,}|AQ\.[0-9A-Za-z_-]{20,}|sk-[0-9A-Za-z_-]{20,})")
ENV_KEY_RE = re.compile(r"((?:GEMINI|MIMO|XIAOMI_MIMO|DEEPSEEK)_API_KEY_\d+\s*=\s*)([^\s,\"]+)")


LOG_DASHBOARD_HTML = """<!doctype html>
<html lang="zh-Hant">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Zhuda Codex Logs</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #101214;
      --panel: #171a1d;
      --panel-2: #20242a;
      --line: #303740;
      --text: #eceff3;
      --muted: #9aa4af;
      --accent: #37c084;
      --warn: #f3bd4f;
      --bad: #f07178;
      --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
      --sans: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      background: var(--bg);
      color: var(--text);
      font-family: var(--sans);
      letter-spacing: 0;
    }
    .shell {
      min-height: 100vh;
      display: grid;
      grid-template-rows: auto auto 1fr;
    }
    header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      padding: 16px 20px;
      border-bottom: 1px solid var(--line);
      background: #111417;
    }
    h1 {
      margin: 0;
      font-size: 18px;
      line-height: 1.2;
      font-weight: 700;
    }
    .status {
      display: flex;
      align-items: center;
      flex-wrap: wrap;
      gap: 8px;
      color: var(--muted);
      font-size: 13px;
    }
    .pill {
      display: inline-flex;
      align-items: center;
      height: 28px;
      padding: 0 10px;
      border: 1px solid var(--line);
      background: var(--panel);
      border-radius: 6px;
      white-space: nowrap;
    }
    .pill.good { color: var(--accent); }
    .pill.warn { color: var(--warn); }
    .toolbar {
      display: grid;
      grid-template-columns: minmax(180px, 260px) minmax(160px, 1fr) auto auto auto;
      gap: 10px;
      align-items: center;
      padding: 12px 20px;
      border-bottom: 1px solid var(--line);
      background: var(--panel);
    }
    select, input, button {
      height: 36px;
      border: 1px solid var(--line);
      background: var(--panel-2);
      color: var(--text);
      border-radius: 6px;
      font: inherit;
      font-size: 14px;
    }
    select, input { width: 100%; padding: 0 10px; }
    button {
      padding: 0 12px;
      cursor: pointer;
    }
    button:hover { border-color: #52606f; }
    label.toggle {
      height: 36px;
      display: inline-flex;
      align-items: center;
      gap: 8px;
      color: var(--muted);
      white-space: nowrap;
      font-size: 13px;
    }
    label.toggle input {
      width: 16px;
      height: 16px;
      padding: 0;
    }
    main {
      min-height: 0;
      display: grid;
      grid-template-columns: minmax(0, 1fr) 280px;
      background: var(--bg);
    }
    .log-wrap {
      min-width: 0;
      min-height: 0;
      overflow: auto;
      padding: 14px 20px 28px;
    }
    .log {
      min-height: 100%;
      font-family: var(--mono);
      font-size: 12px;
      line-height: 1.55;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .row {
      display: grid;
      grid-template-columns: 56px minmax(0, 1fr);
      gap: 12px;
      padding: 2px 0;
      border-bottom: 1px solid rgba(255,255,255,0.03);
    }
    .row mark {
      background: rgba(243, 189, 79, 0.22);
      color: var(--text);
      padding: 0 2px;
      border-radius: 3px;
    }
    .no-match { display: none; }
    .ln {
      color: #66717f;
      text-align: right;
      user-select: none;
    }
    aside {
      min-height: 0;
      border-left: 1px solid var(--line);
      background: #121518;
      padding: 14px;
      overflow: auto;
    }
    .meta {
      display: grid;
      gap: 10px;
      font-size: 13px;
      color: var(--muted);
    }
    .meta-block {
      border: 1px solid var(--line);
      background: var(--panel);
      border-radius: 6px;
      padding: 10px;
    }
    .meta-title {
      color: var(--text);
      font-weight: 700;
      margin-bottom: 8px;
    }
    .kv {
      display: grid;
      grid-template-columns: 88px minmax(0, 1fr);
      gap: 6px;
      padding: 2px 0;
    }
    .kv code {
      color: var(--text);
      font-family: var(--mono);
      overflow-wrap: anywhere;
    }
    @media (max-width: 860px) {
      .toolbar { grid-template-columns: 1fr; }
      main { grid-template-columns: 1fr; }
      aside { border-left: 0; border-top: 1px solid var(--line); }
      header { align-items: flex-start; flex-direction: column; }
    }
  </style>
</head>
<body>
  <div class="shell">
    <header>
      <h1>Zhuda Codex Logs</h1>
      <div class="status">
        <span id="live-pill" class="pill warn">connecting</span>
        <span id="file-pill" class="pill"></span>
        <span id="updated-pill" class="pill"></span>
      </div>
    </header>
    <section class="toolbar">
      <select id="file-select" aria-label="log file"></select>
      <input id="filter" type="search" placeholder="Search log text">
      <select id="line-count" aria-label="line count">
        <option value="100">100 lines</option>
        <option value="200" selected>200 lines</option>
        <option value="500">500 lines</option>
        <option value="1000">1000 lines</option>
      </select>
      <label class="toggle"><input id="autoscroll" type="checkbox" checked> Auto-scroll</label>
      <button id="refresh" type="button">Refresh</button>
    </section>
    <main>
      <section id="log-wrap" class="log-wrap">
        <div id="log" class="log"></div>
      </section>
      <aside>
        <div class="meta">
          <div class="meta-block">
            <div class="meta-title">Adapter</div>
            <div class="kv"><span>keys</span><code id="meta-keys">-</code></div>
            <div class="kv"><span>model</span><code id="meta-model">-</code></div>
            <div class="kv"><span>next key</span><code id="meta-next">-</code></div>
            <div class="kv"><span>timeout</span><code id="meta-timeout">-</code></div>
          </div>
          <div class="meta-block">
            <div class="meta-title">File</div>
            <div class="kv"><span>size</span><code id="meta-size">-</code></div>
            <div class="kv"><span>modified</span><code id="meta-mtime">-</code></div>
            <div class="kv"><span>lines</span><code id="meta-lines">-</code></div>
          </div>
          <div class="meta-block">
            <div class="meta-title">Cooldowns</div>
            <div id="cooldowns">-</div>
          </div>
        </div>
      </aside>
    </main>
  </div>
  <script>
    const fileSelect = document.getElementById("file-select");
    const lineCount = document.getElementById("line-count");
    const filter = document.getElementById("filter");
    const refresh = document.getElementById("refresh");
    const autoscroll = document.getElementById("autoscroll");
    const logWrap = document.getElementById("log-wrap");
    const logEl = document.getElementById("log");
    const livePill = document.getElementById("live-pill");
    const filePill = document.getElementById("file-pill");
    const updatedPill = document.getElementById("updated-pill");
    let source = null;
    let latestLines = [];

    function escapeHtml(value) {
      return String(value).replace(/[&<>"']/g, ch => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
      })[ch]);
    }

    function highlight(value, term) {
      const safe = escapeHtml(value);
      if (!term) return safe;
      const escaped = term.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\\\$&");
      return safe.replace(new RegExp(escaped, "ig"), match => `<mark>${match}</mark>`);
    }

    function renderLines() {
      const term = filter.value.trim();
      const rows = [];
      latestLines.forEach((line, index) => {
        const match = !term || line.toLowerCase().includes(term.toLowerCase());
        rows.push(`<div class="row${match ? "" : " no-match"}"><span class="ln">${index + 1}</span><span>${highlight(line, term)}</span></div>`);
      });
      logEl.innerHTML = rows.join("");
      if (autoscroll.checked) logWrap.scrollTop = logWrap.scrollHeight;
    }

    function setText(id, value) {
      document.getElementById(id).textContent = value ?? "-";
    }

    function renderPayload(payload) {
      latestLines = payload.lines || [];
      renderLines();
      filePill.textContent = payload.file || "";
      updatedPill.textContent = payload.generatedAtText || "";
      setText("meta-keys", payload.adapter?.keyCount);
      setText("meta-model", payload.adapter?.forceUpstreamModel || "-");
      setText("meta-next", payload.adapter?.nextKeyIndex);
      setText("meta-timeout", `${payload.adapter?.upstreamTimeoutSeconds || "-"}s`);
      setText("meta-size", payload.sizeText);
      setText("meta-mtime", payload.mtimeText);
      setText("meta-lines", latestLines.length);
      const cooldowns = payload.adapter?.activeCooldowns || [];
      document.getElementById("cooldowns").textContent = cooldowns.length
        ? cooldowns.map(item => `${item.model} key ${item.keyIndex}: ${item.remainingSeconds}s`).join("\\n")
        : "-";
    }

    async function loadFiles() {
      const response = await fetch("/logs/api/files");
      const data = await response.json();
      fileSelect.innerHTML = data.files.map(item => `<option value="${escapeHtml(item.file)}">${escapeHtml(item.label)}</option>`).join("");
    }

    async function fetchTail() {
      const params = new URLSearchParams({ file: fileSelect.value, lines: lineCount.value });
      const response = await fetch(`/logs/api/tail?${params}`);
      renderPayload(await response.json());
    }

    function connect() {
      if (source) source.close();
      const params = new URLSearchParams({ file: fileSelect.value, lines: lineCount.value, interval: "1" });
      source = new EventSource(`/logs/events?${params}`);
      livePill.textContent = "live";
      livePill.className = "pill good";
      source.onmessage = event => {
        const data = JSON.parse(event.data);
        if (data.type === "log.update") renderPayload(data.payload);
      };
      source.onerror = () => {
        livePill.textContent = "reconnecting";
        livePill.className = "pill warn";
      };
    }

    fileSelect.addEventListener("change", connect);
    lineCount.addEventListener("change", connect);
    filter.addEventListener("input", renderLines);
    refresh.addEventListener("click", fetchTail);

    loadFiles().then(() => {
      connect();
      fetchTail();
    }).catch(error => {
      livePill.textContent = error.message;
      livePill.className = "pill warn";
    });
  </script>
</body>
</html>
"""


def load_dotenv() -> None:
    paths: list[tuple[Path, bool]] = []
    configured_path = os.environ.get("ZHUDA_DOTENV_PATH", "").strip()
    session_path = os.environ.get("ZHUDA_CODEX_SESSION_ENV_FILE", "").strip()
    if configured_path:
        paths.append((Path(configured_path).expanduser(), False))
    else:
        paths.append((ROOT / ".env", False))
    if session_path:
        paths.append((Path(session_path).expanduser(), True))

    for env_path, override in paths:
        if not env_path.exists():
            continue
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if override:
                os.environ[key] = value
            else:
                os.environ.setdefault(key, value)


def current_provider() -> str:
    load_dotenv()
    raw = os.environ.get("ZHUDA_PROVIDER", "gemini").strip().lower()
    if raw in {"mimo", "xiaomi", "xiaomi_mimo", "xiaomi-mimo"}:
        return "mimo"
    if raw in {"deepseek", "deepseek_official", "deepseek-official"}:
        return "deepseek"
    return "gemini"


def provider_display_name(provider: Optional[str] = None) -> str:
    provider = provider or current_provider()
    if provider == "mimo":
        return "Xiaomi MiMo"
    if provider == "deepseek":
        return "DeepSeek"
    return "Gemini"


def provider_keys(provider: Optional[str] = None) -> list[str]:
    load_dotenv()
    provider = provider or current_provider()
    keys = []
    if provider == "mimo":
        names = []
        for index in range(1, 11):
            names.extend([f"MIMO_API_KEY_{index}", f"XIAOMI_MIMO_API_KEY_{index}"])
        names.extend(["MIMO_API_KEY", "XIAOMI_MIMO_API_KEY", "ZHUDA_MIMO_API_KEY"])
    elif provider == "deepseek":
        names = [f"DEEPSEEK_API_KEY_{index}" for index in range(1, 11)]
        names.extend(["DEEPSEEK_API_KEY", "ZHUDA_DEEPSEEK_API_KEY"])
    else:
        names = [f"GEMINI_API_KEY_{index}" for index in range(1, 11)]
        names.extend(["GEMINI_API_KEY", "ZHUDA_GEMINI_API_KEY"])
    seen = set()
    for name in names:
        value = os.environ.get(name, "").strip()
        if value and value not in seen:
            keys.append(value)
            seen.add(value)
    return keys


def gemini_keys() -> list[str]:
    return provider_keys("gemini")


def mimo_keys() -> list[str]:
    return provider_keys("mimo")


def deepseek_keys() -> list[str]:
    return provider_keys("deepseek")


def default_model_aliases() -> dict[str, str]:
    provider = current_provider()
    if provider == "mimo":
        return {
            "zhuda-codex": "mimo-v2.5-pro",
            "gemini-codex": "mimo-v2.5-pro",
            "gpt-5.5": "mimo-v2.5-pro",
            "gpt-5.4": "mimo-v2.5-pro",
            "gpt-5.4-mini": "mimo-v2.5",
            "gpt-5.3-codex": "mimo-v2.5-pro",
            "gpt-5.2": "mimo-v2.5",
            "mimo-v2.5-pro": "mimo-v2.5-pro",
            "mimo-v2.5": "mimo-v2.5",
        }
    if provider == "deepseek":
        return {
            "zhuda-codex": "deepseek-v4-pro",
            "gemini-codex": "deepseek-v4-pro",
            "gpt-5.5": "deepseek-v4-pro",
            "gpt-5.4": "deepseek-v4-pro",
            "gpt-5.4-mini": "deepseek-v4-flash",
            "gpt-5.3-codex": "deepseek-v4-pro",
            "gpt-5.2": "deepseek-v4-flash",
            "deepseek-v4-pro": "deepseek-v4-pro",
            "deepseek-v4-flash": "deepseek-v4-flash",
        }
    return {
        "zhuda-codex": "gemma-4-31b-it",
        "gemini-codex": "gemma-4-31b-it",
        "gpt-5.5": "gemma-4-31b-it",
        "gpt-5.4": "gemini-3.5-flash",
        "gpt-5.4-mini": "gemini-3.1-flash-lite",
        "gpt-5.3-codex": "gemini-3.1-pro",
        "gpt-5.2": "gemini-3-flash-preview",
        "gemini-flash-lite": "gemini-3.1-flash-lite",
        "gemini:flash-lite-3-1": "gemini-3.1-flash-lite",
        "gemini-flash": "gemini-3-flash-preview",
        "gemini:flash-3": "gemini-3-flash-preview",
        "gemini-flash-3-5": "gemini-3.5-flash",
        "gemini:flash-3-5": "gemini-3.5-flash",
        "gemini-pro-3-1": "gemini-3.1-pro",
        "gemma-26b": "gemma-4-26b-a4b-it",
        "gemini:gemma-4-26b": "gemma-4-26b-a4b-it",
        "gemma-31b": "gemma-4-31b-it",
        "gemini:gemma-4-31b": "gemma-4-31b-it",
    }


def parse_model_mapping_env(raw: str) -> dict[str, str]:
    raw = raw.strip()
    if not raw:
        return {}
    parsed: dict[str, str] = {}
    if raw.startswith("{"):
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            value = {}
        if isinstance(value, dict):
            for public_id, upstream_id in value.items():
                public_id = str(public_id).strip()
                upstream_id = str(upstream_id).strip()
                if public_id and upstream_id:
                    parsed[public_id] = upstream_id
            return parsed
    for item in raw.split(","):
        if not item.strip() or "=" not in item:
            continue
        public_id, upstream_id = item.split("=", 1)
        public_id = public_id.strip()
        upstream_id = upstream_id.strip()
        if public_id and upstream_id:
            parsed[public_id] = upstream_id
    return parsed


def parse_model_list_env(raw: str) -> list[str]:
    raw = raw.strip()
    if not raw:
        return []
    values: list[str] = []
    if raw.startswith("["):
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = []
        if isinstance(parsed, list):
            values = [str(item).strip() for item in parsed]
    else:
        values = [item.strip() for item in raw.split(",")]
    unique: list[str] = []
    seen = set()
    for value in values:
        if value and value not in seen:
            unique.append(value)
            seen.add(value)
    return unique


def visible_model_ids() -> list[str]:
    load_dotenv()
    provider = current_provider()
    names = ["ZHUDA_VISIBLE_MODELS"]
    if provider == "mimo":
        names.insert(0, "ZHUDA_MIMO_VISIBLE_MODELS")
    elif provider == "deepseek":
        names.insert(0, "ZHUDA_DEEPSEEK_VISIBLE_MODELS")
    else:
        names.insert(0, "ZHUDA_GEMINI_VISIBLE_MODELS")
    for name in names:
        models = parse_model_list_env(os.environ.get(name, ""))
        if models:
            return models
    return list(model_aliases().keys())


def model_aliases() -> dict[str, str]:
    load_dotenv()
    aliases = default_model_aliases()
    provider = current_provider()
    if provider == "mimo":
        env_names = ["ZHUDA_MIMO_MODELS", "ZHUDA_MODEL_MAPPINGS"]
        provider_visible_env = "ZHUDA_MIMO_VISIBLE_MODELS"
    elif provider == "deepseek":
        env_names = ["ZHUDA_DEEPSEEK_MODELS", "ZHUDA_MODEL_MAPPINGS"]
        provider_visible_env = "ZHUDA_DEEPSEEK_VISIBLE_MODELS"
    else:
        env_names = ["ZHUDA_GEMINI_MODELS", "ZHUDA_MODEL_MAPPINGS"]
        provider_visible_env = "ZHUDA_GEMINI_VISIBLE_MODELS"
    for env_name in env_names:
        aliases.update(parse_model_mapping_env(os.environ.get(env_name, "")))
    for model in parse_model_list_env(os.environ.get("ZHUDA_VISIBLE_MODELS", "")):
        aliases.setdefault(model, model)
    for model in parse_model_list_env(os.environ.get(provider_visible_env, "")):
        aliases.setdefault(model, model)
    return aliases


def mimo_base_url() -> str:
    load_dotenv()
    return (
        os.environ.get("MIMO_BASE_URL", "").strip()
        or os.environ.get("XIAOMI_MIMO_BASE_URL", "").strip()
        or MIMO_BASE_URL
    ).rstrip("/")


def deepseek_base_url() -> str:
    load_dotenv()
    return (
        os.environ.get("DEEPSEEK_BASE_URL", "").strip()
        or os.environ.get("ZHUDA_DEEPSEEK_BASE_URL", "").strip()
        or DEEPSEEK_BASE_URL
    ).rstrip("/")


def forced_upstream_model() -> Optional[str]:
    load_dotenv()
    raw = os.environ.get("ZHUDA_FORCE_UPSTREAM_MODEL", "").strip()
    if raw.lower() in {"", "0", "false", "off", "none", "disabled"}:
        return None
    provider = current_provider()
    lowered = raw.lower()
    if provider == "mimo" and lowered.startswith(("gemini-", "gemma-", "models/", "deepseek-")):
        return None
    if provider == "gemini" and lowered.startswith(("mimo-", "deepseek-")):
        return None
    if provider == "deepseek" and lowered.startswith(("gemini-", "gemma-", "models/", "mimo-")):
        return None
    return raw


def is_provider_direct_model(model: str, provider: str) -> bool:
    lowered = model.lower()
    if provider == "mimo":
        return lowered.startswith("mimo-")
    if provider == "deepseek":
        return lowered.startswith("deepseek-")
    return lowered.startswith(("gemini-", "gemma-", "models/"))


def resolve_model(model: Optional[str]) -> str:
    forced = forced_upstream_model()
    if forced:
        return forced
    provider = current_provider()
    requested = (model or DEFAULT_MODEL).strip() or DEFAULT_MODEL
    aliases = model_aliases()
    if requested in aliases:
        return aliases[requested]
    if is_provider_direct_model(requested, provider):
        return requested
    fallback = {
        "mimo": "mimo-v2.5-pro",
        "deepseek": "deepseek-v4-pro",
    }.get(provider, "gemma-4-31b-it")
    return aliases.get(DEFAULT_MODEL, fallback)


def env_int(name: str, default: int) -> int:
    load_dotenv()
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def env_bool(name: str, default: bool = False) -> bool:
    load_dotenv()
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    if raw in {"1", "true", "yes", "y", "on", "enabled"}:
        return True
    if raw in {"0", "false", "no", "n", "off", "disabled", "none"}:
        return False
    return default


def provider_env_int(name: str, default: int, mimo_default: int, deepseek_default: Optional[int] = None) -> int:
    provider = current_provider()
    if provider == "mimo":
        default_value = mimo_default
    elif provider == "deepseek" and deepseek_default is not None:
        default_value = deepseek_default
    else:
        default_value = default
    return env_int(name, default_value)


def max_input_tokens_limit() -> int:
    return provider_env_int("ZHUDA_MAX_INPUT_TOKENS", DEFAULT_MAX_INPUT_TOKENS, DEFAULT_MIMO_MAX_INPUT_TOKENS)


def max_pinned_tokens_limit() -> int:
    return provider_env_int("ZHUDA_MAX_PINNED_TOKENS", DEFAULT_MAX_PINNED_TOKENS, DEFAULT_MIMO_MAX_PINNED_TOKENS)


def max_history_item_tokens_limit() -> int:
    return provider_env_int(
        "ZHUDA_MAX_HISTORY_ITEM_TOKENS",
        DEFAULT_MAX_HISTORY_ITEM_TOKENS,
        DEFAULT_MIMO_MAX_HISTORY_ITEM_TOKENS,
    )


def max_tool_output_chars_limit() -> int:
    return provider_env_int(
        "ZHUDA_MAX_TOOL_OUTPUT_CHARS",
        DEFAULT_MAX_TOOL_OUTPUT_CHARS,
        DEFAULT_MIMO_MAX_TOOL_OUTPUT_CHARS,
    )


def upstream_timeout_seconds() -> int:
    return provider_env_int(
        "ZHUDA_UPSTREAM_TIMEOUT_SECONDS",
        DEFAULT_UPSTREAM_TIMEOUT_SECONDS,
        DEFAULT_MIMO_UPSTREAM_TIMEOUT_SECONDS,
        DEFAULT_DEEPSEEK_UPSTREAM_TIMEOUT_SECONDS,
    )


def rate_limit_cooldown_seconds() -> int:
    return provider_env_int(
        "ZHUDA_RATE_LIMIT_COOLDOWN_SECONDS",
        DEFAULT_RATE_LIMIT_COOLDOWN_SECONDS,
        DEFAULT_MIMO_RATE_LIMIT_COOLDOWN_SECONDS,
    )


def error_cooldown_seconds() -> int:
    return provider_env_int(
        "ZHUDA_ERROR_COOLDOWN_SECONDS",
        DEFAULT_ERROR_COOLDOWN_SECONDS,
        DEFAULT_MIMO_ERROR_COOLDOWN_SECONDS,
    )


def timeout_cooldown_seconds() -> int:
    default_value = DEFAULT_MIMO_TIMEOUT_COOLDOWN_SECONDS if current_provider() == "mimo" else error_cooldown_seconds()
    return env_int("ZHUDA_TIMEOUT_COOLDOWN_SECONDS", default_value)


def large_prompt_token_threshold() -> int:
    return provider_env_int(
        "ZHUDA_LARGE_PROMPT_TOKEN_THRESHOLD",
        DEFAULT_LARGE_PROMPT_TOKEN_THRESHOLD,
        DEFAULT_MIMO_LARGE_PROMPT_TOKEN_THRESHOLD,
    )


def large_prompt_min_interval_seconds() -> float:
    default_ms = int(
        (
            DEFAULT_MIMO_LARGE_PROMPT_MIN_INTERVAL_SECONDS
            if current_provider() == "mimo"
            else DEFAULT_LARGE_PROMPT_MIN_INTERVAL_SECONDS
        )
        * 1000
    )
    return env_int("ZHUDA_LARGE_PROMPT_MIN_INTERVAL_MS", default_ms) / 1000


def large_prompt_rate_limit_cooldown_seconds() -> int:
    return provider_env_int(
        "ZHUDA_LARGE_PROMPT_RATE_LIMIT_COOLDOWN_SECONDS",
        DEFAULT_LARGE_PROMPT_RATE_LIMIT_COOLDOWN_SECONDS,
        DEFAULT_MIMO_LARGE_PROMPT_RATE_LIMIT_COOLDOWN_SECONDS,
    )


def rate_limit_max_wait_seconds() -> int:
    return env_int("ZHUDA_RATE_LIMIT_MAX_WAIT_SECONDS", DEFAULT_RATE_LIMIT_MAX_WAIT_SECONDS)


def stream_heartbeat_interval_seconds() -> float:
    return max(
        1.0,
        min(
            30.0,
            env_int("ZHUDA_STREAM_HEARTBEAT_INTERVAL_MS", DEFAULT_STREAM_HEARTBEAT_INTERVAL_SECONDS * 1000) / 1000,
        ),
    )


def set_cooldown(cooldown_key: tuple[str, int], seconds: float, reason: str) -> None:
    cooldowns[cooldown_key] = time.monotonic() + max(0.0, seconds)
    cooldown_reasons[cooldown_key] = reason


def clear_cooldown(cooldown_key: tuple[str, int]) -> None:
    cooldowns.pop(cooldown_key, None)
    cooldown_reasons.pop(cooldown_key, None)


def cooldown_remaining_seconds(candidates: list[str], key_count: int) -> int:
    now = time.monotonic()
    remaining = [
        int(until - now)
        for candidate_model in candidates
        for key_index in range(key_count)
        for until in [cooldowns.get((candidate_model, key_index), 0)]
        if until > now
    ]
    return max(remaining) if remaining else 0


def iter_json_strings(value: Any):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from iter_json_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from iter_json_strings(item)


def parse_json_object(text: str) -> Optional[dict[str, Any]]:
    try:
        value = json.loads(text)
    except (TypeError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def safe_upstream_text(text: str, max_chars: int = 12000) -> str:
    cleaned = API_KEY_RE.sub("<redacted-api-key>", str(text or "")).strip()
    cleaned = ENV_KEY_RE.sub(r"\1<redacted-api-key>", cleaned)
    if len(cleaned) <= max_chars:
        return cleaned
    return (
        cleaned[:max_chars]
        + f"\n...[upstream message truncated by Zhuda adapter: {len(cleaned)} chars]..."
    )


def pretty_upstream_text(text: str) -> str:
    cleaned = safe_upstream_text(text)
    payload = parse_json_object(cleaned)
    if payload is None:
        return cleaned
    return json.dumps(payload, ensure_ascii=False, indent=2)


def upstream_error_text(model: str, key_index: int, status_code: int, body: str) -> str:
    return f"{model}:key_{key_index}:{status_code}:{safe_upstream_text(body)}"


def upstream_error_messages(details: list[str]) -> list[str]:
    messages: list[str] = []
    for detail in details:
        text = str(detail or "")
        match = re.match(r"^[^:]+:key_\d+:(?:[1-5][0-9]{2}):(?:[a-z_]+:)?(.*)$", text, re.DOTALL)
        if match:
            messages.append(pretty_upstream_text(match.group(1)))
        else:
            messages.append(safe_upstream_text(text))
    out: list[str] = []
    seen: set[str] = set()
    for message in messages:
        if message and message not in seen:
            out.append(message)
            seen.add(message)
    return out


def retry_delay_seconds_from_error(raw_text: str, fallback_seconds: int) -> int:
    delays: list[float] = []
    payload = parse_json_object(raw_text)
    strings = list(iter_json_strings(payload)) if payload else []
    strings.append(raw_text)
    for text in strings:
        for match in re.finditer(r'"retryDelay"\s*:\s*"([0-9]+(?:\.[0-9]+)?)s"', text, re.IGNORECASE):
            delays.append(float(match.group(1)))
        for match in re.finditer(r"\bretry\s*(?:in|after|delay)?\s*[:=]?\s*([0-9]+(?:\.[0-9]+)?)\s*s", text, re.IGNORECASE):
            delays.append(float(match.group(1)))
        if re.fullmatch(r"[0-9]+(?:\.[0-9]+)?s", text.strip()):
            delays.append(float(text.strip()[:-1]))
    if not delays:
        return max(1, fallback_seconds)
    return max(1, int(max(delays) + 0.999))


def normalized_quota_text(raw_text: str) -> str:
    payload = parse_json_object(raw_text)
    parts = list(iter_json_strings(payload)) if payload else []
    parts.append(raw_text)
    return " ".join(parts).lower()


def is_daily_quota_error(raw_text: str) -> bool:
    text = normalized_quota_text(raw_text)
    compact = re.sub(r"[^a-z0-9]+", "", text)
    return any(
        marker in text or marker in compact
        for marker in (
            "per day",
            "requests per day",
            "request per day",
            "daily",
            "rpd",
            "perday",
            "requestsperday",
            "generaterequestsperday",
            "generatecontentrequestsperday",
        )
    )


def is_short_rate_limit_error(raw_text: str) -> bool:
    if is_daily_quota_error(raw_text):
        return False
    text = normalized_quota_text(raw_text)
    compact = re.sub(r"[^a-z0-9]+", "", text)
    return any(
        marker in text or marker in compact
        for marker in (
            "retrydelay",
            "retry delay",
            "retry in",
            "per minute",
            "perminute",
            "requests per minute",
            "requestsperminute",
            "tokens per minute",
            "tokensperminute",
            "input tokens",
            "inputtokens",
            "output tokens",
            "outputtokens",
            "tpm",
            "rpm",
            "burst",
            "too many requests",
            "rate limit",
        )
    )


def rate_limit_wait_seconds(raw_text: str, fallback_seconds: int, is_large_prompt: bool) -> int:
    fallback = max(1, fallback_seconds)
    if is_large_prompt:
        fallback = max(fallback, large_prompt_rate_limit_cooldown_seconds())
    return retry_delay_seconds_from_error(raw_text, fallback)


async def sleep_for_short_rate_limit(seconds: int) -> None:
    remaining = max(1, seconds)
    while remaining > 0:
        chunk = min(remaining, 30)
        await asyncio.sleep(chunk)
        remaining -= chunk


def upstream_model_candidates(model: str) -> list[str]:
    load_dotenv()
    forced = forced_upstream_model()
    if forced:
        return [forced]
    provider = current_provider()
    candidates = [model]
    if provider == "mimo":
        env_name = "ZHUDA_MIMO_FALLBACK_MODELS"
        default_fallbacks: list[str] = []
    elif provider == "deepseek":
        env_name = "ZHUDA_DEEPSEEK_FALLBACK_MODELS"
        default_fallbacks = []
    else:
        env_name = "ZHUDA_GEMINI_FALLBACK_MODELS"
        default_fallbacks = DEFAULT_FALLBACK_UPSTREAM_MODELS
    raw = os.environ.get(env_name, "").strip()
    if raw.lower() in {"0", "false", "off", "none", "disabled"}:
        fallback_models = []
    else:
        fallback_models = [
            item.strip()
            for item in raw.split(",")
            if item.strip()
        ] if raw else default_fallbacks
    for fallback_model in fallback_models:
        if fallback_model and fallback_model not in candidates:
            candidates.append(fallback_model)
    return candidates


def model_min_interval_seconds(model: str) -> float:
    load_dotenv()
    raw = os.environ.get("ZHUDA_MODEL_MIN_INTERVALS_MS", "").strip()
    intervals = DEFAULT_MODEL_MIN_INTERVAL_SECONDS.copy()
    for item in raw.split(","):
        if not item.strip() or ":" not in item:
            continue
        name, value = item.split(":", 1)
        name = name.strip()
        value = value.strip()
        try:
            intervals[name] = max(0, int(value)) / 1000
        except ValueError:
            continue
    return intervals.get(model, DEFAULT_GLOBAL_MIN_INTERVAL_SECONDS)


def estimate_tokens(text: str) -> int:
    ascii_count = 0
    non_ascii_count = 0
    for char in text:
        if ord(char) < 128:
            ascii_count += 1
        else:
            non_ascii_count += 1
    return max(1, (ascii_count + 3) // 4 + non_ascii_count)


def trim_to_token_budget(text: str, max_tokens: int, keep: str = "tail") -> tuple[str, bool]:
    if estimate_tokens(text) <= max_tokens:
        return text, False
    if max_tokens <= 0:
        return "", True

    def fit_prefix(value: str, budget: int) -> str:
        low = 0
        high = len(value)
        while low < high:
            mid = (low + high + 1) // 2
            if estimate_tokens(value[:mid]) <= budget:
                low = mid
            else:
                high = mid - 1
        return value[:low]

    def fit_suffix(value: str, budget: int) -> str:
        low = 0
        high = len(value)
        while low < high:
            mid = (low + high + 1) // 2
            if estimate_tokens(value[len(value) - mid:]) <= budget:
                low = mid
            else:
                high = mid - 1
        return value[len(value) - low:]

    marker = "\n...[trimmed by Zhuda adapter]...\n"
    marker_tokens = estimate_tokens(marker)
    if max_tokens <= marker_tokens + 16:
        return fit_suffix(text, max_tokens), True

    remaining = max_tokens - marker_tokens
    if keep == "head":
        return fit_prefix(text, remaining) + marker, True
    if keep == "middle":
        head_budget = max(1, int(remaining * 0.55))
        tail_budget = max(1, remaining - head_budget)
        return fit_prefix(text, head_budget) + marker + fit_suffix(text, tail_budget), True
    return marker + fit_suffix(text, remaining), True


def sanitize_large_blobs(text: str) -> str:
    text = re.sub(
        r"data:image/[^;,\s]+;base64,[A-Za-z0-9+/=\s]{1000,}",
        "[omitted base64 image payload]",
        text,
    )

    def replace_long_blob(match: re.Match[str]) -> str:
        value = match.group(0)
        return f"{value[:120]}...[omitted long blob: {len(value)} chars]...{value[-120:]}"

    return re.sub(r"[A-Za-z0-9+/=]{2400,}", replace_long_blob, text)


def stringify_tool_output(output: Any) -> str:
    if isinstance(output, str):
        text = output
    else:
        try:
            text = json.dumps(output, ensure_ascii=False, default=str)
        except TypeError:
            text = str(output)
    text = sanitize_large_blobs(text)
    max_chars = max_tool_output_chars_limit()
    if len(text) > max_chars:
        head = text[: max_chars // 2]
        tail = text[-(max_chars // 2):]
        text = f"{head}\n...[tool output trimmed by Zhuda adapter: {len(text)} chars]...\n{tail}"
    return text


def log_context_fit(before_tokens: int, after_tokens: int, trimmed: bool, chunk_count: int, kept_recent_count: int) -> None:
    record = {
        "created_at": int(time.time()),
        "beforeTokensEstimate": before_tokens,
        "afterTokensEstimate": after_tokens,
        "trimmed": trimmed,
        "chunkCount": chunk_count,
        "keptRecentCount": kept_recent_count,
    }
    try:
        with (ROOT / "adapter.context.jsonl").open("a") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def key_fingerprint(key: str) -> str:
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]


def log_pool_attempt(model: str, key_index: int, status: int, ok: bool, error: str = "") -> None:
    record = {
        "created_at": int(time.time()),
        "model": model,
        "key_index": key_index,
        "status": status,
        "ok": ok,
        "error": safe_upstream_text(error),
    }
    try:
        with (ROOT / "adapter.pool.jsonl").open("a") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def log_pool_start(model: str, key_index: int, prompt_tokens_estimate: int, timeout_seconds: int, is_large_prompt: bool) -> None:
    record = {
        "created_at": int(time.time()),
        "model": model,
        "key_index": key_index,
        "promptTokensEstimate": prompt_tokens_estimate,
        "timeoutSeconds": timeout_seconds,
        "isLargePrompt": is_large_prompt,
    }
    try:
        with (ROOT / "adapter.pool.start.jsonl").open("a") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def log_pool_summary(model: str, attempted: int, skipped_cooldown: int, errors: list[str]) -> None:
    record = {
        "created_at": int(time.time()),
        "model": model,
        "attempted": attempted,
        "skippedCooldown": skipped_cooldown,
        "errors": errors[-5:],
    }
    try:
        with (ROOT / "adapter.pool.summary.jsonl").open("a") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def log_guard(reason: str, details: dict[str, Any]) -> None:
    record = {
        "created_at": int(time.time()),
        "reason": reason,
        "details": details,
    }
    try:
        with (ROOT / "adapter.guard.jsonl").open("a") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
    except OSError:
        pass


def log_images(found: int, attached: int, skipped: list[str], sources: list[dict[str, Any]]) -> None:
    record = {
        "created_at": int(time.time()),
        "found": found,
        "attached": attached,
        "skipped": skipped[-10:],
        "sources": sources[-10:],
    }
    try:
        with (ROOT / "adapter.images.jsonl").open("a") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
    except OSError:
        pass


def log_tool_declarations(declarations: list[dict[str, Any]]) -> None:
    record = {
        "created_at": int(time.time()),
        "count": len(declarations),
        "names": [item.get("name") for item in declarations[:120]],
    }
    try:
        with (ROOT / "adapter.tools.jsonl").open("a") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
    except OSError:
        pass


def log_episode(record: dict[str, Any]) -> None:
    try:
        with (ROOT / "adapter.episodes.jsonl").open("a") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
    except OSError:
        pass


def summarize_request_tools(payload: dict[str, Any]) -> dict[str, Any]:
    tools = payload.get("tools")
    summary = {
        "total": 0,
        "functions": 0,
        "namespaces": 0,
        "namespaceTools": 0,
        "names": [],
    }
    if not isinstance(tools, list):
        return summary
    names = []
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        summary["total"] += 1
        tool_type = tool.get("type")
        tool_name = tool.get("name")
        if isinstance(tool_name, str) and tool_name:
            names.append(tool_name)
        if tool_type == "function":
            summary["functions"] += 1
        elif tool_type == "namespace":
            summary["namespaces"] += 1
            for nested_name, _ in namespace_tool_entries(tool):
                summary["namespaceTools"] += 1
                names.append(f"{tool_name}__{nested_name}")
    summary["names"] = names[:120]
    return summary


def summarize_input_items(payload: dict[str, Any]) -> dict[str, Any]:
    input_value = payload.get("input")
    summary: dict[str, Any] = {
        "inputType": type(input_value).__name__,
        "itemCount": 0,
        "typeCounts": {},
        "roleCounts": {},
        "recentItems": [],
    }
    if not isinstance(input_value, list):
        if isinstance(input_value, str):
            summary["textChars"] = len(input_value)
            summary["textPreview"] = input_value[:500]
        return summary

    type_counts: dict[str, int] = {}
    role_counts: dict[str, int] = {}
    recent = []
    for item in input_value:
        if not isinstance(item, dict):
            item_type = type(item).__name__
            role = None
        else:
            item_type = str(item.get("type") or "unknown")
            role = item.get("role")
        type_counts[item_type] = type_counts.get(item_type, 0) + 1
        if isinstance(role, str):
            role_counts[role] = role_counts.get(role, 0) + 1

    for item in input_value[-12:]:
        if not isinstance(item, dict):
            recent.append({"type": type(item).__name__})
            continue
        entry = {
            "type": item.get("type"),
            "role": item.get("role"),
        }
        if isinstance(item.get("name"), str):
            entry["name"] = item["name"]
        if isinstance(item.get("call_id"), str):
            entry["callId"] = item["call_id"]
        if isinstance(item.get("arguments"), str):
            entry["argumentsChars"] = len(item["arguments"])
            entry["argumentsPreview"] = item["arguments"][:300]
        if "output" in item:
            output = item.get("output")
            output_text = output if isinstance(output, str) else json.dumps(output, ensure_ascii=False, default=str)
            entry["outputChars"] = len(output_text)
            entry["outputPreview"] = output_text[:300]
        recent.append(entry)

    summary["itemCount"] = len(input_value)
    summary["typeCounts"] = type_counts
    summary["roleCounts"] = role_counts
    summary["recentItems"] = recent
    return summary


def summarize_images(image_parts: list[dict[str, Any]]) -> dict[str, Any]:
    mime_counts: dict[str, int] = {}
    estimated_total_bytes = 0
    for part in image_parts:
        inline = part.get("inline_data") if isinstance(part, dict) else None
        if not isinstance(inline, dict):
            continue
        mime_type = str(inline.get("mime_type") or "unknown")
        data = inline.get("data")
        mime_counts[mime_type] = mime_counts.get(mime_type, 0) + 1
        if isinstance(data, str):
            estimated_total_bytes += int(len(data) * 0.75)
    return {
        "attached": len(image_parts),
        "mimeCounts": mime_counts,
        "estimatedTotalBytes": estimated_total_bytes,
    }


def summarize_result(result: dict[str, Any]) -> dict[str, Any]:
    result_type = result.get("type")
    if result_type == "function_call":
        arguments = result.get("arguments") if isinstance(result.get("arguments"), dict) else {}
        return {
            "type": "function_call",
            "name": result.get("name"),
            "argumentKeys": sorted(arguments.keys())[:50],
            "argumentsPreview": json.dumps(arguments, ensure_ascii=False, default=str)[:500],
        }
    text = str(result.get("text") or "")
    return {
        "type": "text",
        "textChars": len(text),
        "textPreview": text[:500],
    }


def summarize_upstream_payload(payload: Optional[dict[str, Any]]) -> dict[str, Any]:
    if not isinstance(payload, dict):
        return {}
    openai_choices = payload.get("choices")
    if isinstance(openai_choices, list) and openai_choices:
        first_choice = openai_choices[0] if isinstance(openai_choices[0], dict) else {}
        message = first_choice.get("message") if isinstance(first_choice.get("message"), dict) else {}
        part_types = []
        if message.get("tool_calls"):
            part_types.append("tool_calls")
        for key in ("content", "reasoning_content", "reasoning", "text", "output_text"):
            if collect_openai_text(message.get(key)):
                part_types.append(f"message_{key}")
        if collect_openai_text(first_choice.get("text")):
            part_types.append("choice_text")
        usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
        return {
            "responseId": payload.get("id"),
            "modelVersion": payload.get("model"),
            "finishReason": first_choice.get("finish_reason"),
            "partTypes": part_types,
            "usage": {
                "promptTokens": usage.get("prompt_tokens"),
                "candidateTokens": usage.get("completion_tokens"),
                "totalTokens": usage.get("total_tokens"),
                "serviceTier": usage.get("service_tier"),
            },
        }
    candidates = payload.get("candidates")
    first_candidate = candidates[0] if isinstance(candidates, list) and candidates else {}
    parts = (((first_candidate or {}).get("content") or {}).get("parts")) or []
    part_types = []
    if isinstance(parts, list):
        for part in parts:
            if not isinstance(part, dict):
                continue
            if "functionCall" in part:
                part_types.append("functionCall")
            elif "text" in part:
                part_types.append("text")
            else:
                part_types.extend(part.keys())
    usage = payload.get("usageMetadata") if isinstance(payload.get("usageMetadata"), dict) else {}
    return {
        "responseId": payload.get("responseId"),
        "modelVersion": payload.get("modelVersion"),
        "finishReason": first_candidate.get("finishReason") if isinstance(first_candidate, dict) else None,
        "partTypes": part_types,
        "usage": {
            "promptTokens": usage.get("promptTokenCount"),
            "candidateTokens": usage.get("candidatesTokenCount"),
            "totalTokens": usage.get("totalTokenCount"),
            "serviceTier": usage.get("serviceTier"),
        },
    }


def summarize_exception(error: Exception) -> dict[str, Any]:
    detail = getattr(error, "detail", None)
    return {
        "type": type(error).__name__,
        "statusCode": getattr(error, "status_code", None),
        "detailPreview": json.dumps(detail, ensure_ascii=False, default=str)[:800] if detail is not None else str(error)[:800],
    }


def check_auth(authorization: Optional[str]) -> None:
    if not LOCAL_BEARER:
        return
    token = (authorization or "").removeprefix("Bearer ").strip()
    if token != LOCAL_BEARER:
        raise HTTPException(status_code=401, detail={"error": "invalid_api_key"})


def debug_log_request(payload: dict[str, Any]) -> None:
    tools = payload.get("tools")
    tool_summary = []
    if isinstance(tools, list):
        for tool in tools[:50]:
            if isinstance(tool, dict):
                nested_tools = tool.get("tools")
                nested_summary = None
                if isinstance(nested_tools, list):
                    nested_summary = [
                        {
                            "name": nested.get("name"),
                            "description": nested.get("description", "")[:100],
                            "keys": sorted(nested.keys()),
                        }
                        for nested in nested_tools[:20]
                        if isinstance(nested, dict)
                    ]
                elif isinstance(nested_tools, dict):
                    nested_summary = [
                        {
                            "name": name,
                            "description": nested.get("description", "")[:100] if isinstance(nested, dict) else "",
                            "keys": sorted(nested.keys()) if isinstance(nested, dict) else [],
                        }
                        for name, nested in list(nested_tools.items())[:20]
                    ]
                tool_summary.append({
                    "type": tool.get("type"),
                    "name": tool.get("name"),
                    "description": tool.get("description", "")[:120],
                    "keys": sorted(tool.keys()),
                    "nested_tools": nested_summary,
                })
    input_value = payload.get("input")
    if isinstance(input_value, list):
        input_summary = [
            {
                "type": item.get("type") if isinstance(item, dict) else type(item).__name__,
                "role": item.get("role") if isinstance(item, dict) else None,
                "keys": sorted(item.keys()) if isinstance(item, dict) else None,
            }
            for item in input_value[-8:]
        ]
    else:
        input_summary = type(input_value).__name__
    record = {
        "created_at": int(time.time()),
        "model": payload.get("model"),
        "stream": payload.get("stream"),
        "tool_choice": payload.get("tool_choice"),
        "tool_count": len(tools) if isinstance(tools, list) else 0,
        "tools": tool_summary,
        "input_summary": input_summary,
    }
    try:
        with (ROOT / "adapter.requests.jsonl").open("a") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def text_from_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                if isinstance(item.get("text"), str):
                    parts.append(item["text"])
                elif isinstance(item.get("input_text"), str):
                    parts.append(item["input_text"])
                elif item.get("type") in {"input_text", "text"} and isinstance(item.get("content"), str):
                    parts.append(item["content"])
        return "\n".join(part for part in parts if part)
    return ""


def walk_values(value: Any):
    if isinstance(value, dict):
        for item in value.values():
            yield from walk_values(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk_values(item)
    elif isinstance(value, str):
        yield value


def payload_text_values(payload: dict[str, Any]) -> list[str]:
    values = []
    for key in ("instructions", "input", "messages"):
        value = payload.get(key)
        if value is not None:
            values.extend(walk_values(value))
    return values


def recent_payload_text_values(payload: dict[str, Any], max_items: int) -> list[str]:
    values: list[str] = []
    input_value = payload.get("input")
    if isinstance(input_value, str):
        values.append(input_value)
    elif isinstance(input_value, list):
        for item in input_value[-max_items:]:
            if isinstance(item, str):
                values.append(item)
                continue
            if not isinstance(item, dict):
                continue
            for key in ("type", "role", "name", "content", "arguments", "input", "output"):
                if key in item:
                    values.extend(walk_values(item.get(key)))

    messages = payload.get("messages")
    if isinstance(messages, list):
        for item in messages[-max_items:]:
            if isinstance(item, str):
                values.append(item)
            elif isinstance(item, dict):
                for key in ("role", "content", "name", "tool_calls", "tool_call_id"):
                    if key in item:
                        values.extend(walk_values(item.get(key)))
    return values


def candidate_workdirs(payload: dict[str, Any]) -> list[Path]:
    workdirs: list[Path] = []
    for text in payload_text_values(payload):
        for pattern in (
            r"<cwd>([^<]+)</cwd>",
            r'"cwd"\s*:\s*"([^"]+)"',
            r"'cwd'\s*:\s*'([^']+)'",
            r"\bcwd\s*[:=]\s*([/\w][^\n\r]+)",
        ):
            for match in re.finditer(pattern, text):
                raw = match.group(1).strip().strip("'\".,;")
                path = Path(raw).expanduser()
                if path.is_dir() and path not in workdirs:
                    workdirs.append(path)
    for fallback in (
        Path.cwd(),
        ROOT,
        Path.home() / "Documents" / "ZhudaAPI",
        Path("/tmp"),
    ):
        if fallback.exists() and fallback not in workdirs:
            workdirs.append(fallback)
    return workdirs


def image_mime_type(path: Path) -> Optional[str]:
    mime_type, _ = mimetypes.guess_type(path.name)
    if mime_type in {"image/png", "image/jpeg", "image/webp", "image/gif"}:
        return mime_type
    suffix = path.suffix.lower()
    if suffix == ".jpg":
        return "image/jpeg"
    if suffix in {".png", ".jpeg", ".webp", ".gif"}:
        return f"image/{suffix.removeprefix('.')}"
    return None


def clean_image_path(raw: str) -> str:
    raw = unquote(raw.strip())
    raw = raw.removeprefix("file://")
    return raw.strip().strip(" \t\r\n\"'<>[]{}")


def image_refs_from_text(text: str) -> tuple[list[str], list[dict[str, str]]]:
    path_refs: list[str] = []
    data_refs: list[dict[str, str]] = []

    for match in re.finditer(r"data:(image/(?:png|jpeg|jpg|webp|gif));base64,([A-Za-z0-9+/=\s]+)", text, re.IGNORECASE):
        mime_type = match.group(1).lower()
        if mime_type == "image/jpg":
            mime_type = "image/jpeg"
        data_refs.append({"mime_type": mime_type, "data": re.sub(r"\s+", "", match.group(2))})

    for match in re.finditer(r"!\[[^\]]*\]\(([^)]+?\.(?:png|jpe?g|webp|gif))\)", text, re.IGNORECASE):
        path_refs.append(clean_image_path(match.group(1)))

    for match in re.finditer(
        r"((?:file://)?/(?:Users|tmp|private|var|Volumes)/[^\n\r\"'<>]*?\.(?:png|jpe?g|webp|gif))",
        text,
        re.IGNORECASE,
    ):
        path_refs.append(clean_image_path(match.group(1)))

    for match in re.finditer(r"\b([A-Za-z0-9_. -]+\.(?:png|jpe?g|webp|gif))\b", text, re.IGNORECASE):
        path_refs.append(clean_image_path(match.group(1)))

    return path_refs, data_refs


def recent_visual_intent(payload: dict[str, Any], lookback_items: int) -> bool:
    for text in recent_payload_text_values(payload, lookback_items):
        if VISUAL_INTENT_RE.search(text):
            return True
        paths, data_refs = image_refs_from_text(text)
        if paths or data_refs:
            return True
    return False


def resolve_image_path(raw: str, workdirs: list[Path]) -> Optional[Path]:
    raw = clean_image_path(raw)
    if not raw:
        return None
    parsed = urlparse(raw)
    if parsed.scheme == "file":
        raw = unquote(parsed.path)
    path = Path(raw).expanduser()
    candidates = [path] if path.is_absolute() else [workdir / path for workdir in workdirs]
    for candidate in candidates:
        try:
            candidate = candidate.resolve()
        except OSError:
            continue
        if candidate.is_file() and image_mime_type(candidate):
            return candidate
    return None


def inline_image_from_path(path: Path, total_bytes: int) -> tuple[Optional[dict[str, Any]], Optional[str]]:
    mime_type = image_mime_type(path)
    if not mime_type:
        return None, f"unsupported mime: {path}"
    max_bytes = env_int("ZHUDA_MAX_INLINE_IMAGE_BYTES", DEFAULT_MAX_INLINE_IMAGE_BYTES)
    max_total = env_int("ZHUDA_MAX_INLINE_IMAGE_TOTAL_BYTES", DEFAULT_MAX_INLINE_IMAGE_TOTAL_BYTES)
    try:
        size = path.stat().st_size
    except OSError as error:
        return None, f"stat failed: {path}: {error}"
    if size <= 0:
        return None, f"empty image: {path}"
    if size > max_bytes:
        return None, f"image too large: {path} ({size} bytes > {max_bytes})"
    if total_bytes + size > max_total:
        return None, f"image total too large: {path} ({total_bytes + size} bytes > {max_total})"
    try:
        data = base64.b64encode(path.read_bytes()).decode("ascii")
    except OSError as error:
        return None, f"read failed: {path}: {error}"
    return {
        "source": str(path),
        "mime_type": mime_type,
        "bytes": size,
        "part": {
            "inline_data": {
                "mime_type": mime_type,
                "data": data,
            }
        },
    }, None


def inline_image_from_data_uri(item: dict[str, str], total_bytes: int, index: int) -> tuple[Optional[dict[str, Any]], Optional[str]]:
    mime_type = item.get("mime_type") or "image/png"
    data = item.get("data") or ""
    max_bytes = env_int("ZHUDA_MAX_INLINE_IMAGE_BYTES", DEFAULT_MAX_INLINE_IMAGE_BYTES)
    max_total = env_int("ZHUDA_MAX_INLINE_IMAGE_TOTAL_BYTES", DEFAULT_MAX_INLINE_IMAGE_TOTAL_BYTES)
    try:
        decoded_size = len(base64.b64decode(data, validate=False))
    except Exception as error:
        return None, f"invalid data URI image {index}: {error}"
    if decoded_size <= 0:
        return None, f"empty data URI image {index}"
    if decoded_size > max_bytes:
        return None, f"data URI image too large {index}: {decoded_size} bytes > {max_bytes}"
    if total_bytes + decoded_size > max_total:
        return None, f"image total too large at data URI {index}: {total_bytes + decoded_size} bytes > {max_total}"
    return {
        "source": f"data-uri:{index}",
        "mime_type": mime_type,
        "bytes": decoded_size,
        "part": {
            "inline_data": {
                "mime_type": mime_type,
                "data": data,
            }
        },
    }, None


def extract_gemini_image_parts(payload: dict[str, Any], prompt_tokens_estimate: int = 0) -> list[dict[str, Any]]:
    max_images = env_int("ZHUDA_MAX_INLINE_IMAGES", DEFAULT_MAX_INLINE_IMAGES)
    if max_images <= 0:
        return []

    lookback_items = env_int("ZHUDA_IMAGE_LOOKBACK_ITEMS", DEFAULT_IMAGE_LOOKBACK_ITEMS)
    if not recent_visual_intent(payload, lookback_items):
        return []

    large_prompt_threshold = large_prompt_token_threshold()
    if prompt_tokens_estimate >= large_prompt_threshold:
        max_images = min(
            max_images,
            env_int("ZHUDA_LARGE_PROMPT_MAX_INLINE_IMAGES", DEFAULT_LARGE_PROMPT_MAX_INLINE_IMAGES),
        )

    workdirs = candidate_workdirs(payload)
    raw_paths: list[str] = []
    raw_data: list[dict[str, str]] = []
    for text in reversed(recent_payload_text_values(payload, lookback_items)):
        paths, data_refs = image_refs_from_text(text)
        raw_paths.extend(paths)
        raw_data.extend(data_refs)

    attached: list[dict[str, Any]] = []
    sources: list[dict[str, Any]] = []
    skipped: list[str] = []
    seen_paths: set[str] = set()
    seen_data: set[str] = set()
    total_bytes = 0

    for index, data_item in enumerate(raw_data, start=1):
        if len(attached) >= max_images:
            break
        data_key = hashlib.sha256(
            f"{data_item.get('mime_type') or ''}:{data_item.get('data') or ''}".encode("utf-8", errors="ignore")
        ).hexdigest()
        if data_key in seen_data:
            continue
        seen_data.add(data_key)
        image, error = inline_image_from_data_uri(data_item, total_bytes, index)
        if error:
            skipped.append(error)
            continue
        if not image:
            continue
        total_bytes += int(image["bytes"])
        sources.append({key: image[key] for key in ("source", "mime_type", "bytes")})
        attached.append(image["part"])

    for raw_path in raw_paths:
        if len(attached) >= max_images:
            break
        path = resolve_image_path(raw_path, workdirs)
        if not path:
            skipped.append(f"image path not found: {raw_path}")
            continue
        path_key = str(path)
        if path_key in seen_paths:
            continue
        seen_paths.add(path_key)
        image, error = inline_image_from_path(path, total_bytes)
        if error:
            skipped.append(error)
            continue
        if not image:
            continue
        total_bytes += int(image["bytes"])
        sources.append({key: image[key] for key in ("source", "mime_type", "bytes")})
        attached.append(image["part"])

    if raw_paths or raw_data or attached or skipped:
        log_images(len(raw_paths) + len(raw_data), len(attached), skipped, sources)
    return attached


def input_item_text(item: dict[str, Any]) -> str:
    item_type = item.get("type")
    if item_type == "message":
        role = item.get("role") or "user"
        content = text_from_content(item.get("content"))
        label = {
            "user": "USER_MESSAGE",
            "assistant": "ASSISTANT_MESSAGE",
            "system": "SYSTEM_MESSAGE",
            "developer": "DEVELOPER_MESSAGE",
        }.get(str(role), str(role).upper())
        return f"{label}:\n{content}" if content else ""
    if item_type == "function_call":
        name = item.get("name") or "function"
        arguments = item.get("arguments") or ""
        return f"ASSISTANT_TOOL_CALL {name}:\n{arguments}"
    if item_type == "function_call_output":
        call_id = item.get("call_id") or ""
        output = stringify_tool_output(item.get("output") or "")
        return f"TOOL_RESULT {call_id}:\n{output}"
    if item_type == "custom_tool_call":
        name = item.get("name") or "custom_tool"
        custom_input = item.get("input") or ""
        return f"ASSISTANT_CUSTOM_TOOL_CALL {name}:\n{custom_input}"
    if item_type == "custom_tool_call_output":
        call_id = item.get("call_id") or ""
        output = stringify_tool_output(item.get("output") or "")
        return f"CUSTOM_TOOL_RESULT {call_id}:\n{output}"
    content = text_from_content(item.get("content"))
    if content:
        return content
    return ""


def normalize_tool_arguments(value: Any) -> str:
    if not isinstance(value, str):
        try:
            value = json.dumps(value, ensure_ascii=False, sort_keys=True)
        except TypeError:
            value = str(value)
    raw = value.strip()
    parsed: Any = None
    if raw:
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = None
    if isinstance(parsed, dict):
        for key in ("cmd", "command", "path", "image_path", "file"):
            candidate = parsed.get(key)
            if isinstance(candidate, str) and candidate.strip():
                raw = candidate.strip()
                if key in {"cmd", "command"}:
                    without_comments = "\n".join(
                        line for line in raw.splitlines()
                        if not line.strip().startswith("#")
                    ).strip()
                    raw = without_comments or raw
                break
        else:
            raw = json.dumps(parsed, ensure_ascii=False, sort_keys=True)
    raw = re.sub(r"\s+", " ", raw)
    raw = re.sub(r"/tmp/[^\s\"']+\.png", "/tmp/<screenshot>.png", raw)
    raw = re.sub(r"/var/folders/[^\s\"']+\.png", "/tmp/<screenshot>.png", raw)
    return raw[:500]


def visual_tool_signature(item: dict[str, Any]) -> Optional[str]:
    item_type = item.get("type")
    if item_type not in {"function_call", "custom_tool_call"}:
        return None
    name = item.get("name")
    if not isinstance(name, str) or not name:
        return None
    arguments = item.get("arguments")
    if item_type == "custom_tool_call":
        arguments = item.get("input")
    normalized = normalize_tool_arguments(arguments or "")
    lowered_name = name.lower()
    lowered_args = normalized.lower()
    is_visual = (
        lowered_name in {"view_image", "screenshot", "get_app_state"}
        or "screencapture" in lowered_args
        or "browser_check.png" in lowered_args
        or "line_check.png" in lowered_args
    )
    if not is_visual:
        return None
    return f"{name}:{normalized}"


def repeated_visual_tool_guard_text(payload: dict[str, Any], image_part_count: int = 0) -> Optional[str]:
    if env_bool("ZHUDA_DISABLE_REPEAT_GUARDS"):
        return None
    max_repeats = env_int("ZHUDA_MAX_REPEAT_VISUAL_TOOL_CALLS", DEFAULT_MAX_REPEAT_VISUAL_TOOL_CALLS)
    input_value = payload.get("input")
    if not isinstance(input_value, list):
        return None

    counts: dict[str, int] = {}
    visual_count = 0
    for item in input_value:
        if not isinstance(item, dict):
            continue
        signature = visual_tool_signature(item)
        if not signature:
            continue
        visual_count += 1
        counts[signature] = counts.get(signature, 0) + 1

    repeated = [
        {"signature": signature[:220], "count": count}
        for signature, count in counts.items()
        if count >= max_repeats
    ]
    if image_part_count > 0 and visual_count <= max_repeats:
        return None
    if not repeated and visual_count < max_repeats + 1:
        return None

    log_guard(
        "repeated_visual_tool_call",
        {
            "visualToolCalls": visual_count,
            "imageParts": image_part_count,
            "maxRepeats": max_repeats,
            "repeated": repeated,
        },
    )
    return (
        "Zhuda adapter stopped a repeated visual-tool loop.\n\n"
        f"- Visual/screenshot tool calls in this turn: {visual_count}\n"
        f"- Repeat guard threshold: {max_repeats}\n\n"
        "這輪裡面已經重複呼叫太多次截圖/讀圖工具，所以 adapter 先停止工具迴圈，避免貼滿同一張圖並燒掉 API 額度。\n\n"
        "現在 adapter 會嘗試把近期截圖檔轉成 Gemini inline image；如果它仍然一直截同一張圖，"
        "通常代表模型沒有從畫面得到足夠決策資訊。建議改成更明確的要求，例如："
        "「看最新一張截圖，直接回答畫面中央主要內容，不要再截圖」。"
    )


IGNORED_REPEAT_TOOL_NAMES = {
    "update_plan",
    "get_goal",
    "create_goal",
    "update_goal",
    "request_user_input",
    "write_stdin",
}


def repeated_tool_signature(item: dict[str, Any]) -> Optional[tuple[str, str]]:
    item_type = item.get("type")
    if item_type not in {"function_call", "custom_tool_call"}:
        return None
    name = item.get("name")
    if not isinstance(name, str) or not name or name in IGNORED_REPEAT_TOOL_NAMES:
        return None
    arguments = item.get("arguments")
    if item_type == "custom_tool_call":
        arguments = item.get("input")
    normalized = normalize_tool_arguments(arguments or "")
    if not normalized:
        normalized = "<empty>"
    return name, normalized


def items_after_latest_user_message(input_value: list[Any]) -> list[Any]:
    start = 0
    for index, item in enumerate(input_value):
        if not isinstance(item, dict):
            continue
        if item.get("type") == "message" and item.get("role") == "user":
            start = index + 1
    return input_value[start:]


def repeated_tool_call_guard_text(payload: dict[str, Any]) -> Optional[str]:
    if env_bool("ZHUDA_DISABLE_REPEAT_GUARDS"):
        return None
    max_repeats = env_int("ZHUDA_MAX_REPEAT_TOOL_CALLS", DEFAULT_MAX_REPEAT_TOOL_CALLS)
    lookback_items = env_int("ZHUDA_REPEAT_TOOL_LOOKBACK_ITEMS", DEFAULT_REPEAT_TOOL_LOOKBACK_ITEMS)
    input_value = payload.get("input")
    if not isinstance(input_value, list):
        return None

    signatures: list[tuple[str, str]] = []
    scoped_input = items_after_latest_user_message(input_value)
    for item in scoped_input:
        if not isinstance(item, dict):
            continue
        signature = repeated_tool_signature(item)
        if signature:
            signatures.append(signature)

    if len(signatures) < max_repeats:
        return None

    recent_signatures = signatures[-max(1, lookback_items):]
    counts: dict[tuple[str, str], int] = {}
    for signature in recent_signatures:
        counts[signature] = counts.get(signature, 0) + 1

    repeated = [
        {"name": name, "arguments": arguments[:220], "count": count}
        for (name, arguments), count in counts.items()
        if count >= max_repeats
    ]
    if not repeated:
        return None

    top = max(repeated, key=lambda item: int(item["count"]))
    log_guard(
        "repeated_tool_call",
        {
            "maxRepeats": max_repeats,
            "lookbackItems": lookback_items,
            "repeated": repeated,
        },
    )
    return (
        "Zhuda adapter stopped a repeated tool-call loop.\n\n"
        f"- Tool: {top['name']}\n"
        f"- Repeated count in recent tool history: {top['count']}\n"
        f"- Repeat guard threshold: {max_repeats}\n\n"
        "這不是 Gemini API 斷線，而是模型正在反覆執行同一個工具動作，通常代表它沒有從前一次輸出取得新決策。\n\n"
        "請直接根據目前已知輸出做結論，或改用不同驗證方式；如果只是要看圖片，請改成："
        "「直接描述我剛貼的圖片，不要再跑任何命令」。"
    )


def extract_input_text(payload: dict[str, Any]) -> str:
    pinned_chunks: list[str] = []
    recent_chunks: list[str] = []
    instructions = payload.get("instructions")
    if isinstance(instructions, str) and instructions.strip():
        pinned_chunks.append(f"CODEx_INSTRUCTIONS:\n{instructions.strip()}")

    input_value = payload.get("input")
    if isinstance(input_value, str):
        recent_chunks.append(input_value)
    elif isinstance(input_value, list):
        for item in input_value:
            if isinstance(item, str):
                recent_chunks.append(item)
                continue
            if not isinstance(item, dict):
                continue
            text = input_item_text(item)
            if text:
                role = item.get("role")
                if item.get("type") == "message" and role in {"system", "developer"}:
                    pinned_chunks.append(text)
                else:
                    recent_chunks.append(text)

    messages = payload.get("messages")
    if isinstance(messages, list):
        for item in messages:
            if not isinstance(item, dict):
                continue
            role = item.get("role")
            content = text_from_content(item.get("content"))
            if content:
                label = {
                    "user": "USER_MESSAGE",
                    "assistant": "ASSISTANT_MESSAGE",
                    "system": "SYSTEM_MESSAGE",
                    "developer": "DEVELOPER_MESSAGE",
                }.get(str(role), str(role or "user").upper())
                chunk = f"{label}:\n{content}"
                if role in {"system", "developer"}:
                    pinned_chunks.append(chunk)
                else:
                    recent_chunks.append(chunk)

    chunks = [chunk.strip() for chunk in pinned_chunks + recent_chunks if chunk and chunk.strip()]
    if not chunks:
        return "Reply OK only."

    max_tokens = max_input_tokens_limit()
    pinned_budget = min(max_pinned_tokens_limit(), max(2048, max_tokens // 3))
    item_budget = max_history_item_tokens_limit()

    before_text = "\n\n".join(chunks)
    before_tokens = estimate_tokens(before_text)
    trimmed = False

    pinned_text = "\n\n".join(chunk.strip() for chunk in pinned_chunks if chunk and chunk.strip())
    pinned_text, pinned_trimmed = trim_to_token_budget(pinned_text, pinned_budget, keep="middle")
    trimmed = trimmed or pinned_trimmed

    remaining = max(2048, max_tokens - estimate_tokens(pinned_text) - 512)
    kept_recent: list[str] = []
    for chunk in reversed([chunk.strip() for chunk in recent_chunks if chunk and chunk.strip()]):
        chunk, item_trimmed = trim_to_token_budget(chunk, item_budget, keep="middle")
        trimmed = trimmed or item_trimmed
        chunk_tokens = estimate_tokens(chunk)
        if chunk_tokens <= remaining:
            kept_recent.append(chunk)
            remaining -= chunk_tokens
            continue
        if remaining > 1024:
            chunk, item_trimmed = trim_to_token_budget(chunk, remaining, keep="tail")
            trimmed = True or item_trimmed
            kept_recent.append(chunk)
        trimmed = True
        break

    kept_recent.reverse()
    output_chunks = []
    if trimmed:
        output_chunks.append(
            f"[Zhuda adapter note: older context and long tool outputs were trimmed to fit a {max_tokens}-token request budget. Continue from the preserved recent context.]"
        )
    if pinned_text.strip():
        output_chunks.append(pinned_text.strip())
    output_chunks.extend(kept_recent)
    output = "\n\n".join(chunk for chunk in output_chunks if chunk)
    after_tokens = estimate_tokens(output)
    log_context_fit(before_tokens, after_tokens, trimmed, len(chunks), len(kept_recent))
    return output or "Reply OK only."


def output_text_from_gemini(value: dict[str, Any]) -> str:
    candidates = value.get("candidates") or []
    if not candidates:
        return ""
    parts = (((candidates[0] or {}).get("content") or {}).get("parts")) or []
    texts = [part.get("text", "") for part in parts if isinstance(part, dict)]
    return clean_model_meta_text("".join(texts).strip())


META_PREFIX_RE = re.compile(
    r"^\s*(?:"
    r"The user (?:wants|asked|asks|said|says|provided|is providing|is asking|is reporting|has asked|has provided)[^.。\n]*(?:[.。]\s*)?|"
    r"User:\s*[^.。\n]*(?:[.。]\s*)?|"
    r"There is no transcript provided[^.。\n]*(?:[.。]\s*)?|"
    r"Looking at [^.。\n]*(?:[.。]\s*)?|"
    r"Actually, [^.。\n]*(?:[.。]\s*)?|"
    r"Analysis of [^.。\n]*(?:[.。]\s*)?|"
    r"Plan:\s*(?:\d+\.\s*[^.。\n]*(?:[.。]\s*)?)+|"
    r"I (?:need|should|will|have) [^.。\n]*(?:[.。]\s*)?|"
    r"Wait, [^.。\n]*(?:[.。]\s*)?"
    r")",
    re.IGNORECASE,
)
CJK_RE = re.compile(r"[\u3400-\u9fff]")
ANALYSIS_ONLY_RE = re.compile(
    r"^\s*(?:[-*]\s*)?(?:User asks|The user |Constraint:|Plan:|Analysis of|Looking at)",
    re.IGNORECASE,
)


def clean_model_meta_text(text: str) -> str:
    cleaned = text.strip()
    if ANALYSIS_ONLY_RE.match(cleaned):
        final_match = re.search(r"(?is)(?:FINAL_ANSWER|Final answer|Answer|結論)[:：]\s*(.+)$", cleaned)
        if final_match:
            return final_match.group(1).strip()
        if re.fullmatch(r'(?is).*(reply with ["“]?OK["”]?|reply OK only).*', text) and cleaned.endswith("OK"):
            return "OK"
        return (
            "上游模型這輪回了 HTTP 200，但輸出被 Zhuda adapter 判定為分析稿，沒有產生可用答案。\n\n"
            "Zhuda adapter 解釋\n"
            "- 這不是 API 斷線，也不是額度錯誤。\n"
            "- adapter 沒有自動切換模型；你選哪個模型，這輪就只使用哪個模型。\n"
            "- 這通常是模型在長上下文或工具任務裡指令遵循失穩。請重試一次，或先用 /compact 開新上下文。"
        )
    cjk_match = CJK_RE.search(cleaned)
    if cjk_match and META_PREFIX_RE.match(cleaned):
        return cleaned[cjk_match.start():].strip()
    for _ in range(6):
        updated = META_PREFIX_RE.sub("", cleaned).strip()
        if updated == cleaned:
            break
        cleaned = updated
    if re.fullmatch(r'(?is).*(reply with ["“]?OK["”]?|reply OK only).*', text) and cleaned.endswith("OK"):
        return "OK"
    return cleaned or text.strip()


def function_call_from_gemini(value: dict[str, Any]) -> Optional[dict[str, Any]]:
    candidates = value.get("candidates") or []
    if not candidates:
        return None
    parts = (((candidates[0] or {}).get("content") or {}).get("parts")) or []
    for part in parts:
        if isinstance(part, dict) and isinstance(part.get("functionCall"), dict):
            call = part["functionCall"]
            name = call.get("name")
            args = call.get("args") if isinstance(call.get("args"), dict) else {}
            if isinstance(name, str) and name:
                return {"name": name, "arguments": args}
    return None


def strip_schema_for_gemini(value: Any) -> Any:
    if isinstance(value, dict):
        cleaned = {}
        for key, item in value.items():
            if key in {"$schema", "$defs", "definitions", "additionalProperties", "unevaluatedProperties"}:
                continue
            if key in {"anyOf", "oneOf", "allOf"} and isinstance(item, list) and item:
                cleaned.update(strip_schema_for_gemini(item[0]))
                continue
            cleaned[key] = strip_schema_for_gemini(item)
        if cleaned.get("type") == "object":
            cleaned["type"] = "OBJECT"
        elif cleaned.get("type") == "array":
            cleaned["type"] = "ARRAY"
        elif cleaned.get("type") == "string":
            cleaned["type"] = "STRING"
        elif cleaned.get("type") == "number":
            cleaned["type"] = "NUMBER"
        elif cleaned.get("type") == "integer":
            cleaned["type"] = "INTEGER"
        elif cleaned.get("type") == "boolean":
            cleaned["type"] = "BOOLEAN"
        return cleaned
    if isinstance(value, list):
        return [strip_schema_for_gemini(item) for item in value]
    return value


def gemini_safe_tool_name(name: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_]", "_", name.strip())
    if not safe:
        safe = "tool"
    if safe[0].isdigit():
        safe = f"tool_{safe}"
    return safe[:63]


def tool_parameters(tool: dict[str, Any]) -> dict[str, Any]:
    for key in ("parameters", "input_schema", "inputSchema", "schema"):
        value = tool.get(key)
        if isinstance(value, dict):
            return value
    return {"type": "object", "properties": {}}


def namespace_tool_entries(tool: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    namespace = tool.get("name")
    nested_tools = tool.get("tools")
    if not isinstance(namespace, str) or not namespace:
        return []
    entries: list[tuple[str, dict[str, Any]]] = []
    if isinstance(nested_tools, list):
        for nested in nested_tools:
            if isinstance(nested, dict):
                nested_name = nested.get("name")
                if isinstance(nested_name, str) and nested_name:
                    entries.append((nested_name, nested))
    elif isinstance(nested_tools, dict):
        for nested_name, nested in nested_tools.items():
            if isinstance(nested_name, str) and isinstance(nested, dict):
                nested = {"name": nested_name, **nested}
                entries.append((nested_name, nested))
    return entries


def gemini_function_declarations(payload: dict[str, Any]) -> list[dict[str, Any]]:
    declarations = []
    seen_names: set[str] = set()
    tools = payload.get("tools")
    if not isinstance(tools, list):
        return declarations
    max_tools = env_int("ZHUDA_MAX_DECLARED_TOOLS", DEFAULT_MAX_DECLARED_TOOLS)
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        if len(declarations) >= max_tools:
            break
        if tool.get("type") == "function":
            name = tool.get("name")
            if not isinstance(name, str) or not name:
                continue
            safe_name = gemini_safe_tool_name(name)
            if safe_name in seen_names:
                continue
            seen_names.add(safe_name)
            declarations.append({
                "name": safe_name,
                "description": tool.get("description") or name,
                "parameters": strip_schema_for_gemini(tool_parameters(tool)),
            })
            continue
        if tool.get("type") == "namespace":
            namespace = tool.get("name")
            if not isinstance(namespace, str) or not namespace:
                continue
            for nested_name, nested in namespace_tool_entries(tool):
                if len(declarations) >= max_tools:
                    break
                flattened_name = gemini_safe_tool_name(f"{namespace}__{nested_name}")
                if flattened_name in seen_names:
                    continue
                seen_names.add(flattened_name)
                description = nested.get("description") or nested_name
                namespace_description = tool.get("description") or namespace
                declarations.append({
                    "name": flattened_name,
                    "description": (
                        f"{description}\n\n"
                        f"Codex namespace tool: {namespace}.{nested_name}. "
                        f"Call this declared function as `{flattened_name}`. "
                        "Do not pass this name to exec_command or any shell."
                        f"\nNamespace guidance: {namespace_description}"
                    ),
                    "parameters": strip_schema_for_gemini(tool_parameters(nested)),
                })
    log_tool_declarations(declarations)
    return declarations


def gemini_system_instruction(declarations: list[dict[str, Any]], image_part_count: int) -> str:
    sections = [EXECUTION_VERIFICATION_PROMPT.strip()]
    if declarations:
        sections.append(
            "\n".join([
                "[Zhuda tool bridge instructions]",
                "- Use Gemini function calling for declared tools.",
                "- Never run tool names such as `mcp__node_repl__js`, `mcp__computer_use__get_app_state`, "
                "`codex_app__read_thread_terminal`, `browser__...`, or `chrome__...` through `exec_command`.",
                "- `exec_command` is only for real shell commands like `ls`, `rg`, `python3`, or `screencapture`.",
                "- Namespace tools are declared with flattened names using double underscores, for example "
                "`mcp__node_repl__js`. Call that declared function directly when needed.",
            ])
        )
    if image_part_count:
        sections.append(
            f"[Zhuda visual bridge note]\n"
            f"The adapter attached {image_part_count} recent local image(s) as Gemini inline image parts. "
            "Use them directly when the user asks about the screen, browser, YouTube, screenshots, or visual content. "
            "Do not call another screenshot tool unless the current image is clearly insufficient."
        )
    else:
        sections.append(
            "[Zhuda visual bridge note]\n"
            "For visual/screen/browser tasks, if you need a screenshot through shell, save it to "
            "`/tmp/zhuda_codex_screen.png` or another `/tmp/*.png` path. Do not save screenshots into "
            "`~/Documents` or the workspace for visual analysis, because the background adapter may not "
            "have macOS privacy permission to read those files."
        )
    return "\n\n".join(sections)


async def call_gemini(
    prompt: str,
    model: str,
    declarations: Optional[list[dict[str, Any]]] = None,
    image_parts: Optional[list[dict[str, Any]]] = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    global cursor, last_upstream_call_at
    keys = gemini_keys()
    if not keys:
        raise HTTPException(status_code=503, detail={"error": "gemini_keys_missing"})

    started = cursor
    cursor = (cursor + 1) % len(keys)
    errors: list[str] = []
    image_parts = image_parts or []
    content_parts = []
    if image_parts:
        content_parts.extend(image_parts)
    system_instruction = gemini_system_instruction(declarations or [], len(image_parts))
    prompt_tokens_estimate = estimate_tokens(system_instruction + "\n\n" + prompt)
    large_prompt_threshold = large_prompt_token_threshold()
    is_large_prompt = prompt_tokens_estimate >= large_prompt_threshold
    content_parts.append({"text": prompt})
    body = {
        "systemInstruction": {
            "parts": [{"text": system_instruction}],
        },
        "contents": [
            {
                "role": "user",
                "parts": content_parts,
            }
        ],
        "generationConfig": {
            "temperature": 0.2,
            "maxOutputTokens": 2048,
        },
    }
    if declarations:
        body["tools"] = [{"functionDeclarations": declarations}]
        body["toolConfig"] = {"functionCallingConfig": {"mode": "AUTO"}}

    max_key_attempts = min(len(keys), env_int("ZHUDA_MAX_KEY_ATTEMPTS", DEFAULT_MAX_KEY_ATTEMPTS))
    max_model_attempts = env_int("ZHUDA_MAX_MODEL_ATTEMPTS", DEFAULT_MAX_MODEL_ATTEMPTS)
    if is_large_prompt:
        max_model_attempts = min(
            max_model_attempts,
            env_int("ZHUDA_LARGE_PROMPT_MAX_MODEL_ATTEMPTS", DEFAULT_LARGE_PROMPT_MAX_MODEL_ATTEMPTS),
        )
    rate_limit_cooldown = rate_limit_cooldown_seconds()
    large_prompt_rate_limit_cooldown = large_prompt_rate_limit_cooldown_seconds()
    error_cooldown = error_cooldown_seconds()
    timeout_cooldown = timeout_cooldown_seconds()
    min_interval = env_int("ZHUDA_GLOBAL_MIN_INTERVAL_MS", int(DEFAULT_GLOBAL_MIN_INTERVAL_SECONDS * 1000)) / 1000
    large_prompt_min_interval = large_prompt_min_interval_seconds()
    candidates = upstream_model_candidates(model)[:max(1, max_model_attempts)]
    attempted = 0
    skipped_cooldown = 0
    daily_quota_errors: list[str] = []
    rate_limit_waited = 0.0

    upstream_timeout = upstream_timeout_seconds()
    async with upstream_state_lock:
        async with httpx.AsyncClient(timeout=upstream_timeout) as client:
            for candidate_model in candidates:
                candidate_attempts = 0
                offset = 0
                while offset < len(keys):
                    if candidate_attempts >= max_key_attempts:
                        break
                    key_index = (started + offset) % len(keys)
                    cooldown_key = (candidate_model, key_index)
                    now = time.monotonic()
                    cooldown_until = cooldowns.get(cooldown_key, 0)
                    if cooldown_until > now:
                        reason = cooldown_reasons.get(cooldown_key, "")
                        if reason == "daily_quota":
                            daily_quota_errors.append(f"{candidate_model}:key_{key_index + 1}:429:daily_quota_cooldown")
                            skipped_cooldown += 1
                            offset += 1
                            continue
                        wait_seconds = int(cooldown_until - now + 0.999)
                        rate_limit_waited += wait_seconds
                        if rate_limit_waited > rate_limit_max_wait_seconds():
                            errors.append(f"{candidate_model}:key_{key_index + 1}:429:short_rate_limit_wait_exceeded")
                            offset += 1
                            continue
                        log_pool_attempt(candidate_model, key_index + 1, 0, False, f"short_rate_limit_wait:{wait_seconds}s")
                        await sleep_for_short_rate_limit(wait_seconds)
                        clear_cooldown(cooldown_key)
                        now = time.monotonic()
                    key = keys[key_index]
                    url = f"{GEMINI_BASE_URL}/models/{candidate_model}:generateContent"
                    model_interval = model_min_interval_seconds(candidate_model)
                    model_wait_for = model_interval - (now - last_model_call_at.get(candidate_model, 0))
                    large_prompt_wait_for = large_prompt_min_interval - (now - last_upstream_call_at) if is_large_prompt else 0
                    wait_for = max(
                        min_interval - (now - last_upstream_call_at),
                        model_wait_for,
                        large_prompt_wait_for,
                    )
                    if wait_for > 0:
                        await asyncio.sleep(wait_for)
                    last_upstream_call_at = time.monotonic()
                    last_model_call_at[candidate_model] = last_upstream_call_at
                    attempted += 1
                    candidate_attempts += 1
                    log_pool_start(candidate_model, key_index + 1, prompt_tokens_estimate, upstream_timeout, is_large_prompt)
                    try:
                        response = await client.post(url, params={"key": key}, json=body)
                    except httpx.TimeoutException as error:
                        error_text = f"{candidate_model}:key_{key_index + 1}:timeout_after_{upstream_timeout}s:{error}"
                        errors.append(error_text)
                        log_pool_attempt(candidate_model, key_index + 1, 0, False, error_text)
                        set_cooldown(cooldown_key, timeout_cooldown, "timeout")
                        offset += 1
                        continue
                    except httpx.HTTPError as error:
                        error_text = f"{candidate_model}:key_{key_index + 1}:http_error:{type(error).__name__}:{error}"
                        errors.append(error_text)
                        log_pool_attempt(candidate_model, key_index + 1, 0, False, error_text)
                        set_cooldown(cooldown_key, error_cooldown, "http_error")
                        offset += 1
                        continue
                    log_pool_attempt(
                        model=candidate_model,
                        key_index=key_index + 1,
                        status=response.status_code,
                        ok=response.is_success,
                        error="" if response.is_success else response.text,
                    )
                    if response.is_success:
                        payload = response.json()
                        clear_cooldown(cooldown_key)
                        function_call = function_call_from_gemini(payload)
                        if function_call:
                            log_pool_summary(model, attempted, skipped_cooldown, errors)
                            return {"type": "function_call", **function_call}, payload
                        text = output_text_from_gemini(payload)
                        if text:
                            log_pool_summary(model, attempted, skipped_cooldown, errors)
                            return {"type": "text", "text": text}, payload
                        errors.append(f"{candidate_model}:gemini_content_missing")
                        offset += 1
                        continue
                    errors.append(upstream_error_text(candidate_model, key_index + 1, response.status_code, response.text))
                    if response.status_code == 400 and "input token count exceeds" in response.text.lower():
                        log_pool_summary(model, attempted, skipped_cooldown, errors)
                        raise HTTPException(status_code=400, detail={"error": "gemini_input_too_large", "details": errors[-3:]})
                    if response.status_code == 400:
                        log_pool_summary(model, attempted, skipped_cooldown, errors)
                        raise HTTPException(status_code=400, detail={"error": "gemini_bad_request", "details": errors[-3:]})
                    if response.status_code == 429:
                        if is_daily_quota_error(response.text):
                            daily_error = (
                                f"{candidate_model}:key_{key_index + 1}:429:daily_quota_exhausted:"
                                f"{safe_upstream_text(response.text)}"
                            )
                            daily_quota_errors.append(daily_error)
                            set_cooldown(cooldown_key, env_int("ZHUDA_DAILY_QUOTA_COOLDOWN_SECONDS", 12 * 60 * 60), "daily_quota")
                            offset += 1
                            continue
                        cooldown = rate_limit_wait_seconds(response.text, rate_limit_cooldown, is_large_prompt)
                        rate_limit_waited += cooldown
                        if rate_limit_waited > rate_limit_max_wait_seconds():
                            errors.append(
                                f"{candidate_model}:key_{key_index + 1}:429:short_rate_limit_wait_exceeded:"
                                f"{safe_upstream_text(response.text)}"
                            )
                            offset += 1
                            continue
                        set_cooldown(cooldown_key, cooldown, "short_rate_limit")
                        log_pool_attempt(candidate_model, key_index + 1, 0, False, f"short_rate_limit_wait:{cooldown}s")
                        await sleep_for_short_rate_limit(cooldown)
                        clear_cooldown(cooldown_key)
                        candidate_attempts = max(0, candidate_attempts - 1)
                        continue
                    if response.status_code in {500, 502, 503, 504}:
                        set_cooldown(cooldown_key, error_cooldown, "server_error")
                    if response.status_code not in RETRYABLE_UPSTREAM_STATUSES:
                        break
                    offset += 1

    log_pool_summary(model, attempted, skipped_cooldown, errors)
    if daily_quota_errors:
        raise HTTPException(status_code=429, detail={"error": "gemini_daily_quota_exhausted", "details": daily_quota_errors[-3:]})
    if attempted == 0 and skipped_cooldown:
        raise HTTPException(
            status_code=503,
            detail={
                "error": "gemini_cooling_down",
                "cooldownSeconds": cooldown_remaining_seconds(candidates, len(keys)),
                "details": errors[-3:],
            },
        )
    raise HTTPException(status_code=502, detail={"error": "gemini_pool_failed", "details": errors[-3:]})


def openai_compatible_system_instruction(
    provider_name: str,
    declarations: list[dict[str, Any]],
    image_part_count: int,
    image_switch_hint: str,
) -> str:
    sections = [EXECUTION_VERIFICATION_PROMPT.strip()]
    sections.append(
        "[Zhuda provider note]\n"
        f"This turn is routed through {provider_name} using an OpenAI-compatible chat/completions endpoint. "
        "Answer directly in the user's language."
    )
    if declarations:
        tool_names = [
            item.get("name")
            for item in declarations[:40]
            if isinstance(item.get("name"), str) and item.get("name")
        ]
        tool_list = ", ".join(tool_names)
        sections.append(
            "[Zhuda tool bridge note]\n"
            "If the API supports native tool_calls, call exactly one declared tool and no prose.\n"
            "If native tool_calls are unavailable, output exactly this fallback text format and no prose: "
            "<tool_call><function=exec_command><parameter=cmd>pwd</parameter></function></tool_call>\n"
            "For shell or terminal actions, use function=exec_command and parameter=cmd, not function=shell.\n"
            f"Available tool names: {tool_list}"
        )
    if image_part_count:
        sections.append(
            f"[Zhuda visual bridge note]\n"
            f"Codex supplied {image_part_count} image(s), but this route does not send inline images yet. "
            f"If image details are essential, ask the user to switch to {image_switch_hint}."
        )
    return "\n\n".join(sections)


def mimo_system_instruction(declarations: list[dict[str, Any]], image_part_count: int) -> str:
    return openai_compatible_system_instruction(
        "Xiaomi MiMo",
        declarations,
        image_part_count,
        "a Gemini vision-capable mapping",
    )


def deepseek_system_instruction(declarations: list[dict[str, Any]], image_part_count: int) -> str:
    return openai_compatible_system_instruction(
        "DeepSeek",
        declarations,
        image_part_count,
        "a vision-capable provider mapping",
    )


def output_text_from_openai_chat(payload: dict[str, Any]) -> str:
    top_level_text = collect_openai_text(payload.get("output_text")) or collect_openai_text(payload.get("output"))
    if top_level_text:
        return top_level_text
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        return ""
    first = choices[0] if isinstance(choices[0], dict) else {}
    choice_text = collect_openai_text(first.get("text")) or collect_openai_text(first.get("output_text"))
    if choice_text:
        return choice_text
    message = first.get("message") if isinstance(first.get("message"), dict) else {}
    for key in ("content", "text", "output_text"):
        text = collect_openai_text(message.get(key))
        if text:
            return text
    delta = first.get("delta") if isinstance(first.get("delta"), dict) else {}
    for key in ("content", "text", "output_text"):
        text = collect_openai_text(delta.get(key))
        if text:
            return text
    return ""


def collect_openai_text(value: Any) -> str:
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        chunks = [collect_openai_text(item) for item in value]
        return "".join(chunk for chunk in chunks if chunk).strip()
    if isinstance(value, dict):
        chunks = []
        for key in ("text", "output_text", "content", "summary"):
            text = collect_openai_text(value.get(key))
            if text:
                chunks.append(text)
        return "\n".join(chunks).strip()
    return ""


def openai_chat_payload_shape(payload: dict[str, Any]) -> dict[str, Any]:
    choices = payload.get("choices")
    first = choices[0] if isinstance(choices, list) and choices and isinstance(choices[0], dict) else {}
    message = first.get("message") if isinstance(first.get("message"), dict) else {}
    usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    content = message.get("content")
    return {
        "topKeys": sorted(str(key) for key in payload.keys())[:24],
        "choiceKeys": sorted(str(key) for key in first.keys())[:24],
        "messageKeys": sorted(str(key) for key in message.keys())[:24],
        "contentType": type(content).__name__,
        "finishReason": first.get("finish_reason"),
        "usage": {
            "promptTokens": usage.get("prompt_tokens"),
            "completionTokens": usage.get("completion_tokens"),
            "totalTokens": usage.get("total_tokens"),
        },
    }


def function_call_from_openai_chat(payload: dict[str, Any]) -> Optional[dict[str, Any]]:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        return None
    first = choices[0] if isinstance(choices[0], dict) else {}
    message = first.get("message") if isinstance(first.get("message"), dict) else {}
    tool_calls = message.get("tool_calls")
    if not isinstance(tool_calls, list) or not tool_calls:
        return None
    call = tool_calls[0] if isinstance(tool_calls[0], dict) else {}
    function = call.get("function") if isinstance(call.get("function"), dict) else {}
    name = function.get("name")
    raw_arguments = function.get("arguments") or "{}"
    if not isinstance(name, str) or not name:
        return None
    try:
        arguments = json.loads(raw_arguments) if isinstance(raw_arguments, str) else raw_arguments
    except json.JSONDecodeError:
        arguments = {"raw": raw_arguments}
    if not isinstance(arguments, dict):
        arguments = {"value": arguments}
    return {"name": name, "arguments": arguments}


TEXT_TOOL_CALL_RE = re.compile(r"<tool_call\b[^>]*>(.*?)</tool_call>", re.IGNORECASE | re.DOTALL)
TEXT_FUNCTION_RE = re.compile(
    r"<function\s*=\s*[\"']?([A-Za-z0-9_.:-]+)[\"']?\s*>(.*?)</function>",
    re.IGNORECASE | re.DOTALL,
)
TEXT_PARAMETER_RE = re.compile(
    r"<parameter\s*=\s*[\"']?([A-Za-z0-9_.:-]+)[\"']?\s*>(.*?)</parameter>",
    re.IGNORECASE | re.DOTALL,
)
TEXT_TOOL_NAME_ALIASES = {
    "bash": "exec_command",
    "cmd": "exec_command",
    "command": "exec_command",
    "exec": "exec_command",
    "sh": "exec_command",
    "shell": "exec_command",
    "terminal": "exec_command",
    "read": "exec_command",
    "read_file": "exec_command",
}
TEXT_TOOL_ARGUMENT_ALIASES = {
    "exec_command": {
        "command": "cmd",
        "shell_command": "cmd",
    }
}


def function_call_from_text_tool_markup(text: str, declarations: list[dict[str, Any]]) -> Optional[dict[str, Any]]:
    if not text or "<tool_call" not in text:
        return None
    declared_names = {
        item.get("name")
        for item in declarations
        if isinstance(item, dict) and isinstance(item.get("name"), str) and item.get("name")
    }
    blocks = TEXT_TOOL_CALL_RE.findall(text)
    if not blocks:
        blocks = [text]
    for block in blocks:
        function_match = TEXT_FUNCTION_RE.search(block)
        if not function_match:
            continue
        raw_name = function_match.group(1).strip()
        name = normalize_text_tool_name(raw_name, declared_names)
        if not name:
            continue
        raw_params = {
            html.unescape(param_name).strip(): html.unescape(param_value).strip()
            for param_name, param_value in TEXT_PARAMETER_RE.findall(function_match.group(2))
        }
        arguments = normalize_text_tool_arguments(name, raw_params)
        if name == "exec_command" and not arguments.get("cmd"):
            continue
        return {"name": name, "arguments": arguments}
    return None


def normalize_text_tool_name(raw_name: str, declared_names: set[str]) -> Optional[str]:
    normalized = raw_name.strip().strip("\"'")
    candidates = [
        normalized,
        normalized.replace(".", "__"),
        TEXT_TOOL_NAME_ALIASES.get(normalized.lower(), ""),
    ]
    for candidate in candidates:
        if candidate and (not declared_names or candidate in declared_names):
            return candidate
    return None


def normalize_text_tool_arguments(name: str, raw_params: dict[str, str]) -> dict[str, Any]:
    aliases = TEXT_TOOL_ARGUMENT_ALIASES.get(name, {})
    if name == "exec_command" and not any(
        key.lower() in {"cmd", "command", "shell_command"} for key in raw_params
    ):
        read_path = raw_params.get("path") or raw_params.get("file") or raw_params.get("filename")
        if read_path:
            command = read_path_command(read_path)
            workdir = raw_params.get("workdir") or raw_params.get("cwd")
            arguments: dict[str, Any] = {"cmd": command}
            if workdir:
                arguments["workdir"] = workdir
            return arguments
    arguments: dict[str, Any] = {}
    for raw_key, value in raw_params.items():
        key = aliases.get(raw_key.lower(), raw_key)
        if name == "exec_command" and key not in {
            "cmd",
            "login",
            "max_output_tokens",
            "shell",
            "tty",
            "workdir",
            "yield_time_ms",
        }:
            continue
        if key in {"login", "tty"}:
            arguments[key] = value.lower() in {"1", "true", "yes", "y"}
        elif key in {"max_output_tokens", "yield_time_ms"}:
            try:
                arguments[key] = int(value)
            except ValueError:
                continue
        else:
            arguments[key] = value
    return arguments


def read_path_command(path_text: str) -> str:
    path_value = path_text.strip()
    if path_value.startswith("file://"):
        parsed = urlparse(path_value)
        if parsed.path:
            path_value = unquote(parsed.path)
    return f"sed -n '1,240p' {shlex.quote(path_value)}"


def openai_provider_config(provider_id: str, declarations: list[dict[str, Any]], image_part_count: int) -> dict[str, Any]:
    if provider_id == "deepseek":
        return {
            "providerId": "deepseek",
            "keys": deepseek_keys(),
            "missingError": "deepseek_keys_missing",
            "baseUrl": deepseek_base_url(),
            "headers": lambda key: {"Authorization": f"Bearer {key}"},
            "systemInstruction": deepseek_system_instruction(declarations, image_part_count),
            "enableTools": env_bool("ZHUDA_DEEPSEEK_ENABLE_TOOLS", True),
            "maxTokens": env_int("ZHUDA_DEEPSEEK_MAX_TOKENS", DEFAULT_DEEPSEEK_MAX_OUTPUT_TOKENS),
            "badRequestError": "deepseek_bad_request",
            "dailyQuotaError": "deepseek_daily_quota_exhausted",
            "cooldownError": "deepseek_cooling_down",
            "poolError": "deepseek_pool_failed",
            "contentMissingTag": "deepseek_content_missing",
        }
    return {
        "providerId": "mimo",
        "keys": mimo_keys(),
        "missingError": "mimo_keys_missing",
        "baseUrl": mimo_base_url(),
        "headers": lambda key: {"Authorization": f"Bearer {key}", "api-key": key},
        "systemInstruction": mimo_system_instruction(declarations, image_part_count),
        "enableTools": env_bool("ZHUDA_MIMO_ENABLE_TOOLS", False),
        "maxTokens": env_int("ZHUDA_MIMO_MAX_TOKENS", DEFAULT_MIMO_MAX_OUTPUT_TOKENS),
        "badRequestError": "mimo_bad_request",
        "dailyQuotaError": "mimo_daily_quota_exhausted",
        "cooldownError": "mimo_cooling_down",
        "poolError": "mimo_pool_failed",
        "contentMissingTag": "mimo_content_missing",
    }


async def call_openai_compatible(
    prompt: str,
    model: str,
    provider_id: str,
    declarations: Optional[list[dict[str, Any]]] = None,
    image_parts: Optional[list[dict[str, Any]]] = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    global cursor, last_upstream_call_at
    declarations = declarations or []
    image_parts = image_parts or []
    config = openai_provider_config(provider_id, declarations, len(image_parts))
    keys = config["keys"]
    if not keys:
        raise HTTPException(status_code=503, detail={"error": config["missingError"]})

    started = cursor
    cursor = (cursor + 1) % len(keys)
    errors: list[str] = []
    system_instruction = config["systemInstruction"]
    prompt_tokens_estimate = estimate_tokens(system_instruction + "\n\n" + prompt)
    large_prompt_threshold = large_prompt_token_threshold()
    is_large_prompt = prompt_tokens_estimate >= large_prompt_threshold

    max_key_attempts = min(len(keys), env_int("ZHUDA_MAX_KEY_ATTEMPTS", DEFAULT_MAX_KEY_ATTEMPTS))
    max_model_attempts = env_int("ZHUDA_MAX_MODEL_ATTEMPTS", DEFAULT_MAX_MODEL_ATTEMPTS)
    if is_large_prompt:
        max_model_attempts = min(
            max_model_attempts,
            env_int("ZHUDA_LARGE_PROMPT_MAX_MODEL_ATTEMPTS", DEFAULT_LARGE_PROMPT_MAX_MODEL_ATTEMPTS),
        )
    rate_limit_cooldown = rate_limit_cooldown_seconds()
    large_prompt_rate_limit_cooldown = large_prompt_rate_limit_cooldown_seconds()
    error_cooldown = error_cooldown_seconds()
    timeout_cooldown = timeout_cooldown_seconds()
    min_interval = env_int("ZHUDA_GLOBAL_MIN_INTERVAL_MS", int(DEFAULT_GLOBAL_MIN_INTERVAL_SECONDS * 1000)) / 1000
    large_prompt_min_interval = large_prompt_min_interval_seconds()
    candidates = upstream_model_candidates(model)[:max(1, max_model_attempts)]
    attempted = 0
    skipped_cooldown = 0
    daily_quota_errors: list[str] = []
    rate_limit_waited = 0.0
    upstream_timeout = upstream_timeout_seconds()
    base_url = config["baseUrl"]
    enable_tools = bool(config["enableTools"])

    async with upstream_state_lock:
        async with httpx.AsyncClient(timeout=upstream_timeout) as client:
            for candidate_model in candidates:
                candidate_attempts = 0
                offset = 0
                while offset < len(keys):
                    if candidate_attempts >= max_key_attempts:
                        break
                    key_index = (started + offset) % len(keys)
                    cooldown_key = (candidate_model, key_index)
                    now = time.monotonic()
                    cooldown_until = cooldowns.get(cooldown_key, 0)
                    if cooldown_until > now:
                        reason = cooldown_reasons.get(cooldown_key, "")
                        if reason == "daily_quota":
                            daily_quota_errors.append(f"{candidate_model}:key_{key_index + 1}:429:daily_quota_cooldown")
                            skipped_cooldown += 1
                            offset += 1
                            continue
                        wait_seconds = int(cooldown_until - now + 0.999)
                        rate_limit_waited += wait_seconds
                        if rate_limit_waited > rate_limit_max_wait_seconds():
                            errors.append(f"{candidate_model}:key_{key_index + 1}:429:short_rate_limit_wait_exceeded")
                            offset += 1
                            continue
                        log_pool_attempt(candidate_model, key_index + 1, 0, False, f"short_rate_limit_wait:{wait_seconds}s")
                        await sleep_for_short_rate_limit(wait_seconds)
                        clear_cooldown(cooldown_key)
                        now = time.monotonic()
                    key = keys[key_index]
                    model_interval = model_min_interval_seconds(candidate_model)
                    model_wait_for = model_interval - (now - last_model_call_at.get(candidate_model, 0))
                    large_prompt_wait_for = large_prompt_min_interval - (now - last_upstream_call_at) if is_large_prompt else 0
                    wait_for = max(
                        min_interval - (now - last_upstream_call_at),
                        model_wait_for,
                        large_prompt_wait_for,
                    )
                    if wait_for > 0:
                        await asyncio.sleep(wait_for)
                    last_upstream_call_at = time.monotonic()
                    last_model_call_at[candidate_model] = last_upstream_call_at
                    attempted += 1
                    candidate_attempts += 1
                    log_pool_start(candidate_model, key_index + 1, prompt_tokens_estimate, upstream_timeout, is_large_prompt)
                    body: dict[str, Any] = {
                        "model": candidate_model,
                        "messages": [
                            {"role": "system", "content": system_instruction},
                            {"role": "user", "content": prompt},
                        ],
                        "stream": False,
                        "temperature": 0.2,
                        "max_tokens": config["maxTokens"],
                    }
                    if enable_tools and declarations:
                        body["tools"] = [
                            {
                                "type": "function",
                                "function": {
                                    "name": declaration.get("name"),
                                    "description": declaration.get("description", ""),
                                    "parameters": declaration.get("parameters") or {},
                                },
                            }
                            for declaration in declarations
                        ]
                        body["tool_choice"] = "auto"
                    try:
                        response = await client.post(
                            f"{base_url}/chat/completions",
                            headers=config["headers"](key),
                            json=body,
                        )
                    except httpx.TimeoutException as error:
                        error_text = f"{candidate_model}:key_{key_index + 1}:timeout_after_{upstream_timeout}s:{error}"
                        errors.append(error_text)
                        log_pool_attempt(candidate_model, key_index + 1, 0, False, error_text)
                        set_cooldown(cooldown_key, timeout_cooldown, "timeout")
                        offset += 1
                        continue
                    except httpx.HTTPError as error:
                        error_text = f"{candidate_model}:key_{key_index + 1}:http_error:{type(error).__name__}:{error}"
                        errors.append(error_text)
                        log_pool_attempt(candidate_model, key_index + 1, 0, False, error_text)
                        set_cooldown(cooldown_key, error_cooldown, "http_error")
                        offset += 1
                        continue
                    log_pool_attempt(
                        model=candidate_model,
                        key_index=key_index + 1,
                        status=response.status_code,
                        ok=response.is_success,
                        error="" if response.is_success else response.text,
                    )
                    if response.is_success:
                        payload = response.json()
                        clear_cooldown(cooldown_key)
                        function_call = function_call_from_openai_chat(payload)
                        if function_call:
                            log_pool_summary(model, attempted, skipped_cooldown, errors)
                            return {"type": "function_call", **function_call}, payload
                        text = output_text_from_openai_chat(payload)
                        text_function_call = function_call_from_text_tool_markup(text, declarations or [])
                        if text_function_call:
                            log_pool_summary(model, attempted, skipped_cooldown, errors)
                            return {"type": "function_call", **text_function_call}, payload
                        if text:
                            log_pool_summary(model, attempted, skipped_cooldown, errors)
                            return {"type": "text", "text": clean_model_meta_text(text)}, payload
                        shape = json.dumps(openai_chat_payload_shape(payload), ensure_ascii=False, separators=(",", ":"))
                        errors.append(f"{candidate_model}:{config['contentMissingTag']}:{shape[:600]}")
                        offset += 1
                        continue
                    errors.append(upstream_error_text(candidate_model, key_index + 1, response.status_code, response.text))
                    if response.status_code == 400:
                        log_pool_summary(model, attempted, skipped_cooldown, errors)
                        raise HTTPException(status_code=400, detail={"error": config["badRequestError"], "details": errors[-3:]})
                    if response.status_code == 429:
                        if is_daily_quota_error(response.text):
                            daily_error = (
                                f"{candidate_model}:key_{key_index + 1}:429:daily_quota_exhausted:"
                                f"{safe_upstream_text(response.text)}"
                            )
                            daily_quota_errors.append(daily_error)
                            set_cooldown(cooldown_key, env_int("ZHUDA_DAILY_QUOTA_COOLDOWN_SECONDS", 12 * 60 * 60), "daily_quota")
                            offset += 1
                            continue
                        cooldown = rate_limit_wait_seconds(response.text, rate_limit_cooldown, is_large_prompt)
                        rate_limit_waited += cooldown
                        if rate_limit_waited > rate_limit_max_wait_seconds():
                            errors.append(
                                f"{candidate_model}:key_{key_index + 1}:429:short_rate_limit_wait_exceeded:"
                                f"{safe_upstream_text(response.text)}"
                            )
                            offset += 1
                            continue
                        set_cooldown(cooldown_key, cooldown, "short_rate_limit")
                        log_pool_attempt(candidate_model, key_index + 1, 0, False, f"short_rate_limit_wait:{cooldown}s")
                        await sleep_for_short_rate_limit(cooldown)
                        clear_cooldown(cooldown_key)
                        candidate_attempts = max(0, candidate_attempts - 1)
                        continue
                    if response.status_code in {500, 502, 503, 504}:
                        set_cooldown(cooldown_key, max(error_cooldown, timeout_cooldown), "server_error")
                    if response.status_code not in RETRYABLE_UPSTREAM_STATUSES:
                        break
                    offset += 1

    log_pool_summary(model, attempted, skipped_cooldown, errors)
    if daily_quota_errors:
        raise HTTPException(status_code=429, detail={"error": config["dailyQuotaError"], "details": daily_quota_errors[-3:]})
    if attempted == 0 and skipped_cooldown:
        raise HTTPException(
            status_code=503,
            detail={
                "error": config["cooldownError"],
                "cooldownSeconds": cooldown_remaining_seconds(candidates, len(keys)),
                "details": errors[-3:],
            },
        )
    raise HTTPException(status_code=502, detail={"error": config["poolError"], "details": errors[-3:]})


async def call_mimo(
    prompt: str,
    model: str,
    declarations: Optional[list[dict[str, Any]]] = None,
    image_parts: Optional[list[dict[str, Any]]] = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    return await call_openai_compatible(prompt, model, "mimo", declarations, image_parts)


async def call_deepseek(
    prompt: str,
    model: str,
    declarations: Optional[list[dict[str, Any]]] = None,
    image_parts: Optional[list[dict[str, Any]]] = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    return await call_openai_compatible(prompt, model, "deepseek", declarations, image_parts)


async def call_upstream(
    prompt: str,
    model: str,
    declarations: Optional[list[dict[str, Any]]] = None,
    image_parts: Optional[list[dict[str, Any]]] = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    provider = current_provider()
    if provider == "mimo":
        return await call_mimo(prompt, model, declarations, image_parts)
    if provider == "deepseek":
        return await call_deepseek(prompt, model, declarations, image_parts)
    return await call_gemini(prompt, model, declarations, image_parts)


def response_object(response_id: str, model: str, text: str, status: str = "completed") -> dict[str, Any]:
    item_id = f"msg_{uuid.uuid4().hex}"
    return {
        "id": response_id,
        "object": "response",
        "created_at": int(time.time()),
        "status": status,
        "error": None,
        "incomplete_details": None,
        "instructions": None,
        "model": model,
        "output": [
            {
                "id": item_id,
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [
                    {
                        "type": "output_text",
                        "text": text,
                        "annotations": [],
                    }
                ],
            }
        ],
        "parallel_tool_calls": False,
        "tool_choice": "auto",
        "tools": [],
        "usage": None,
    }


def function_call_response_object(response_id: str, model: str, call_id: str, item_id: str, name: str, arguments: str) -> dict[str, Any]:
    return {
        "id": response_id,
        "object": "response",
        "created_at": int(time.time()),
        "status": "completed",
        "error": None,
        "incomplete_details": None,
        "instructions": None,
        "model": model,
        "output": [
            {
                "id": item_id,
                "type": "function_call",
                "call_id": call_id,
                "name": name,
                "arguments": arguments,
                "status": "completed",
            }
        ],
        "parallel_tool_calls": False,
        "tool_choice": "auto",
        "tools": [],
        "usage": None,
    }


def sse_event(event: dict[str, Any]) -> str:
    return f"data: {json.dumps(event, ensure_ascii=False)}\n\n"


def visible_error_text(
    model: str,
    upstream_model: str,
    error: Exception,
    prompt_tokens_estimate: int = 0,
    image_part_count: int = 0,
) -> str:
    provider_name = provider_display_name()
    detail = getattr(error, "detail", None)
    details = []
    if isinstance(detail, dict):
        raw_details = detail.get("details")
        if isinstance(raw_details, list):
            details = [str(item) for item in raw_details]
    detail_text = "\n".join(details)
    status_codes = sorted(set(re.findall(r":([1-5][0-9]{2}):", detail_text)))
    status_summary = ", ".join(status_codes) if status_codes else str(getattr(error, "status_code", "unknown"))
    detail_error = str(detail.get("error", "")) if isinstance(detail, dict) else ""
    timeout_match = re.search(r"timeout_after_(\d+)s", detail_text)
    if "content_missing" in detail_text:
        reason = "empty or unsupported upstream response"
        status_summary = "200 (empty/unsupported content)"
        suggestion = (
            f"{provider_name} returned HTTP 200 but no parseable message content or tool call. "
            "The adapter now parses more OpenAI-like fields and trims large tool outputs more aggressively; "
            "retry this turn after relaunching the adapter."
        )
    elif detail_error.endswith("_cooling_down"):
        reason = "adapter cooldown after recent upstream failure"
        status_summary = "cooldown"
        cooldown_seconds = detail.get("cooldownSeconds") if isinstance(detail, dict) else None
        cooldown_text = f"約 {cooldown_seconds} 秒" if isinstance(cooldown_seconds, int) and cooldown_seconds > 0 else "短暫"
        suggestion = (
            f"上游剛剛失敗，adapter 這輪沒有再燒請求，而是進入 {cooldown_text} 冷卻。"
            "稍等後重試，或切到另一個模型。"
        )
    elif "gemini_upstream_timeout" in str(detail) or "timeout_after" in detail_text:
        reason = "upstream timeout"
        status_summary = "timeout"
        timeout_seconds: Optional[int] = None
        if isinstance(detail, dict):
            timeout_seconds = detail.get("timeoutSeconds")
        if timeout_seconds is None and timeout_match:
            try:
                timeout_seconds = int(timeout_match.group(1))
            except ValueError:
                timeout_seconds = None
        timeout_seconds = timeout_seconds or upstream_timeout_seconds()
        if current_provider() in {"mimo", "deepseek"}:
            suggestion = (
                f"{provider_name} 上游超過 {timeout_seconds} 秒沒有完成；這通常不是餘額不足，而是長上下文、工具歷史或上游擁塞。"
                "adapter 已正常結束這輪並進入冷卻，避免 Codex 一直卡在「正在思考」。"
                "如果同一任務連續發生，先 /compact 或切較輕的模型再試。"
            )
        else:
            suggestion = (
                f"上游呼叫超過 {timeout_seconds} 秒沒有完成，"
                "adapter 已改成正常結束這輪，避免 Codex 一直卡在「正在思考」。"
            )
    elif "input token count exceeds" in detail_text.lower() or "gemini_input_too_large" in str(detail):
        reason = "input context too large"
        suggestion = "Start a new chat or use /compact if the current thread has grown too large."
    elif "401" in status_codes:
        reason = "API key rejected"
        suggestion = "The upstream rejected this API key. Reopen the launcher, paste a fresh key, and activate the provider again."
    elif "400" in status_codes:
        reason = "bad upstream request"
        suggestion = "The provider rejected the request format. The adapter logs include the upstream body for debugging."
    elif detail_error.endswith("_daily_quota_exhausted") or is_daily_quota_error(detail_text):
        reason = "daily quota exhausted"
        status_summary = "429"
        suggestion = (
            "今天這個上游模型的 API 日額度用完啦，請在 Codex 左下角模型選單切到其他映射模型。"
            "明天配額重置後，可以再切回來。"
        )
    elif "short_rate_limit_wait_exceeded" in detail_text:
        reason = "minute/token rate limit kept retrying too long"
        status_summary = "429"
        suggestion = (
            "這不是日額度用完，而是 TPM/RPM 短窗口一直沒有恢復。"
            "正常情況 adapter 會等待並重試；如果等超過上限才會結束這輪，避免無限掛住。"
        )
    elif "429" in status_codes or "quota" in detail_text.lower():
        reason = "quota/rate limit exhausted or burst-limited"
        large_prompt_threshold = large_prompt_token_threshold()
        if prompt_tokens_estimate >= large_prompt_threshold:
            image_note = f", with {image_part_count} inline image(s)" if image_part_count else ""
            suggestion = (
                f"這輪送上游前仍有約 {prompt_tokens_estimate:,} estimated tokens{image_note}，"
                "比較容易撞到 TPM 或 burst limit。先用 /compact 或開新 chat 會最有效；"
                "adapter 已降低長上下文 fallback 與圖片重送。"
            )
        else:
            suggestion = "Wait for the cooldown window, then retry. The adapter now limits retries and slows model calls to avoid burning the whole key pool."
    elif current_provider() in {"mimo", "deepseek"} and any(code in status_codes for code in ("500", "502", "503", "504")):
        reason = f"{provider_name} gateway/server error"
        suggestion = (
            f"{provider_name} 上游回了 5xx，這通常和餘額無關，比較像供應商 gateway、模型忙碌或長上下文處理不穩。"
            "adapter 已把這類錯誤放入較長冷卻；短暫等待、/compact，或切到較輕模型通常比立刻連續重試有效。"
        )
    elif current_provider() == "gemini" and any(code in status_codes for code in ("500", "502", "503", "504")):
        reason = "Gemini upstream server/high-demand error"
        suggestion = (
            "這通常和 API key 餘額無關，而是 Gemini 上游模型暫時高需求或服務端不穩。"
            "adapter 會尊重你目前選的模型，不會自動切換；短暫等待後重試，或你手動切到其他模型。"
        )
    else:
        reason = "upstream request failed"
        if forced_upstream_model():
            suggestion = (
                f"The adapter is currently forced to `{forced_upstream_model()}` with model fallback disabled. "
                "Retry after a short pause; this keeps the request on the forced upstream model."
            )
        else:
            suggestion = "短暫等待後重試；要換模型請你手動在 Codex 模型選單切換，adapter 不會代你切。"
    upstream_messages = upstream_error_messages(details)
    if upstream_messages:
        upstream_section = "\n\n".join(f"```text\n{message}\n```" for message in upstream_messages)
    else:
        upstream_section = "```text\n沒有上游原始錯誤訊息；這是 adapter 本地判斷或本地冷卻狀態。\n```"
    return (
        f"Zhuda {provider_name} adapter could not complete this turn.\n\n"
        f"上游原始訊息\n{upstream_section}\n\n"
        f"Zhuda adapter 解釋\n"
        f"- Codex model: {model}\n"
        f"- Selected upstream: {upstream_model}\n"
        f"- Reason: {reason}\n"
        f"- Upstream status: {status_summary}\n"
        f"- 模型切換：adapter 不會自動切到其他模型；你選哪個模型，這輪就只打哪個模型。\n"
        f"- 回傳方式：adapter 把這輪包成正常 completed response，避免 Codex 卡在 reconnecting 或正在思考。\n"
        f"- 建議：{suggestion}"
    )


async def stream_response(payload: dict[str, Any], model: str):
    started_at = time.monotonic()
    response_id = f"resp_{uuid.uuid4().hex}"
    item_id = f"msg_{uuid.uuid4().hex}"
    created = int(time.time())
    created_response = {
        "id": response_id,
        "object": "response",
        "created_at": created,
        "status": "in_progress",
        "model": model,
        "output": [],
    }
    yield sse_event({"type": "response.created", "response": created_response})

    prompt = extract_input_text(payload)
    prompt_tokens_estimate = estimate_tokens(prompt)
    declarations = gemini_function_declarations(payload)
    upstream_model = payload.get("_zhuda_upstream_model") or resolve_model(model)
    image_parts = extract_gemini_image_parts(payload, prompt_tokens_estimate)
    guard_text = (
        repeated_visual_tool_guard_text(payload, len(image_parts))
        or repeated_tool_call_guard_text(payload)
    )
    upstream_payload: Optional[dict[str, Any]] = None
    error_summary: Optional[dict[str, Any]] = None
    if guard_text:
        result = {"type": "text", "text": guard_text}
    else:
        try:
            upstream_task = asyncio.create_task(call_upstream(prompt, upstream_model, declarations, image_parts))
            heartbeat_interval = stream_heartbeat_interval_seconds()
            while True:
                done, _ = await asyncio.wait({upstream_task}, timeout=heartbeat_interval)
                if upstream_task in done:
                    result, upstream_payload = upstream_task.result()
                    break
                heartbeat_response = dict(created_response)
                heartbeat_response["status"] = "in_progress"
                heartbeat_response["output"] = []
                yield sse_event({"type": "response.in_progress", "response": heartbeat_response})
        except Exception as error:
            error_summary = summarize_exception(error)
            result = {
                "type": "text",
                "text": visible_error_text(model, upstream_model, error, prompt_tokens_estimate, len(image_parts)),
            }

    if result["type"] == "function_call":
        name = result["name"]
        arguments = json.dumps(result.get("arguments") or {}, ensure_ascii=False)
        call_id = f"call_{uuid.uuid4().hex}"
        function_item_id = f"fc_{uuid.uuid4().hex}"
        item = {
            "id": function_item_id,
            "type": "function_call",
            "call_id": call_id,
            "name": name,
            "arguments": "",
            "status": "in_progress",
        }
        yield sse_event({"type": "response.output_item.added", "response_id": response_id, "output_index": 0, "item": item})
        yield sse_event({
            "type": "response.function_call_arguments.delta",
            "response_id": response_id,
            "item_id": function_item_id,
            "output_index": 0,
            "delta": arguments,
        })
        yield sse_event({
            "type": "response.function_call_arguments.done",
            "response_id": response_id,
            "item_id": function_item_id,
            "output_index": 0,
            "arguments": arguments,
        })
        completed_item = {
            "id": function_item_id,
            "type": "function_call",
            "call_id": call_id,
            "name": name,
            "arguments": arguments,
            "status": "completed",
        }
        yield sse_event({
            "type": "response.output_item.done",
            "response_id": response_id,
            "output_index": 0,
            "item": completed_item,
        })
        completed = function_call_response_object(response_id, model, call_id, function_item_id, name, arguments)
        log_episode({
            "created_at": created,
            "responseId": response_id,
            "stream": True,
            "status": "completed",
            "durationMs": int((time.monotonic() - started_at) * 1000),
            "codexModel": model,
            "upstreamModel": upstream_model,
            "promptChars": len(prompt),
            "promptTokensEstimate": prompt_tokens_estimate,
            "requestTools": summarize_request_tools(payload),
            "declaredTools": {
                "count": len(declarations),
                "names": [item.get("name") for item in declarations[:120]],
            },
            "images": summarize_images(image_parts),
            "input": summarize_input_items(payload),
            "guardTriggered": bool(guard_text),
            "result": summarize_result(result),
            "upstream": summarize_upstream_payload(upstream_payload),
            "error": error_summary,
        })
        yield sse_event({"type": "response.completed", "response": completed})
        return

    text = result["text"]

    yield sse_event(
        {
            "type": "response.output_item.added",
            "response_id": response_id,
            "output_index": 0,
            "item": {
                "id": item_id,
                "type": "message",
                "status": "in_progress",
                "role": "assistant",
                "content": [],
            },
        }
    )
    yield sse_event(
        {
            "type": "response.content_part.added",
            "response_id": response_id,
            "item_id": item_id,
            "output_index": 0,
            "content_index": 0,
            "part": {"type": "output_text", "text": "", "annotations": []},
        }
    )
    await asyncio.sleep(0)
    yield sse_event(
        {
            "type": "response.output_text.delta",
            "response_id": response_id,
            "item_id": item_id,
            "output_index": 0,
            "content_index": 0,
            "delta": text,
        }
    )
    yield sse_event(
        {
            "type": "response.output_text.done",
            "response_id": response_id,
            "item_id": item_id,
            "output_index": 0,
            "content_index": 0,
            "text": text,
        }
    )
    content_part = {"type": "output_text", "text": text, "annotations": []}
    yield sse_event(
        {
            "type": "response.content_part.done",
            "response_id": response_id,
            "item_id": item_id,
            "output_index": 0,
            "content_index": 0,
            "part": content_part,
        }
    )
    output_item = {
        "id": item_id,
        "type": "message",
        "status": "completed",
        "role": "assistant",
        "content": [content_part],
    }
    yield sse_event(
        {
            "type": "response.output_item.done",
            "response_id": response_id,
            "output_index": 0,
            "item": output_item,
        }
    )
    completed = response_object(response_id, model, text)
    completed["output"][0]["id"] = item_id
    log_episode({
        "created_at": created,
        "responseId": response_id,
        "stream": True,
        "status": "completed",
        "durationMs": int((time.monotonic() - started_at) * 1000),
        "codexModel": model,
        "upstreamModel": upstream_model,
        "promptChars": len(prompt),
        "promptTokensEstimate": prompt_tokens_estimate,
        "requestTools": summarize_request_tools(payload),
        "declaredTools": {
            "count": len(declarations),
            "names": [item.get("name") for item in declarations[:120]],
        },
        "images": summarize_images(image_parts),
        "input": summarize_input_items(payload),
        "guardTriggered": bool(guard_text),
        "result": summarize_result(result),
        "upstream": summarize_upstream_payload(upstream_payload),
        "error": error_summary,
    })
    yield sse_event({"type": "response.completed", "response": completed})


def redact_log_text(text: str) -> str:
    text = API_KEY_RE.sub("<redacted-api-key>", text)
    return ENV_KEY_RE.sub(r"\1<redacted-api-key>", text)


def log_path_for_name(file_name: str) -> Path:
    if file_name not in LOG_FILE_NAMES:
        raise HTTPException(status_code=404, detail={"error": "log_file_not_found"})
    return ROOT / file_name


def format_bytes(size: int) -> str:
    value = float(size)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
    return f"{size} B"


def format_epoch(epoch: float) -> str:
    if epoch <= 0:
        return "-"
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(epoch))


def tail_log_lines(path: Path, max_lines: int) -> list[str]:
    if not path.exists():
        return []
    max_lines = max(1, min(LOG_TAIL_MAX_LINES, max_lines))
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            if size > LOG_TAIL_MAX_BYTES:
                handle.seek(max(0, size - LOG_TAIL_MAX_BYTES))
            data = handle.read()
    except OSError as error:
        return [f"read failed: {error}"]
    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines()
    if path.stat().st_size > LOG_TAIL_MAX_BYTES and lines:
        lines[0] = f"[truncated to last {format_bytes(LOG_TAIL_MAX_BYTES)}] {lines[0]}"
    return [redact_log_text(line) for line in lines[-max_lines:]]


def log_adapter_status() -> dict[str, Any]:
    provider = current_provider()
    keys = provider_keys(provider)
    now = time.monotonic()
    active_cooldowns = [
        {
            "model": model,
            "keyIndex": key_index + 1,
            "remainingSeconds": max(0, int(until - now)),
            "reason": cooldown_reasons.get((model, key_index), ""),
        }
        for (model, key_index), until in cooldowns.items()
        if until > now
    ]
    return {
        "provider": provider,
        "providerName": provider_display_name(provider),
        "keyCount": len(keys),
        "forceUpstreamModel": forced_upstream_model(),
        "nextKeyIndex": (cursor % max(len(keys), 1)) + 1,
        "upstreamTimeoutSeconds": upstream_timeout_seconds(),
        "maxKeyAttempts": env_int("ZHUDA_MAX_KEY_ATTEMPTS", DEFAULT_MAX_KEY_ATTEMPTS),
        "activeCooldowns": active_cooldowns,
    }


def log_tail_payload(file_name: str, lines: int = LOG_TAIL_DEFAULT_LINES) -> dict[str, Any]:
    path = log_path_for_name(file_name)
    try:
        stat = path.stat()
        size = stat.st_size
        mtime = stat.st_mtime
    except OSError:
        size = 0
        mtime = 0
    return {
        "file": file_name,
        "label": next((label for label, name in LOG_FILES if name == file_name), file_name),
        "size": size,
        "sizeText": format_bytes(size),
        "mtime": mtime,
        "mtimeText": format_epoch(mtime),
        "generatedAt": int(time.time()),
        "generatedAtText": format_epoch(time.time()),
        "lines": tail_log_lines(path, lines),
        "adapter": log_adapter_status(),
    }


async def log_event_stream(file_name: str, lines: int, interval: float):
    interval = max(0.5, min(10.0, interval))
    last_key = ""
    while True:
        payload = log_tail_payload(file_name, lines)
        key = f"{payload['size']}:{payload['mtime']}:{len(payload['adapter']['activeCooldowns'])}"
        if key != last_key:
            yield sse_event({"type": "log.update", "payload": payload})
            last_key = key
        await asyncio.sleep(interval)


@app.get("/logs", response_class=HTMLResponse)
async def logs_page():
    return HTMLResponse(LOG_DASHBOARD_HTML)


@app.get("/logs/api/files")
async def logs_files():
    files = []
    for label, file_name in LOG_FILES:
        path = ROOT / file_name
        try:
            stat = path.stat()
            size = stat.st_size
            mtime = stat.st_mtime
        except OSError:
            size = 0
            mtime = 0
        files.append({
            "label": label,
            "file": file_name,
            "size": size,
            "sizeText": format_bytes(size),
            "mtime": mtime,
            "mtimeText": format_epoch(mtime),
            "exists": path.exists(),
        })
    return {"files": files, "adapter": log_adapter_status()}


@app.get("/logs/api/tail")
async def logs_tail(file: str = "adapter.episodes.jsonl", lines: int = LOG_TAIL_DEFAULT_LINES):
    return log_tail_payload(file, lines)


@app.get("/logs/events")
async def logs_events(file: str = "adapter.episodes.jsonl", lines: int = LOG_TAIL_DEFAULT_LINES, interval: float = 1.0):
    log_path_for_name(file)
    return StreamingResponse(log_event_stream(file, lines, interval), media_type="text/event-stream")


@app.get("/health/readiness")
async def readiness():
    provider = current_provider()
    keys = provider_keys(provider)
    selected_codex_model = os.environ.get("ZHUDA_SELECTED_CODEX_MODEL", "").strip()
    selected_upstream_model = os.environ.get("ZHUDA_SELECTED_UPSTREAM_MODEL", "").strip()
    return {
        "status": "healthy",
        "provider": provider,
        "keys": len(keys),
        "adapter": f"zhuda-codex-{provider}-adapter",
        "models": visible_model_ids(),
        "forceUpstreamModel": forced_upstream_model(),
        "selectedCodeModel": selected_codex_model,
        "selectedUpstreamModel": selected_upstream_model,
        "nextKeyIndex": (cursor % max(len(keys), 1)) + 1,
    }


@app.get("/pool/status")
async def pool_status():
    provider = current_provider()
    keys = provider_keys(provider)
    selected_codex_model = os.environ.get("ZHUDA_SELECTED_CODEX_MODEL", "").strip()
    selected_upstream_model = os.environ.get("ZHUDA_SELECTED_UPSTREAM_MODEL", "").strip()
    now = time.monotonic()
    active_cooldowns = [
        {
            "model": model,
            "keyIndex": key_index + 1,
            "remainingSeconds": max(0, int(until - now)),
            "reason": cooldown_reasons.get((model, key_index), ""),
        }
        for (model, key_index), until in cooldowns.items()
        if until > now
    ]
    return {
        "provider": provider,
        "providerName": provider_display_name(provider),
        "keyCount": len(keys),
        "nextKeyIndex": (cursor % max(len(keys), 1)) + 1,
        "keyFingerprints": [
            {"index": index + 1, "fingerprint": key_fingerprint(key)}
            for index, key in enumerate(keys)
        ],
        "models": model_aliases(),
        "visibleModels": visible_model_ids(),
        "forceUpstreamModel": forced_upstream_model(),
        "selectedCodeModel": selected_codex_model,
        "selectedUpstreamModel": selected_upstream_model,
        "runtime": {
            "maxInputTokens": max_input_tokens_limit(),
            "maxPinnedTokens": max_pinned_tokens_limit(),
            "maxHistoryItemTokens": max_history_item_tokens_limit(),
            "maxToolOutputChars": max_tool_output_chars_limit(),
            "maxKeyAttempts": env_int("ZHUDA_MAX_KEY_ATTEMPTS", DEFAULT_MAX_KEY_ATTEMPTS),
            "maxModelAttempts": env_int("ZHUDA_MAX_MODEL_ATTEMPTS", DEFAULT_MAX_MODEL_ATTEMPTS),
            "upstreamTimeoutSeconds": upstream_timeout_seconds(),
            "maxRepeatVisualToolCalls": env_int("ZHUDA_MAX_REPEAT_VISUAL_TOOL_CALLS", DEFAULT_MAX_REPEAT_VISUAL_TOOL_CALLS),
            "maxRepeatToolCalls": env_int("ZHUDA_MAX_REPEAT_TOOL_CALLS", DEFAULT_MAX_REPEAT_TOOL_CALLS),
            "repeatGuardsDisabled": env_bool("ZHUDA_DISABLE_REPEAT_GUARDS"),
            "repeatToolLookbackItems": env_int("ZHUDA_REPEAT_TOOL_LOOKBACK_ITEMS", DEFAULT_REPEAT_TOOL_LOOKBACK_ITEMS),
            "imageLookbackItems": env_int("ZHUDA_IMAGE_LOOKBACK_ITEMS", DEFAULT_IMAGE_LOOKBACK_ITEMS),
            "maxInlineImages": env_int("ZHUDA_MAX_INLINE_IMAGES", DEFAULT_MAX_INLINE_IMAGES),
            "maxInlineImageBytes": env_int("ZHUDA_MAX_INLINE_IMAGE_BYTES", DEFAULT_MAX_INLINE_IMAGE_BYTES),
            "maxInlineImageTotalBytes": env_int("ZHUDA_MAX_INLINE_IMAGE_TOTAL_BYTES", DEFAULT_MAX_INLINE_IMAGE_TOTAL_BYTES),
            "largePromptTokenThreshold": large_prompt_token_threshold(),
            "largePromptMaxInlineImages": env_int("ZHUDA_LARGE_PROMPT_MAX_INLINE_IMAGES", DEFAULT_LARGE_PROMPT_MAX_INLINE_IMAGES),
            "largePromptMaxModelAttempts": env_int("ZHUDA_LARGE_PROMPT_MAX_MODEL_ATTEMPTS", DEFAULT_LARGE_PROMPT_MAX_MODEL_ATTEMPTS),
            "largePromptMinIntervalMs": int(large_prompt_min_interval_seconds() * 1000),
            "largePromptRateLimitCooldownSeconds": large_prompt_rate_limit_cooldown_seconds(),
            "rateLimitCooldownSeconds": rate_limit_cooldown_seconds(),
            "errorCooldownSeconds": error_cooldown_seconds(),
            "timeoutCooldownSeconds": timeout_cooldown_seconds(),
            "globalMinIntervalMs": env_int("ZHUDA_GLOBAL_MIN_INTERVAL_MS", int(DEFAULT_GLOBAL_MIN_INTERVAL_SECONDS * 1000)),
            "activeCooldowns": active_cooldowns,
        },
    }


@app.get("/v1/models")
async def models(authorization: Optional[str] = Header(default=None)):
    check_auth(authorization)
    return {
        "object": "list",
        "data": [
            {
                "id": public_id,
                "object": "model",
                "owned_by": f"zhuda-codex-{current_provider()}-adapter",
            }
            for public_id in visible_model_ids()
        ],
    }


@app.post("/v1/responses")
async def responses(request: Request, authorization: Optional[str] = Header(default=None)):
    started_at = time.monotonic()
    check_auth(authorization)
    payload = await request.json()
    debug_log_request(payload)
    model = payload.get("model") or DEFAULT_MODEL
    upstream_model = resolve_model(model)
    if payload.get("stream", True):
        payload["_zhuda_upstream_model"] = upstream_model
        return StreamingResponse(stream_response(payload, model), media_type="text/event-stream")

    prompt = extract_input_text(payload)
    prompt_tokens_estimate = estimate_tokens(prompt)
    declarations = gemini_function_declarations(payload)
    image_parts = extract_gemini_image_parts(payload, prompt_tokens_estimate)
    guard_text = (
        repeated_visual_tool_guard_text(payload, len(image_parts))
        or repeated_tool_call_guard_text(payload)
    )
    upstream_payload: Optional[dict[str, Any]] = None
    error_summary: Optional[dict[str, Any]] = None
    if guard_text:
        result = {"type": "text", "text": guard_text}
    else:
        try:
            result, upstream_payload = await call_upstream(prompt, upstream_model, declarations, image_parts)
        except Exception as error:
            error_summary = summarize_exception(error)
            text = visible_error_text(model, upstream_model, error, prompt_tokens_estimate, len(image_parts))
            response_id = f"resp_{uuid.uuid4().hex}"
            result = {"type": "text", "text": text}
            log_episode({
                "created_at": int(time.time()),
                "responseId": response_id,
                "stream": False,
                "status": "completed_with_visible_error",
                "durationMs": int((time.monotonic() - started_at) * 1000),
                "codexModel": model,
                "upstreamModel": upstream_model,
                "promptChars": len(prompt),
                "promptTokensEstimate": prompt_tokens_estimate,
                "requestTools": summarize_request_tools(payload),
                "declaredTools": {
                    "count": len(declarations),
                    "names": [item.get("name") for item in declarations[:120]],
                },
                "images": summarize_images(image_parts),
                "input": summarize_input_items(payload),
                "guardTriggered": bool(guard_text),
                "result": summarize_result(result),
                "upstream": summarize_upstream_payload(upstream_payload),
                "error": error_summary,
            })
            return JSONResponse(response_object(response_id, model, text))
    if result["type"] == "function_call":
        response_id = f"resp_{uuid.uuid4().hex}"
        call_id = f"call_{uuid.uuid4().hex}"
        item_id = f"fc_{uuid.uuid4().hex}"
        arguments = json.dumps(result.get("arguments") or {}, ensure_ascii=False)
        log_episode({
            "created_at": int(time.time()),
            "responseId": response_id,
            "stream": False,
            "status": "completed",
            "durationMs": int((time.monotonic() - started_at) * 1000),
            "codexModel": model,
            "upstreamModel": upstream_model,
            "promptChars": len(prompt),
            "promptTokensEstimate": prompt_tokens_estimate,
            "requestTools": summarize_request_tools(payload),
            "declaredTools": {
                "count": len(declarations),
                "names": [item.get("name") for item in declarations[:120]],
            },
            "images": summarize_images(image_parts),
            "input": summarize_input_items(payload),
            "guardTriggered": bool(guard_text),
            "result": summarize_result(result),
            "upstream": summarize_upstream_payload(upstream_payload),
            "error": error_summary,
        })
        return JSONResponse(function_call_response_object(response_id, model, call_id, item_id, result["name"], arguments))
    text = result["text"]
    response_id = f"resp_{uuid.uuid4().hex}"
    log_episode({
        "created_at": int(time.time()),
        "responseId": response_id,
        "stream": False,
        "status": "completed",
        "durationMs": int((time.monotonic() - started_at) * 1000),
        "codexModel": model,
        "upstreamModel": upstream_model,
        "promptChars": len(prompt),
        "promptTokensEstimate": prompt_tokens_estimate,
        "requestTools": summarize_request_tools(payload),
        "declaredTools": {
            "count": len(declarations),
            "names": [item.get("name") for item in declarations[:120]],
        },
        "images": summarize_images(image_parts),
        "input": summarize_input_items(payload),
        "guardTriggered": bool(guard_text),
        "result": summarize_result(result),
        "upstream": summarize_upstream_payload(upstream_payload),
        "error": error_summary,
    })
    return JSONResponse(response_object(response_id, model, text))
