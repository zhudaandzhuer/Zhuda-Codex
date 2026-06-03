#!/usr/bin/env python3
import argparse
import base64
import html
import json
import os
import re
import secrets
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


DOWNLOAD_DIR = Path.home() / ".zhuda-codex" / "downloads"
CONTROL_TOKEN_FILE = Path.home() / ".zhuda-codex" / "control_token"

SECRET_PATTERNS = [
    (re.compile(r"(?i)data:[^,\s]{1,120};base64,[A-Za-z0-9+/=\r\n]{512,}"), "<redacted-long-data-url-base64-blob>"),
    (re.compile(r"(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{512,}={0,2}(?![A-Za-z0-9+/=])"), "<redacted-long-base64-like-blob>"),
    (re.compile(r"AIza[0-9A-Za-z_-]{20,}"), "<redacted-google-api-key>"),
    (re.compile(r"sk-[0-9A-Za-z_-]{20,}"), "<redacted-openai-key>"),
    (re.compile(r"AQ\.[0-9A-Za-z_-]{20,}"), "<redacted-token>"),
    (re.compile(r"(?i)(authorization\s*[:=]\s*bearer\s+)[0-9A-Za-z._~+/=-]{8,}"), r"\1<redacted-bearer>"),
    (re.compile(r"(?i)(api[_-]?key\s*[:=]\s*)[0-9A-Za-z._~+/=-]{8,}"), r"\1<redacted-api-key>"),
]


def redact_text(value):
    if value is None:
        return ""
    text = str(value)
    for pattern, replacement in SECRET_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def redact(value):
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, list):
        return [redact(item) for item in value]
    if isinstance(value, dict):
        return {str(key): redact(item) for key, item in value.items()}
    return value


def safe_name(value):
    value = redact_text(value or "unknown")
    value = re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("._")
    return value[:120] or "unknown"


def read_control_token():
    CONTROL_TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    if CONTROL_TOKEN_FILE.exists():
        token = CONTROL_TOKEN_FILE.read_text(encoding="utf-8", errors="replace").strip()
        if token:
            return token
    token = secrets.token_urlsafe(32)
    CONTROL_TOKEN_FILE.write_text(token + "\n", encoding="utf-8")
    try:
        CONTROL_TOKEN_FILE.chmod(0o600)
    except Exception:
        pass
    return token


class ReceiverState:
    def __init__(self, root):
        self.root = Path(root).expanduser()
        self.root.mkdir(parents=True, exist_ok=True)
        self.control_token = read_control_token()
        self.command_secrets = {}

    def client_dir(self, client_id):
        path = self.root / safe_name(client_id)
        path.mkdir(parents=True, exist_ok=True)
        (path / "files").mkdir(parents=True, exist_ok=True)
        return path

    def ingest(self, payload):
        payload = redact(payload)
        client_id = payload.get("client_id") or "unknown"
        cdir = self.client_dir(client_id)
        payload["received_at"] = int(time.time())
        with (cdir / "events.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")

        meta = {
            "client_id": client_id,
            "last_seen": payload["received_at"],
            "computer": payload.get("computer"),
            "user": payload.get("user"),
            "ps_version": payload.get("ps_version"),
            "local_4000_health": payload.get("local_4000_health"),
            "local_4000_pool_status": payload.get("local_4000_pool_status"),
            "codex_process_count": len(payload.get("codex_processes") or []),
            "receiver_root": str(self.root),
        }
        (cdir / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")

        for item in payload.get("files", []):
            label = safe_name(item.get("label") or item.get("path") or "file")
            body = []
            body.append("# " + redact_text(item.get("label") or label))
            body.append("# path: " + redact_text(item.get("path") or ""))
            body.append("# exists: " + str(item.get("exists")))
            body.append("# last_write_time: " + redact_text(item.get("last_write_time") or ""))
            body.append("# received_at: " + str(payload["received_at"]))
            body.append("")
            body.append(redact_text(item.get("content") or ""))
            (cdir / "files" / (label + ".txt")).write_text("\n".join(body), encoding="utf-8")
        return meta

    def clients(self):
        out = []
        for cdir in sorted(self.root.iterdir()):
            if not cdir.is_dir():
                continue
            meta_path = cdir / "meta.json"
            meta = {"client_id": cdir.name, "last_seen": 0}
            if meta_path.exists():
                try:
                    meta = json.loads(meta_path.read_text(encoding="utf-8"))
                except Exception:
                    pass
            files = []
            fdir = cdir / "files"
            if fdir.exists():
                files = sorted(path.name for path in fdir.glob("*.txt"))
            meta["files"] = files
            out.append(meta)
        out.sort(key=lambda item: item.get("last_seen", 0), reverse=True)
        return out

    def read_tail(self, client_id, file_name, max_lines=300):
        cdir = self.client_dir(client_id)
        if file_name == "events.jsonl":
            path = cdir / "events.jsonl"
        else:
            path = cdir / "files" / safe_name(file_name)
            if not path.name.endswith(".txt"):
                path = path.with_suffix(".txt")
        if not path.exists():
            return []
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        return lines[-max(1, min(max_lines, 2000)) :]

    def commands_path(self, client_id):
        return self.client_dir(client_id) / "commands.json"

    def load_commands(self, client_id):
        path = self.commands_path(client_id)
        if not path.exists():
            return []
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            return value if isinstance(value, list) else []
        except Exception:
            return []

    def save_commands(self, client_id, commands):
        path = self.commands_path(client_id)
        path.write_text(json.dumps(commands, ensure_ascii=False, indent=2), encoding="utf-8")

    def append_command_event(self, client_id, event):
        cdir = self.client_dir(client_id)
        event = redact(event)
        event["event_at"] = int(time.time())
        with (cdir / "command_events.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")

    def enqueue_command(self, payload):
        client_id = payload.get("client_id") or ""
        if not client_id:
            raise ValueError("client_id is required")
        raw_command = payload.get("command") or ""
        now = int(time.time())
        command = {
            "id": uuid.uuid4().hex,
            "client_id": client_id,
            "status": "queued",
            "created_at": now,
            "updated_at": now,
            "shell": payload.get("shell") or "powershell",
            "cwd": payload.get("cwd") or "",
            "timeout_sec": max(1, min(int(payload.get("timeout_sec") or 60), 600)),
            "command": payload.get("display_command") or redact_text(raw_command),
        }
        if not raw_command:
            raise ValueError("command is required")
        if command["command"] != raw_command:
            self.command_secrets[command["id"]] = raw_command
        commands = self.load_commands(client_id)
        commands.append(command)
        self.save_commands(client_id, commands)
        self.append_command_event(client_id, {"type": "queued", "command": command})
        return command

    def next_command(self, client_id):
        commands = self.load_commands(client_id)
        now = int(time.time())
        for command in commands:
            if command.get("status") == "queued":
                command["status"] = "dispatched"
                command["dispatched_at"] = now
                command["updated_at"] = now
                self.save_commands(client_id, commands)
                self.append_command_event(client_id, {"type": "dispatched", "command": command})
                outbound = dict(command)
                outbound["command"] = self.command_secrets.pop(command.get("id"), command.get("command") or "")
                return outbound
        return None

    def record_command_result(self, payload):
        client_id = payload.get("client_id") or ""
        command_id = payload.get("id") or payload.get("command_id") or ""
        if not client_id or not command_id:
            raise ValueError("client_id and command id are required")
        commands = self.load_commands(client_id)
        now = int(time.time())
        found = None
        for command in commands:
            if command.get("id") == command_id:
                command["status"] = "done" if payload.get("ok") else "failed"
                command["updated_at"] = now
                command["finished_at"] = now
                command["result"] = redact({
                    "ok": bool(payload.get("ok")),
                    "exit_code": payload.get("exit_code"),
                    "duration_ms": payload.get("duration_ms"),
                    "stdout": payload.get("stdout") or "",
                    "stderr": payload.get("stderr") or "",
                    "error": payload.get("error") or "",
                })
                found = command
                break
        if found is None:
            raise ValueError("command not found")
        self.save_commands(client_id, commands)
        self.append_command_event(client_id, {"type": "result", "command": found})
        return found

    def recent_commands(self, client_id=None, limit=80):
        items = []
        clients = [client_id] if client_id else [c.get("client_id") for c in self.clients()]
        for cid in clients:
            if not cid:
                continue
            for command in self.load_commands(cid):
                items.append(command)
        items.sort(key=lambda item: item.get("updated_at") or item.get("created_at") or 0, reverse=True)
        return items[: max(1, min(limit, 500))]


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def build_runtime_config_command(model, api_key):
    payload = {
        "model": (model or "").strip(),
        "api_key": (api_key or "").strip(),
    }
    if not payload["model"] and not payload["api_key"]:
        raise ValueError("model or api_key is required")
    encoded = base64.b64encode(json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).decode("ascii")
    command = f"""$ErrorActionPreference = 'Stop'
$rt = Join-Path $env:USERPROFILE '.zhuda-codex-win'
New-Item -ItemType Directory -Force -Path $rt | Out-Null
$json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('{encoded}'))
$payload = $json | ConvertFrom-Json
$enc = New-Object System.Text.UTF8Encoding($false)
if ($payload.PSObject.Properties['model'] -and [string]$payload.model) {{
    [System.IO.File]::WriteAllText((Join-Path $rt 'active_model.txt'), ([string]$payload.model).Trim(), $enc)
}}
if ($payload.PSObject.Properties['api_key'] -and [string]$payload.api_key) {{
    [System.IO.File]::WriteAllText((Join-Path $rt 'active_api_key.txt'), ([string]$payload.api_key).Trim(), $enc)
}}
$status = $null
try {{
    $status = Invoke-RestMethod -Uri 'http://127.0.0.1:4000/pool/status' -TimeoutSec 5
}} catch {{
    $status = @{{ error = $_.Exception.Message }}
}}
[pscustomobject]@{{
    updated = $true
    model = if ($payload.PSObject.Properties['model']) {{ [string]$payload.model }} else {{ '' }}
    apiKeySet = [bool]($payload.PSObject.Properties['api_key'] -and [string]$payload.api_key)
    status = $status
}} | ConvertTo-Json -Depth 20 -Compress
"""
    display_parts = []
    if payload["model"]:
        display_parts.append(f"model={payload['model']}")
    if payload["api_key"]:
        display_parts.append("api_key=<redacted>")
    display = "Set Zhuda runtime config without restart: " + ", ".join(display_parts)
    return command, display


def html_page():
    return b"""<!doctype html>
<html><head><meta charset="utf-8"><title>Zhuda LAN Logs</title>
<style>
body{margin:0;background:#101214;color:#eceff3;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Arial,sans-serif}
header,.bar{padding:12px 16px;background:#171a1f;border-bottom:1px solid #313841}
select,input,button{height:32px;background:#222832;color:#eceff3;border:1px solid #48515c;border-radius:5px;padding:0 8px}
.grid{display:grid;grid-template-columns:1fr 300px;height:calc(100vh - 101px)}
pre{margin:0;padding:14px;overflow:auto;font:12px Menlo,Consolas,monospace;white-space:pre-wrap}
.side{border-left:1px solid #313841;padding:12px;color:#aab2bd}.ok{color:#45d18a}.warn{color:#f0bd4f}
.client{padding:8px;border-bottom:1px solid #30363d;cursor:pointer}.client:hover{background:#1d232a}
</style></head><body>
<header><b>Zhuda LAN Logs</b> <span id="state" class="warn">loading</span></header>
<div class="bar"><select id="file"></select> <input id="q" placeholder="search"> <button onclick="loadTail()">Refresh</button> <label><input id="auto" type="checkbox" checked> auto</label></div>
<div class="grid"><pre id="log"></pre><div class="side"><div id="clients"></div></div></div>
<script>
let currentClient="", lines=[];
function esc(s){return String(s).replace(/[&<>]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]));}
function render(){let q=document.getElementById("q").value.toLowerCase();document.getElementById("log").innerHTML=lines.filter(x=>!q||x.toLowerCase().includes(q)).map(esc).join("\\n");if(document.getElementById("auto").checked)document.getElementById("log").scrollTop=99999999;}
async function loadClients(){let r=await fetch("/api/clients");let d=await r.json();let box=document.getElementById("clients");box.innerHTML="";for(let c of d.clients){let health=c.local_4000_health||{};let pool=c.local_4000_pool_status||{};let model=health.model||pool.forceUpstreamModel||"-";let status=health.status||health.error||"unknown";let div=document.createElement("div");div.className="client";div.innerHTML="<b>"+esc(c.client_id)+"</b><br><small>last seen: "+new Date((c.last_seen||0)*1000).toLocaleTimeString()+"</small><br><small class='muted'>4000: "+esc(status)+" | model: "+esc(model)+"</small>";div.onclick=()=>selectClient(c);box.appendChild(div);}if(!currentClient&&d.clients[0])selectClient(d.clients[0]);document.getElementById("state").textContent="live";document.getElementById("state").className="ok";}
function selectClient(c){currentClient=c.client_id;let sel=document.getElementById("file");sel.innerHTML='<option value="events.jsonl">events.jsonl</option>';for(let f of (c.files||[])){let o=document.createElement("option");o.value=f;o.textContent=f;sel.appendChild(o);}loadTail();}
async function loadTail(){if(!currentClient)return;let f=document.getElementById("file").value||"events.jsonl";let r=await fetch("/api/tail?client="+encodeURIComponent(currentClient)+"&file="+encodeURIComponent(f)+"&lines=400");let d=await r.json();lines=d.lines||[];render();}
document.getElementById("file").onchange=loadTail;document.getElementById("q").oninput=render;setInterval(()=>{loadClients();loadTail();},2000);loadClients();
</script></body></html>"""


def control_page(token):
    token_js = json.dumps(token)
    repair_command = """$p = Join-Path $env:USERPROFILE '.codex\\config.toml'
if (Test-Path $p) {
  $t = [IO.File]::ReadAllText($p)
  $lines = $t -split "`r?`n", -1
  $out = New-Object System.Collections.Generic.List[string]
  $skip = $false
  foreach ($line in $lines) {
    $trim = $line.Trim()
    if ($trim.StartsWith('[projects.')) { $skip = $true; continue }
    if ($skip) { if ($trim.StartsWith('[') -and $trim.EndsWith(']')) { $skip = $false } else { continue } }
    $out.Add($line)
  }
  $text = (($out.ToArray()) -join "`r`n").Trim() + "`r`n"
  if ($text -notmatch '(?m)^\\[windows\\]') { $text += "`r`n[windows]`r`nsandbox = `"unelevated`"`r`n" }
  elseif ($text -match '(?ms)^\\[windows\\].*?(?=^\\[|\\z)' -and $text -notmatch '(?m)^sandbox\\s*=') { $text = $text -replace '(?ms)^\\[windows\\]\\r?\\n', "[windows]`r`nsandbox = `"unelevated`"`r`n" }
  $enc = New-Object Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($p, $text, $enc)
  Write-Output 'repaired config.toml'
} else {
  Write-Output 'config not found'
}"""
    repair_js = json.dumps(repair_command)
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Zhuda LAN Control</title>
<style>
body{{margin:0;background:#101214;color:#eceff3;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Arial,sans-serif}}
header,.bar{{padding:12px 16px;background:#171a1f;border-bottom:1px solid #313841}}
select,input,button,textarea{{background:#222832;color:#eceff3;border:1px solid #48515c;border-radius:5px;padding:8px}}
button{{cursor:pointer}}button:hover{{background:#2d3540}}
.grid{{display:grid;grid-template-columns:380px 1fr;height:calc(100vh - 57px)}}
.side{{border-right:1px solid #313841;padding:12px;overflow:auto}}
.main{{padding:12px;overflow:auto}}
.client,.cmd{{padding:10px;border:1px solid #30363d;border-radius:6px;margin-bottom:8px;background:#15191e}}
.client{{cursor:pointer}}.client:hover{{background:#1d232a}}
textarea{{width:100%;height:120px;box-sizing:border-box;font:13px Menlo,Consolas,monospace}}
pre{{margin:8px 0 0;padding:10px;background:#0d0f12;border:1px solid #30363d;border-radius:6px;white-space:pre-wrap;overflow:auto;max-height:360px;font:12px Menlo,Consolas,monospace}}
.ok{{color:#45d18a}}.warn{{color:#f0bd4f}}.bad{{color:#ff6b6b}}.muted{{color:#9aa4af}}
.row{{display:flex;gap:8px;align-items:center;margin:8px 0}}.row>*{{flex:1}}.row button{{flex:0 0 auto}}
a{{color:#7db7ff}}
</style></head><body>
<header><b>Zhuda LAN Control</b> <span id="state" class="warn">loading</span> <span class="muted"> | </span> <a href="/logs">logs</a></header>
<div class="grid">
  <div class="side"><h3>Clients</h3><div id="clients"></div></div>
  <div class="main">
    <h3 id="title">Select a client</h3>
    <h3>Runtime Config</h3>
    <div class="row">
      <input id="runtimeModel" placeholder="model, e.g. gemma-31b / flash-lite">
      <input id="runtimeKey" type="password" placeholder="Gemini API key, optional">
      <button onclick="applyRuntime()">Apply Next Turn</button>
    </div>
    <div class="row">
      <select id="shell"><option value="powershell">PowerShell</option><option value="cmd">CMD</option></select>
      <input id="cwd" placeholder="cwd, optional">
      <input id="timeout" type="number" value="60" min="1" max="600" title="timeout seconds">
    </div>
    <textarea id="command" placeholder="Command to run on the selected Windows computer"></textarea>
    <div class="row"><button onclick="sendCommand()">Run Command</button><button onclick="quickSnapshot()">Send Snapshot Now</button><button onclick="quickRepair()">Repair Codex Config</button></div>
    <h3>Command History</h3>
    <div id="commands"></div>
  </div>
</div>
<script>
const TOKEN = {token_js};
const REPAIR_COMMAND = {repair_js};
let currentClient="";
function esc(s){{return String(s||"").replace(/[&<>]/g,c=>({{"&":"&amp;","<":"&lt;",">":"&gt;"}}[c]));}}
async function api(url, opts={{}}){{opts.headers=Object.assign({{"X-Zhuda-Control-Token":TOKEN}}, opts.headers||{{}});let r=await fetch(url,opts);if(!r.ok)throw new Error(await r.text());return await r.json();}}
async function loadClients(){{let d=await api("/api/clients");let box=document.getElementById("clients");box.innerHTML="";for(let c of d.clients){{let health=c.local_4000_health||{{}};let pool=c.local_4000_pool_status||{{}};let model=health.model||pool.forceUpstreamModel||"-";let status=health.status||health.error||"unknown";let div=document.createElement("div");div.className="client";div.innerHTML="<b>"+esc(c.client_id)+"</b><br><small>last seen: "+new Date((c.last_seen||0)*1000).toLocaleTimeString()+"</small><br><small class='muted'>"+esc(c.computer||"")+" / "+esc(c.user||"")+"</small><br><small class='muted'>4000: "+esc(status)+" | model: "+esc(model)+"</small>";div.onclick=()=>selectClient(c.client_id);box.appendChild(div);}}if(!currentClient&&d.clients[0])selectClient(d.clients[0].client_id);document.getElementById("state").textContent="live";document.getElementById("state").className="ok";}}
function selectClient(id){{currentClient=id;document.getElementById("title").textContent=id;loadCommands();}}
async function loadCommands(){{if(!currentClient)return;let d=await api("/api/commands?client="+encodeURIComponent(currentClient));let box=document.getElementById("commands");box.innerHTML="";for(let c of d.commands){{let cls=c.status==="done"?"ok":(c.status==="failed"?"bad":"warn");let r=c.result||{{}};let div=document.createElement("div");div.className="cmd";div.innerHTML="<b class='"+cls+"'>"+esc(c.status)+"</b> <span class='muted'>"+esc(c.id)+"</span><br><small>"+new Date((c.updated_at||c.created_at||0)*1000).toLocaleString()+" | "+esc(c.shell)+" | timeout "+esc(c.timeout_sec)+"s</small><pre>"+esc(c.command)+"</pre>"+(c.result?("<pre>exit="+esc(r.exit_code)+" duration="+esc(r.duration_ms)+"ms\\n\\nSTDOUT\\n"+esc(r.stdout)+"\\n\\nSTDERR\\n"+esc(r.stderr)+"\\n"+esc(r.error)+"</pre>"):"");box.appendChild(div);}}}}
async function sendCommand(){{if(!currentClient)return alert("select client first");let payload={{client_id:currentClient,shell:document.getElementById("shell").value,cwd:document.getElementById("cwd").value,timeout_sec:Number(document.getElementById("timeout").value||60),command:document.getElementById("command").value}};await api("/api/command",{{method:"POST",headers:{{"Content-Type":"application/json"}},body:JSON.stringify(payload)}});document.getElementById("command").value="";loadCommands();}}
async function applyRuntime(){{if(!currentClient)return alert("select client first");let payload={{client_id:currentClient,model:document.getElementById("runtimeModel").value,api_key:document.getElementById("runtimeKey").value}};await api("/api/runtime",{{method:"POST",headers:{{"Content-Type":"application/json"}},body:JSON.stringify(payload)}});document.getElementById("runtimeKey").value="";loadCommands();}}
function quickSnapshot(){{document.getElementById("shell").value="powershell";document.getElementById("command").value="Write-Output 'snapshot requested';";sendCommand();}}
function quickRepair(){{document.getElementById("shell").value="powershell";document.getElementById("command").value=REPAIR_COMMAND;sendCommand();}}
setInterval(()=>{{loadClients();loadCommands();}},2000);loadClients();
</script></body></html>""".encode("utf-8")


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return

        def send_data(self, code, content_type, data):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def authorized(self):
            token = self.headers.get("X-Zhuda-Control-Token", "")
            return token == state.control_token

        def send_unauthorized(self):
            self.send_data(401, "application/json; charset=utf-8", json_bytes({"error": "unauthorized"}))

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(parsed.query)
            if parsed.path in ("/", "/logs"):
                self.send_data(200, "text/html; charset=utf-8", html_page())
                return
            if parsed.path == "/control":
                self.send_data(200, "text/html; charset=utf-8", control_page(state.control_token))
                return
            if parsed.path.startswith("/download/"):
                rel = urllib.parse.unquote(parsed.path.split("/download/", 1)[1]).replace("\\", "/")
                rel = rel.lstrip("/")
                safe_rel = os.path.normpath(rel)
                download_root = DOWNLOAD_DIR.resolve()
                path = (download_root / safe_rel).resolve()
                if safe_rel.startswith("..") or path != download_root and download_root not in path.parents:
                    self.send_data(400, "application/json; charset=utf-8", json_bytes({"error": "invalid_download_path"}))
                    return
                if path.exists() and path.is_file():
                    data = path.read_bytes()
                    text = data.decode("utf-8", errors="replace") if path.suffix.lower() in (".ps1", ".cmd") else ""
                    if "__ZHUDA_" in text:
                        host = self.headers.get("Host") or f"127.0.0.1:{self.server.server_port}"
                        receiver = f"http://{host}"
                        text = text.replace("__ZHUDA_CONTROL_TOKEN__", state.control_token)
                        text = text.replace("__ZHUDA_RECEIVER_URL__", receiver)
                        data = text.encode("utf-8")
                    self.send_data(200, "application/octet-stream", data)
                    return
                self.send_data(404, "application/json; charset=utf-8", json_bytes({"error": "download_not_found"}))
                return
            if parsed.path == "/health":
                self.send_data(200, "application/json; charset=utf-8", json_bytes({"ok": True, "root": str(state.root)}))
                return
            if parsed.path == "/api/clients":
                self.send_data(200, "application/json; charset=utf-8", json_bytes({"clients": state.clients()}))
                return
            if parsed.path == "/api/tail":
                client = query.get("client", ["unknown"])[0]
                file_name = query.get("file", ["events.jsonl"])[0]
                try:
                    lines = int(query.get("lines", ["300"])[0])
                except Exception:
                    lines = 300
                self.send_data(200, "application/json; charset=utf-8", json_bytes({"client": client, "file": file_name, "lines": state.read_tail(client, file_name, lines)}))
                return
            if parsed.path == "/api/commands":
                if not self.authorized():
                    self.send_unauthorized()
                    return
                client = query.get("client", [""])[0] or None
                self.send_data(200, "application/json; charset=utf-8", json_bytes({"commands": state.recent_commands(client)}))
                return
            if parsed.path == "/api/command/next":
                if not self.authorized():
                    self.send_unauthorized()
                    return
                client = query.get("client", [""])[0]
                command = state.next_command(client) if client else None
                self.send_data(200, "application/json; charset=utf-8", json_bytes({"command": command}))
                return
            self.send_data(404, "application/json; charset=utf-8", json_bytes({"error": "not_found"}))

        def do_POST(self):
            parsed_path = urllib.parse.urlparse(self.path).path
            if parsed_path == "/api/command":
                if not self.authorized():
                    self.send_unauthorized()
                    return
                length = min(int(self.headers.get("Content-Length", "0")), 1024 * 1024)
                raw = self.rfile.read(length)
                try:
                    payload = json.loads(raw.decode("utf-8", errors="replace"))
                    command = state.enqueue_command(payload)
                    self.send_data(200, "application/json; charset=utf-8", json_bytes({"ok": True, "command": command}))
                except Exception as exc:
                    self.send_data(400, "application/json; charset=utf-8", json_bytes({"ok": False, "error": str(exc)}))
                return
            if parsed_path == "/api/runtime":
                if not self.authorized():
                    self.send_unauthorized()
                    return
                length = min(int(self.headers.get("Content-Length", "0")), 256 * 1024)
                raw = self.rfile.read(length)
                try:
                    payload = json.loads(raw.decode("utf-8", errors="replace"))
                    command_text, display_command = build_runtime_config_command(payload.get("model"), payload.get("api_key"))
                    command = state.enqueue_command({
                        "client_id": payload.get("client_id") or "",
                        "shell": "powershell",
                        "timeout_sec": 45,
                        "command": command_text,
                        "display_command": display_command,
                    })
                    self.send_data(200, "application/json; charset=utf-8", json_bytes({"ok": True, "command": command}))
                except Exception as exc:
                    self.send_data(400, "application/json; charset=utf-8", json_bytes({"ok": False, "error": str(exc)}))
                return
            if parsed_path == "/api/command/result":
                if not self.authorized():
                    self.send_unauthorized()
                    return
                length = min(int(self.headers.get("Content-Length", "0")), 10 * 1024 * 1024)
                raw = self.rfile.read(length)
                try:
                    payload = json.loads(raw.decode("utf-8", errors="replace"))
                    command = state.record_command_result(payload)
                    self.send_data(200, "application/json; charset=utf-8", json_bytes({"ok": True, "command": command}))
                except Exception as exc:
                    self.send_data(400, "application/json; charset=utf-8", json_bytes({"ok": False, "error": str(exc)}))
                return
            if parsed_path != "/ingest":
                self.send_data(404, "application/json; charset=utf-8", json_bytes({"error": "not_found"}))
                return
            length = min(int(self.headers.get("Content-Length", "0")), 25 * 1024 * 1024)
            raw = self.rfile.read(length)
            try:
                payload = json.loads(raw.decode("utf-8", errors="replace"))
                meta = state.ingest(payload)
                self.send_data(200, "application/json; charset=utf-8", json_bytes({"ok": True, "meta": meta}))
            except Exception as exc:
                self.send_data(400, "application/json; charset=utf-8", json_bytes({"ok": False, "error": str(exc)}))

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=4100)
    parser.add_argument("--root", default="~/.zhuda-codex/remote_logs")
    args = parser.parse_args()
    state = ReceiverState(args.root)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(state))
    print(f"Zhuda LAN log receiver listening on http://{args.host}:{args.port}/logs", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
