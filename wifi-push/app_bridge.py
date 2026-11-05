#!/opt/homebrew/bin/python3
"""JSON bridge used by the native Mac app. No service or cloud account."""
import concurrent.futures
import contextlib
import hashlib
import io
import ipaddress
import json
import re
import socket
import subprocess
import sys
from pathlib import Path
import kindle_push as kp


def config():
    return json.loads(kp.CONFIG.read_text()) if kp.CONFIG.exists() else {}


def valid_host(value):
    ip = ipaddress.ip_address(value)
    if ip.version != 4 or not ip.is_private or ip.is_loopback or ip.is_unspecified or ip.is_multicast:
        raise ValueError('请输入 Kindle 网络信息里的 IPv4 地址，例如 192.168.1.42。')
    return str(ip)


def trusted_key():
    path = kp.DATA / 'known_hosts'
    if path.exists():
        for line in path.read_text().splitlines():
            fields = line.split()
            if len(fields) >= 3 and fields[0] == 'kindle-push' and fields[1] == 'ssh-ed25519':
                return fields[2]
    raise ValueError('缺少已配对 Kindle 的身份记录，请恢复本机 KindlePush 配置。')


def reachable(host, timeout=0.45):
    try:
        with socket.create_connection((host, 2222), timeout=timeout):
            return True
    except OSError:
        return False


def matches_device(host, key):
    try:
        result = subprocess.run(['/usr/bin/ssh-keyscan', '-T', '2', '-p', '2222', '-t', 'ed25519', host],
                                capture_output=True, timeout=4)
        return any(len(parts := line.split()) >= 3 and parts[1] == 'ssh-ed25519' and parts[2] == key
                   for line in result.stdout.decode().splitlines())
    except (OSError, subprocess.TimeoutExpired):
        return False


def verify(host):
    host = valid_host(host)
    if not reachable(host, 2):
        raise ValueError('没有连上 Kindle。请连接同一个 Wi-Fi，在 Kindle 打开 KOReader；然后点“自动寻找”。')
    if not matches_device(host, trusted_key()):
        raise ValueError('这个地址的设备与已配对 Kindle 不一致。请核对 IP；应用没有发送文件。')
    if kp.ssh({'host': host}, 'ping').strip() not in kp.RECEIVER_VERSIONS:
        raise ValueError('Kindle 接收服务没有正常响应，请重新打开 KOReader。')
    kp.get_config(host)
    return host


def local_candidates():
    """Only active physical LANs; /24 cap on larger LANs plus observed ARP peers."""
    raw = subprocess.run(['/sbin/ifconfig'], capture_output=True, text=True, check=True).stdout
    candidates, own, networks = set(), set(), []
    for block in re.split(r'(?=^\S[^\n]*: flags=)', raw, flags=re.M):
        if not re.match(r'(en\d+|bridge\d+):', block) or 'status: active' not in block:
            continue
        for addr, mask in re.findall(r'\binet (\d+\.\d+\.\d+\.\d+) netmask (0x[0-9a-f]+)', block):
            ip = ipaddress.ip_address(addr)
            if not ip.is_private or ip.is_loopback:
                continue
            own.add(addr)
            prefix = bin(int(mask, 16)).count('1')
            original = ipaddress.ip_network(f'{addr}/{prefix}', strict=False)
            networks.append(original)
            net = ipaddress.ip_network(f'{addr}/{max(prefix, 24)}', strict=False)
            candidates.update(str(h) for h in net.hosts())
    arp = subprocess.run(['/usr/sbin/arp', '-an'], capture_output=True, text=True).stdout
    for addr in re.findall(r'\((\d+\.\d+\.\d+\.\d+)\)', arp):
        if any(ipaddress.ip_address(addr) in net for net in networks):
            candidates.add(addr)
    return sorted(candidates - own, key=ipaddress.ip_address)[:1024]


def discover(force_scan=False):
    key = trusted_key()
    previous = config().get('host', '')
    if previous and not force_scan:
        try:
            return verify(previous)
        except (ValueError, OSError, subprocess.SubprocessError):
            pass
    candidates = local_candidates()
    if not candidates:
        raise ValueError('未发现可用局域网。请先连接 Wi-Fi，或在“手动连接”中输入 Kindle IP。')
    found = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
        futures = {pool.submit(reachable, host): host for host in candidates}
        for future in concurrent.futures.as_completed(futures):
            if future.result():
                found.append(futures[future])
    for host in found:
        if matches_device(host, key):
            return verify(host)
    raise ValueError('未找到已配对的 Kindle。请确认两台设备在同一 Wi-Fi、Kindle 已打开 KOReader；访客网络可能隔离设备。也可以手动输入 IP。')


def handle(args):
    command = args[0]
    if command in {'codex-status', 'codex-login', 'codex-logout', 'models', 'sign-in-key'}:
        import accounts
        if command == 'codex-status': return accounts.codex_status()
        if command == 'codex-login': return accounts.codex_login()
        if command == 'codex-logout': return accounts.codex_logout()
        if command == 'models':
            # A key typed but not yet saved comes on stdin; otherwise use the one saved for this address.
            key = sys.stdin.readline().strip() if len(args) > 2 and args[2] == '--key-stdin' else ''
            if not key:
                import translation as tr
                base = tr.endpoint(args[1])
                saved = tr.settings()
                # Not named `config`: that would shadow the module's config() for all of handle().
                route = saved if saved.get('base') == base and saved.get('service') else {'base': base, 'service': tr.KEY_SERVICE, 'account': tr.own_account(base)}
                if tr.has_key(route): key = tr.read_key(route)
            return accounts.list_models(args[1], key)
        return accounts.sign_in_key(args[1])
    if command.startswith('translation-'):
        import translation as tr
        if command == 'translation-settings': return tr.public_settings()
        if command == 'translation-save': return tr.save_settings(**json.loads(args[1]))
        if command == 'translation-install': return tr.install()
        if command == 'translation-start': return tr.start(args[1], len(args) > 2 and args[2] == 'preview', args[3] if len(args) > 3 else 'bilingual')
        if command == 'translation-progress': return tr.progress(args[1])
        if command == 'translation-find': return tr.find(args[1])
        if command == 'translation-cancel': return tr.cancel(args[1])
        raise ValueError('未知翻译操作。')
    if command == 'tidy-names':
        # stdin: {"items": [{"path", "title", "author"}], "smart": bool, "author": bool}
        import names
        request = json.loads(sys.stdin.read())
        return {'ok': True, 'names': [names.suggest(i['path'], i.get('title') or '', i.get('author') or '',
                                                    request.get('smart', True), request.get('author', False))
                                      for i in request['items']]}
    if command == 'book-info':
        import bookinfo
        return bookinfo.info(args[1])
    if command == 'status':
        missing = [str(p) for p in [Path(kp.PANDOC), kp.DATA / 'id_ed25519', kp.DATA / 'known_hosts'] if not p.exists()]
        if missing:
            raise ValueError('缺少本机组件：' + '、'.join(missing))
        return {'ok': True, 'host': config().get('host', ''), 'output': str(kp.OUT)}
    if command in {'discover', 'scan', 'connect'}:
        host = verify(args[1]) if command == 'connect' else discover(command == 'scan')
        return {'ok': True, 'host': host, 'message': 'Kindle 已连接'}
    if command == 'convert':
        log = io.StringIO()
        with contextlib.redirect_stdout(log):
            output = kp.convert(Path(args[1]))
        return {'ok': True, 'output': str(output), 'message': '已保存到本机', 'details': log.getvalue()}
    if command == 'send':
        host = verify(args[1])
        source = Path(args[2])
        log = io.StringIO()
        with contextlib.redirect_stdout(log):
            epub = kp.convert(source)
            sent = kp.send(epub, {'host': host})
        # A PDF sent as image volumes: point the row at the first volume.
        epub = sent[0] if sent and sent[0] != epub else epub
        return {'ok': True, 'host': host, 'output': str(epub),
                'message': '已发送并校验', 'details': log.getvalue(),
                'sha256': hashlib.sha256(epub.read_bytes()).hexdigest()}
    raise ValueError('未知操作。')


if __name__ == '__main__':
    try:
        result = handle(sys.argv[1:])
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or b'').decode(errors='replace') if isinstance(error.stderr, bytes) else str(error.stderr or '')
        result = {'ok': False, 'message': '连接或转换未完成。请检查 Kindle Wi-Fi 和 KOReader，然后重试。', 'details': detail[-2000:]}
    except Exception as error:
        result = {'ok': False, 'message': str(error)}
    print(json.dumps(result, ensure_ascii=False))
