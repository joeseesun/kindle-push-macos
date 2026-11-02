"""Model services for translation: model lists, ChatGPT via the Codex CLI, and browser sign-in for keys.

Nothing here stores a secret. Keys found by sign-in go back to the app, which keeps them in the Keychain.
"""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import threading
import urllib.error
import urllib.parse
import urllib.request

import kindle_push as kp

RUNTIME = kp.DATA / 'translation-runtime'
# GUI apps start with a minimal PATH; look where installers put the Codex CLI.
CODEX_DIRS = ['~/.local/bin', '/opt/homebrew/bin', '/usr/local/bin', '~/.npm-global/bin',
              '~/.bun/bin', '~/.volta/bin', '~/.codex/bin']
SIGN_IN = {
    'openrouter': {'name': 'OpenRouter', 'auth': 'https://openrouter.ai/auth',
                   'exchange': 'https://openrouter.ai/api/v1/auth/keys', 'host': 'localhost'},
    'tokendance': {'name': '词元跳动', 'auth': 'https://tokendance.space/auth',
                   'exchange': 'https://tokendance.space/portal/api/v1/auth/keys', 'host': '127.0.0.1'},
}
APP_URL = 'https://github.com/joeseesun/kindle-push-macos'
DONE_PAGE = ('<!doctype html><meta charset="utf-8"><title>Kindle 推送</title>'
             '<body style="font:16px -apple-system;display:grid;place-items:center;height:90vh;margin:0">'
             '<div style="text-align:center"><h2>{0}</h2><p style="color:#666">{1}</p></div>')


def codex_binary():
    found = shutil.which('codex', path=os.pathsep.join([os.environ.get('PATH', '')] + [os.path.expanduser(d) for d in CODEX_DIRS]))
    if found:
        return found
    try:
        shell = subprocess.run(['/bin/zsh', '-lc', 'command -v codex'], capture_output=True, text=True, timeout=6)
        path = shell.stdout.strip().splitlines()[-1] if shell.stdout.strip() else ''
        return path if path and os.access(path, os.X_OK) else None
    except (subprocess.SubprocessError, OSError):
        return None


def codex_env():
    """Environment for anything that runs the Codex CLI: its own folder first on PATH."""
    env = dict(os.environ)
    binary = codex_binary()
    if binary:
        env['PATH'] = str(Path(binary).parent) + os.pathsep + env.get('PATH', '/usr/bin:/bin')
    return env


# Asks the Codex app-server (through the translation engine's client) who is signed in and which models it offers.
PROBE = r'''
import json
from book_maker.codex_client import CodexAppServer
with CodexAppServer() as server:
    server.start()
    account = server.request("account/read", {}).get("account") or {}
    listed = server.request("model/list", {})
    models = [{"id": m.get("id") or m.get("model"), "name": m.get("displayName") or m.get("id"), "default": bool(m.get("isDefault"))}
              for m in listed.get("data", listed.get("models", [])) if not m.get("hidden")]
    print(json.dumps({"type": account.get("type"), "plan": account.get("planType"), "email": account.get("email"), "models": models}))
'''


def codex_status():
    binary = codex_binary()
    if not binary:
        return {'ok': True, 'installed': False, 'loggedIn': False, 'models': []}
    status = subprocess.run([binary, 'login', 'status'], capture_output=True, text=True, timeout=20, env=codex_env())
    text = (status.stdout + status.stderr).strip()
    logged_in = status.returncode == 0 and 'ChatGPT' in text
    result = {'ok': True, 'installed': True, 'loggedIn': logged_in, 'models': [],
              'message': '' if logged_in else ('Codex 用的是 API Key，不是 ChatGPT 账号。' if status.returncode == 0 else '')}
    python = RUNTIME / 'bin/python3'
    if logged_in and python.is_file():
        try:
            probe = subprocess.run([str(python), '-c', PROBE], capture_output=True, text=True, timeout=60,
                                   env=codex_env(), cwd=str(kp.DATA))
            data = json.loads(probe.stdout.strip().splitlines()[-1])
            result.update(plan=data.get('plan'), email=data.get('email'), models=[m for m in data['models'] if m['id']])
        except (subprocess.SubprocessError, ValueError, IndexError, KeyError, OSError):
            result['message'] = '已登录，但暂时读不到模型列表，可以手动填写模型。'
    return result


def codex_login():
    binary = codex_binary()
    if not binary:
        raise ValueError('还没有安装 Codex 命令行工具。')
    # `codex login` opens the browser for ChatGPT sign-in and waits for its own callback.
    try:
        subprocess.run([binary, 'login'], capture_output=True, text=True, timeout=600, env=codex_env(),
                       stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired as error:
        raise ValueError('登录超时，请重试。') from error
    status = codex_status()
    if not status['loggedIn']:
        raise ValueError('没有完成 ChatGPT 登录，请在浏览器里登录后重试。')
    return status


def codex_logout():
    binary = codex_binary()
    if binary:
        subprocess.run([binary, 'logout'], capture_output=True, timeout=20, env=codex_env())
    return codex_status()


def list_models(base, key=''):
    """OpenAI-compatible /models. The key arrives on stdin, never in argv."""
    base = base.strip().rstrip('/')
    request = urllib.request.Request(base + '/models', headers={'Accept': 'application/json', 'User-Agent': 'KindlePush'})
    if key:
        request.add_header('Authorization', 'Bearer ' + key)
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            data = json.loads(response.read())
    except urllib.error.HTTPError as error:
        hint = '，请检查 API Key' if error.code in (401, 403) else ''
        raise ValueError(f'读取模型列表失败（HTTP {error.code}）{hint}。也可以手动填写模型。') from error
    except (urllib.error.URLError, socket.timeout, ValueError) as error:
        raise ValueError('连不上这个服务，读不到模型列表。也可以手动填写模型。') from error
    entries = data.get('data', data.get('models', [])) if isinstance(data, dict) else []
    models = {}
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        # Gateways that mix in image/audio models list their protocols; keep chat ones.
        protocols = entry.get('supported_protocols')
        if isinstance(protocols, list) and 'openai:chat-completions' not in protocols:
            continue
        model = entry.get('id') or entry.get('name') or ''
        model = model.removeprefix('models/')
        if model:
            name = entry.get('display_name') or entry.get('displayName') or entry.get('name') or model
            models[model] = {'id': model, 'name': name if isinstance(name, str) and name.strip() else model}
    if not models:
        raise ValueError('这个服务没有返回可用模型。也可以手动填写模型。')
    return {'ok': True, 'models': sorted(models.values(), key=lambda m: m['name'].lower())}


def _servers(port, handler):
    servers = []
    for family, host in [(socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')]:
        class Server(http.server.HTTPServer):
            address_family = family
        try:
            servers.append(Server((host, port), handler))
        except OSError:
            if family == socket.AF_INET:
                raise
    return servers


def sign_in_key(provider):
    """PKCE sign-in that returns an ordinary API key (OpenRouter, 词元跳动)."""
    spec = SIGN_IN.get(provider)
    if not spec:
        raise ValueError('这个服务不支持登录授权，请粘贴 API Key。')
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
    state = secrets.token_urlsafe(24)
    found = {}
    done = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            url = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(url.query)
            if url.path != '/callback':
                self.send_response(404); self.end_headers(); return
            ok = 'code' in query and (provider != 'openrouter' or query.get('state', [''])[0] == state)
            if ok:
                found['code'] = query['code'][0]
            page = DONE_PAGE.format('授权完成' if ok else '授权没有完成', '可以回到 Kindle 推送了。' if ok else '请回到 Kindle 推送重试。')
            self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.end_headers()
            self.wfile.write(page.encode())
            done.set()

        def log_message(self, *args):
            pass

    for _ in range(10):
        port = 49152 + secrets.randbelow(16000)
        try:
            servers = _servers(port, Handler); break
        except OSError:
            continue
    else:
        raise ValueError('无法在本机接收授权结果，请重试。')
    callback = f"http://{spec['host']}:{port}/callback"
    if provider == 'openrouter':
        params = {'callback_url': callback, 'code_challenge': challenge, 'code_challenge_method': 'S256', 'state': state}
    else:
        params = {'callback_url': callback, 'code_challenge': challenge, 'code_challenge_method': 'S256',
                  'app_url': APP_URL, 'key_name': 'Kindle 推送'}
    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
    for thread in threads:
        thread.start()
    try:
        subprocess.run(['/usr/bin/open', spec['auth'] + '?' + urllib.parse.urlencode(params)], check=True)
        if not done.wait(300):
            raise ValueError('授权超时，请重试。')
    finally:
        for server in servers:
            server.shutdown(); server.server_close()
    if 'code' not in found:
        raise ValueError(spec['name'] + ' 授权没有完成，请重试。')
    body = json.dumps({'code': found['code'], 'code_verifier': verifier, 'code_challenge_method': 'S256'}).encode()
    request = urllib.request.Request(spec['exchange'], data=body, method='POST',
                                     headers={'Content-Type': 'application/json', 'Accept': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            key = json.loads(response.read()).get('key')
    except (urllib.error.URLError, ValueError) as error:
        raise ValueError(spec['name'] + ' 没有返回 Key，请重新授权。') from error
    if not isinstance(key, str) or not key:
        raise ValueError(spec['name'] + ' 没有返回 Key，请重新授权。')
    return {'ok': True, 'key': key}
