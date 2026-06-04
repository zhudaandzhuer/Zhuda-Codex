#!/usr/bin/env python3
import argparse
import json
import mimetypes
import os
import shutil
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


DEFAULT_PORT = 4111
MAC_APP_ID = "com.zhuda.zhuda-codex"
MAC_ADAPTER_PORT = 4400


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def find_port(start):
    for port in range(start, start + 40):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind(("127.0.0.1", port))
            except OSError:
                continue
            return port
    raise RuntimeError(f"no free localhost port from {start}")


def command_exists(name):
    return shutil.which(name) is not None


def provider_by_id(manifest, provider_id):
    for provider in manifest.get("providers", []):
        if provider.get("id") == provider_id:
            return provider
    return None


def endpoint_options(provider):
    return provider.get("endpoint_options") or []


def endpoint_by_id(provider, endpoint_id):
    options = endpoint_options(provider)
    if not options:
        return None
    selected = endpoint_id or provider.get("default_endpoint") or options[0].get("id")
    for endpoint in options:
        if endpoint.get("id") == selected:
            return endpoint
    return options[0]


def provider_base_url(provider, endpoint_id=None):
    endpoint = endpoint_by_id(provider, endpoint_id)
    if endpoint and endpoint.get("base_url"):
        return endpoint["base_url"]
    return provider.get("base_url", "")


def provider_endpoint_label(provider, endpoint_id=None):
    endpoint = endpoint_by_id(provider, endpoint_id)
    return endpoint.get("label") if endpoint else ""


def upstream_models(provider):
    return provider.get("upstream_models") or provider.get("models") or []


def upstream_by_id(provider, model_id):
    for model in upstream_models(provider):
        if model.get("id") == model_id or model.get("upstream") == model_id:
            return model.get("upstream")
    models = upstream_models(provider)
    return models[0].get("upstream") if models else ""


def build_aliases(manifest, provider, mapping_ids):
    codex_ids = [item["id"] for item in manifest.get("codex_models", [])]
    aliases = {}
    default_mappings = provider.get("default_mappings") or {}
    first_upstream = upstream_models(provider)[0]["upstream"] if upstream_models(provider) else ""
    for codex_id in codex_ids:
        selected = (mapping_ids or {}).get(codex_id) or default_mappings.get(codex_id) or first_upstream
        aliases[codex_id] = upstream_by_id(provider, selected)
    if "zhuda-codex" in aliases:
        aliases["gemini-codex"] = aliases["zhuda-codex"]
    return {key: value for key, value in aliases.items() if key and value}


def build_session_env_vars(manifest, provider, mapping_ids, api_key, endpoint_id=None):
    aliases = build_aliases(manifest, provider, mapping_ids)
    first_codex = "zhuda-codex" if "zhuda-codex" in aliases else next(iter(aliases), "")
    key_name = "MIMO_API_KEY_1" if provider["id"] == "mimo" else "GEMINI_API_KEY_1"
    values = {
        "ZHUDA_PROVIDER": provider["id"],
        "ZHUDA_PROVIDER_ENDPOINT": endpoint_id or "",
        "ZHUDA_SELECTED_CODEX_MODEL": first_codex,
        "ZHUDA_SELECTED_UPSTREAM_MODEL": aliases.get(first_codex, ""),
        key_name: api_key,
        "ZHUDA_MODEL_MAPPINGS": ",".join(f"{key}={value}" for key, value in aliases.items()),
        "ZHUDA_FORCE_UPSTREAM_MODEL": "0",
        "ZHUDA_GEMINI_FALLBACK_MODELS": "0",
        "ZHUDA_MIMO_FALLBACK_MODELS": "0",
        "ZHUDA_MAX_KEY_ATTEMPTS": "1",
        "ZHUDA_MAX_MODEL_ATTEMPTS": "1",
        "ZHUDA_UPSTREAM_TIMEOUT_SECONDS": "60",
        "ZHUDA_RATE_LIMIT_COOLDOWN_SECONDS": "120",
        "ZHUDA_ERROR_COOLDOWN_SECONDS": "60",
        "ZHUDA_CODEX_LAUNCHER_SESSION": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    if provider["id"] == "gemini":
        values["ZHUDA_GEMINI_MODELS"] = ",".join(f"{key}={value}" for key, value in aliases.items())
        values["ZHUDA_GEMINI_API_KEY"] = api_key
        values["GEMINI_API_KEY"] = api_key
    if provider["id"] == "mimo":
        base_url = provider_base_url(provider, endpoint_id) or "https://api.xiaomimimo.com/v1"
        values["MIMO_API_KEY"] = api_key
        values["XIAOMI_MIMO_API_KEY"] = api_key
        values["MIMO_BASE_URL"] = base_url
        values["XIAOMI_MIMO_BASE_URL"] = base_url
        values["ZHUDA_MAX_INPUT_TOKENS"] = "12000"
        values["ZHUDA_MAX_PINNED_TOKENS"] = "3500"
        values["ZHUDA_MAX_HISTORY_ITEM_TOKENS"] = "1200"
        values["ZHUDA_MAX_TOOL_OUTPUT_CHARS"] = "1200"
        values["ZHUDA_MIMO_MAX_TOKENS"] = "2048"
        values["ZHUDA_UPSTREAM_TIMEOUT_SECONDS"] = "90"
        values["ZHUDA_TIMEOUT_COOLDOWN_SECONDS"] = "90"
        values["ZHUDA_ERROR_COOLDOWN_SECONDS"] = "45"
        values["ZHUDA_LARGE_PROMPT_TOKEN_THRESHOLD"] = "12000"
        values["ZHUDA_LARGE_PROMPT_MIN_INTERVAL_MS"] = "25000"
        values["ZHUDA_LARGE_PROMPT_RATE_LIMIT_COOLDOWN_SECONDS"] = "180"
        values["ZHUDA_MODEL_MIN_INTERVALS_MS"] = "mimo-v2.5-pro:12000,mimo-v2.5:8000"
    return values


def http_json(url, timeout=1.5):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8", errors="replace"))
    except Exception:
        return None


def shutdown_server_later(server, delay=1.2):
    def worker():
        time.sleep(delay)
        server.shutdown()

    threading.Thread(target=worker, daemon=True).start()


class LauncherState:
    def __init__(self, project_root, platform_name):
        self.project_root = Path(project_root).resolve()
        self.platform_name = platform_name
        self.web_root = self.project_root / "launcher" / "web"
        self.assets_root = self.project_root / "assets"
        self.providers_path = self.project_root / "providers.json"
        self.mac_app_path = self.project_root / "mac" / "dist" / "Zhuda-Codex.app"
        self.mac_app_exe = self.mac_app_path / "Contents" / "MacOS" / "Codex"
        self.mac_runtime_env = Path.home() / "Library" / "Application Support" / "Zhuda-Codex" / "adapters" / "gemini" / ".env"
        self.win_launch_script = self.project_root / "win" / "Zhuda-Codex-Launcher.ps1"
        self.last_launch = ""

    def manifest(self):
        data = read_json(self.providers_path)
        data["launcher"] = {
            "platform": self.platform_name,
            "session_only_keys": True,
        }
        return data

    def status(self):
        adapter = {"ok": False, "port": MAC_ADAPTER_PORT}
        if self.platform_name == "mac":
            pool = http_json(f"http://127.0.0.1:{MAC_ADAPTER_PORT}/pool/status")
            if pool:
                runtime = pool.get("runtime") or {}
                adapter.update({
                    "ok": True,
                    "provider": pool.get("provider"),
                    "timeoutSeconds": runtime.get("upstreamTimeoutSeconds"),
                    "modelCount": len(pool.get("models") or {}),
                    "keyCount": pool.get("keyCount"),
                })
        return {
            "platform": self.platform_name,
            "projectRoot": str(self.project_root),
            "adapter": adapter,
            "lastLaunch": self.last_launch,
        }

    def stop_mac(self):
        subprocess.run(["osascript", "-e", f'tell application id "{MAC_APP_ID}" to quit'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if self.mac_app_exe.exists():
            subprocess.run([str(self.mac_app_exe), "--zhuda-stop-adapter"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def launch_mac(self, manifest, provider, mapping_ids, api_key, endpoint_id=None):
        if not self.mac_app_exe.exists():
            raise RuntimeError(f"missing Mac app executable: {self.mac_app_exe}")
        self.stop_mac()
        try:
            self.mac_runtime_env.unlink()
        except FileNotFoundError:
            pass
        env = os.environ.copy()
        env.update(build_session_env_vars(manifest, provider, mapping_ids, api_key, endpoint_id))
        subprocess.Popen([str(self.mac_app_exe)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        aliases = build_aliases(manifest, provider, mapping_ids)
        endpoint_label = provider_endpoint_label(provider, endpoint_id)
        endpoint_part = f" / {endpoint_label}" if endpoint_label else ""
        self.last_launch = f"{provider['name']}{endpoint_part} / {len(aliases)} mappings @ {time.strftime('%H:%M:%S')}"

    def launch_win(self, manifest, provider, mapping_ids, api_key, endpoint_id=None):
        if not self.win_launch_script.exists():
            raise RuntimeError(f"missing Windows launch script: {self.win_launch_script}")
        powershell = shutil.which("powershell.exe") or shutil.which("powershell") or shutil.which("pwsh")
        if not powershell:
            raise RuntimeError("PowerShell was not found.")
        env = os.environ.copy()
        env["ZHUDA_WEB_LAUNCH_API_KEY"] = api_key
        env["ZHUDA_WEB_LAUNCH_MAPPINGS"] = json.dumps(mapping_ids or {}, ensure_ascii=False, separators=(",", ":"))
        env["ZHUDA_WEB_LAUNCH_ENDPOINT_ID"] = endpoint_id or ""
        base_url = provider_base_url(provider, endpoint_id)
        if base_url:
            env["ZHUDA_WEB_LAUNCH_BASE_URL"] = base_url
        subprocess.Popen([
            powershell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(self.win_launch_script),
            "-Headless",
            "-Provider",
            provider["id"],
        ], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        aliases = build_aliases(manifest, provider, mapping_ids)
        endpoint_label = provider_endpoint_label(provider, endpoint_id)
        endpoint_part = f" / {endpoint_label}" if endpoint_label else ""
        self.last_launch = f"{provider['name']}{endpoint_part} / {len(aliases)} mappings @ {time.strftime('%H:%M:%S')}"

    def launch(self, payload):
        manifest = self.manifest()
        provider = provider_by_id(manifest, payload.get("provider_id"))
        if not provider:
            raise RuntimeError("Provider not found.")
        if not provider.get("enabled"):
            raise RuntimeError(f"{provider.get('name')} is reserved for later.")
        api_key = (payload.get("api_key") or "").strip()
        if not api_key:
            raise RuntimeError("API key is empty.")
        endpoint_id = (payload.get("endpoint_id") or "").strip()
        mapping_ids = payload.get("mappings") or {}
        aliases = build_aliases(manifest, provider, mapping_ids)
        if not aliases:
            raise RuntimeError("No model mappings were selected.")
        if self.platform_name == "win":
            self.launch_win(manifest, provider, mapping_ids, api_key, endpoint_id)
        else:
            self.launch_mac(manifest, provider, mapping_ids, api_key, endpoint_id)
        return {
            "ok": True,
            "message": f"已啟動 {provider['name']}，{len(aliases)} 個 Codex 模型映射已注入。",
            "mappings": aliases,
            "endpoint": provider_endpoint_label(provider, endpoint_id),
        }


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

        def send_json(self, code, value):
            self.send_data(code, "application/json; charset=utf-8", json_bytes(value))

        def read_payload(self):
            length = int(self.headers.get("Content-Length") or "0")
            body = self.rfile.read(length).decode("utf-8", errors="replace") if length else "{}"
            return json.loads(body or "{}")

        def safe_file(self, root, rel):
            rel = urllib.parse.unquote(rel).replace("\\", "/").lstrip("/")
            path = (root / os.path.normpath(rel)).resolve()
            root = root.resolve()
            if path != root and root not in path.parents:
                return None
            return path

        def serve_file(self, path):
            if not path or not path.exists() or not path.is_file():
                self.send_json(404, {"error": "not found"})
                return
            content_type = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
            if path.suffix.lower() in (".html", ".css", ".js"):
                content_type = {
                    ".html": "text/html; charset=utf-8",
                    ".css": "text/css; charset=utf-8",
                    ".js": "application/javascript; charset=utf-8",
                }[path.suffix.lower()]
            self.send_data(200, content_type, path.read_bytes())

        def do_HEAD(self):
            parsed = urllib.parse.urlparse(self.path)
            path = None
            if parsed.path in ("/", "/launcher"):
                path = state.web_root / "index.html"
            elif parsed.path.startswith("/web/"):
                path = self.safe_file(state.web_root, parsed.path.split("/web/", 1)[1])
            elif parsed.path.startswith("/assets/"):
                path = self.safe_file(state.assets_root, parsed.path.split("/assets/", 1)[1])
            if not path or not path.exists() or not path.is_file():
                self.send_response(404)
                self.end_headers()
                return
            content_type = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(path.stat().st_size))
            self.end_headers()

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path in ("/", "/launcher"):
                self.serve_file(state.web_root / "index.html")
                return
            if parsed.path == "/api/manifest":
                self.send_json(200, state.manifest())
                return
            if parsed.path == "/api/status":
                self.send_json(200, state.status())
                return
            if parsed.path.startswith("/web/"):
                self.serve_file(self.safe_file(state.web_root, parsed.path.split("/web/", 1)[1]))
                return
            if parsed.path.startswith("/assets/"):
                self.serve_file(self.safe_file(state.assets_root, parsed.path.split("/assets/", 1)[1]))
                return
            self.send_json(404, {"error": "not found"})

        def do_POST(self):
            parsed = urllib.parse.urlparse(self.path)
            try:
                if parsed.path == "/api/launch":
                    result = state.launch(self.read_payload())
                    result["launcherWillExit"] = True
                    result["shutdownDelaySeconds"] = 1.2
                    self.send_json(200, result)
                    shutdown_server_later(self.server)
                    return
                if parsed.path == "/api/stop":
                    if state.platform_name == "mac":
                        state.stop_mac()
                    self.send_json(200, {"ok": True, "message": "Adapter stopped."})
                    return
                self.send_json(404, {"error": "not found"})
            except Exception as exc:
                self.send_json(400, {"error": str(exc)})

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--platform", choices=["mac", "win"], default="mac")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()

    state = LauncherState(args.project_root, args.platform)
    port = find_port(args.port)
    server = ThreadingHTTPServer(("127.0.0.1", port), make_handler(state))
    url = f"http://127.0.0.1:{port}/"
    print(f"Zhuda-Codex Web Launcher: {url}", flush=True)
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
