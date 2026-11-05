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
import devices as dv


def config():
    return json.loads(kp.CONFIG.read_text()) if kp.CONFIG.exists() else {}


def valid_host(value):
    ip = ipaddress.ip_address(value)
    if ip.version != 4 or not ip.is_private or ip.is_loopback or ip.is_unspecified or ip.is_multicast:
        raise ValueError('请输入 Kindle 网络信息里的 IPv4 地址，例如 192.168.1.42。')
    return str(ip)

def paired():
    found = dv.load()[0]
    if not found:
        raise ValueError('缺少已配对 Kindle 的身份记录，请恢复本机 KindlePush 配置。')
    return found


def reachable(host, timeout=0.45):
    try:
        with socket.create_connection((host, 2222), timeout=timeout):
            return True
    except OSError:
        return False


def host_key(host, attempts=2):
    """The ED25519 host key `host` presents on the receiver port, without authenticating.

    A Kindle busy writing a book can take seconds to answer, so a slow reply is retried."""
    for attempt in range(attempts):
        try:
            result = subprocess.run(['/usr/bin/ssh-keyscan', '-T', str(3 + 2 * attempt), '-p', '2222', '-t', 'ed25519', host],
                                    capture_output=True, timeout=10 + 4 * attempt)
        except (OSError, subprocess.TimeoutExpired):
            continue
        for line in result.stdout.decode().splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[1] == 'ssh-ed25519':
                return parts[2]
    return None


def identify(host, known):
    """The paired Kindle at `host`, or None for any other device."""
    key = host_key(host)
    return next((d for d in known if d['key'] == key), None) if key else None


MISMATCH = '这个地址的设备与已配对 Kindle 不一致。请核对 IP；应用没有发送文件。'
NO_ANSWER = 'Kindle 暂时没有响应。请确认它没有休眠、KOReader 仍在前台，然后重试。'


def ping(host, device):
    """The receiver's answer, over a connection pinned to `device`'s host key."""
    for attempt in range(2):
        try:
            return kp.ssh({'host': host, 'alias': device['alias']}, 'ping', timeout=30).strip()
        except subprocess.CalledProcessError as error:
            detail = error.stderr or b''
            if b'Host key verification failed' in detail or b'IDENTIFICATION HAS CHANGED' in detail:
                raise ValueError(MISMATCH) from error
        except subprocess.TimeoutExpired:
            pass
    raise ValueError(NO_ANSWER)


def verify(host, expected=None):
    """Connect to the paired Kindle at `host` (the one with id `expected`, when given) and make it current.

    With `expected`, SSH itself checks the host key, so no separate scan is needed; a different
    device at that address fails the handshake and nothing is sent."""
    host = valid_host(host)
    if not reachable(host, 3):
        raise ValueError('没有连上 Kindle。请连接同一个 Wi-Fi，在 Kindle 打开 KOReader；然后点“自动寻找”。')
    if expected:
        device = next((d for d in paired() if d['id'] == expected), None)
        if device is None:
            raise ValueError('没有这台 Kindle 的配对记录。')
    else:
        key = host_key(host)
        if key is None:
            raise ValueError(NO_ANSWER)
        device = next((d for d in paired() if d['key'] == key), None)
        if device is None:
            raise ValueError(MISMATCH)
    if ping(host, device) not in kp.RECEIVER_VERSIONS:
        raise ValueError('Kindle 接收服务没有正常响应，请重新打开 KOReader。')
    dv.update(device['id'], host=host, select=True)
    return host, device


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


def scan(known):
    """{device id: host} for every paired Kindle answering on this network."""
    candidates = local_candidates()
    if not candidates:
        raise ValueError('未发现可用局域网。请先连接 Wi-Fi，或在“手动连接”中输入 Kindle IP。')
    found = {}
    # A Kindle in Wi-Fi power saving can miss the quick probe; a second, slower pass wakes it.
    for timeout in (0.45, 1.5):
        with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
            open_hosts = [h for h, ok in zip(candidates, pool.map(lambda h: reachable(h, timeout), candidates)) if ok]
            for host, device in zip(open_hosts, pool.map(lambda h: identify(h, known), open_hosts)):
                if device and device['id'] not in found:
                    found[device['id']] = host
        if found:
            break
    return found


def unpaired(only=None):
    """Kindles on this network that answer on the receiver port but are not paired yet.

    `ready` means this Mac's receiver answered, so pairing will work; otherwise the Kindle
    still needs the receiver written over USB."""
    import setup_device as setup
    known = {d['key'] for d in dv.load()[0]}
    candidates = [valid_host(only)] if only else local_candidates()
    if not candidates:
        raise ValueError('未发现可用局域网。请先连接 Wi-Fi。')
    hosts = []
    for timeout in (0.45, 1.5):
        with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
            hosts = [h for h, ok in zip(candidates, pool.map(lambda h: reachable(h, timeout), candidates)) if ok]
        if hosts:
            break

    def check(host):
        key = host_key(host)
        if not key or key in known:
            return None
        item = {'host': host, 'key': key, 'fingerprint': setup.fingerprint(key), 'ready': False}
        try:
            setup.probe(host, key)
            item['ready'] = True
        except (ValueError, OSError, subprocess.SubprocessError):
            item['reason'] = '找到了 KOReader，但还没写入接收配置：先用 USB 连接这台 Kindle。'
        return item

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        return [item for item in pool.map(check, hosts) if item]


NOT_FOUND = '未找到已配对的 Kindle。请确认两台设备在同一 Wi-Fi、Kindle 已打开 KOReader；访客网络可能隔离设备。也可以手动输入 IP。'


def discover(force_scan=False):
    """Connect to the Kindle chosen last time, or, when it is away, to another paired one nearby."""
    known = paired()
    chosen = dv.current()
    if chosen and chosen.get('host') and not force_scan:
        try:
            return verify(chosen['host'], chosen['id'])
        except (ValueError, OSError, subprocess.SubprocessError):
            pass
    found = scan(known)
    order = [d['id'] for d in known]
    for device_id, host in found.items():
        dv.update(device_id, host=host)
    for device_id in sorted(found, key=lambda i: (i != (chosen or {}).get('id'), order.index(i))):
        try:
            return verify(found[device_id], device_id)
        except (ValueError, OSError, subprocess.SubprocessError):
            continue
    raise ValueError(NOT_FOUND)


def device_list(full_scan=False):
    """Paired Kindles and which are on this network: a quick check of each last address, or a full scan."""
    known, chosen = dv.load()
    if full_scan and known:
        online = scan(known)
        for device_id, host in online.items():
            dv.update(device_id, host=host)
        known, chosen = dv.load()
    else:
        def here(device):
            host = device.get('host')
            return bool(host) and reachable(host, 0.8) and (identify(host, [device]) is not None)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            online = {d['id'] for d, ok in zip(known, pool.map(here, known)) if ok}
    return [dv.public(d, chosen, d['id'] in online) for d in known]


def select(device_id):
    """Make `device_id` the Kindle books go to, and connect to it if it is on this network."""
    device = dv.find(device_id)
    dv.update(device_id, select=True)
    if device.get('host'):
        try:
            return verify(device['host'], device_id)
        except (ValueError, OSError, subprocess.SubprocessError):
            pass
    found = scan([device])
    if device_id in found:
        return verify(found[device_id], device_id)
    raise ValueError(f'已切换到「{device["name"]}」，但它现在不在这个 Wi-Fi 里。请在这台 Kindle 上打开 KOReader，再点“重新寻找”。')


def connected(host, device, message='Kindle 已连接'):
    return {'ok': True, 'host': host, 'device': device['name'], 'deviceId': device['id'], 'message': message}


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
        chosen = dv.current()
        return {'ok': True, 'host': chosen['host'] if chosen else config().get('host', ''), 'output': str(kp.OUT),
                'device': chosen['name'] if chosen else None, 'deviceId': chosen['id'] if chosen else None}
    if command in {'discover', 'scan', 'connect'}:
        before = dv.current()
        host, device = verify(args[1]) if command == 'connect' else discover(command == 'scan')
        if command != 'connect' and before and before['id'] != device['id']:
            # The chosen Kindle is away: say so, never switch silently.
            return connected(host, device, f'「{before["name"]}」不在这个 Wi-Fi 里，已改为发到「{device["name"]}」')
        return connected(host, device)
    if command == 'devices':
        return {'ok': True, 'devices': device_list(len(args) > 1 and args[1] == 'scan')}
    if command in {'usb-volumes', 'usb-install', 'find-new', 'pair'}:
        import setup_device as setup
        if command == 'usb-install':
            if not any(v['path'] == args[1] and v['ready'] for v in setup.kindle_volumes()):
                raise ValueError('没有在这个磁盘上找到 KOReader。请确认 Kindle 已用 USB 连接，并且运行过 KOReader。')
            with contextlib.redirect_stdout(io.StringIO()):
                setup.install_usb(Path(args[1]))
        if command in {'usb-volumes', 'usb-install'}:
            return {'ok': True, 'volumes': setup.kindle_volumes()}
        if command == 'find-new':
            return {'ok': True, 'candidates': unpaired(args[1] if len(args) > 1 else None)}
        return connected(*(lambda d: (d['host'], d))(setup.pair(args[1], args[2], args[3] if len(args) > 3 else '')),
                         message='配对成功')
    if command == 'select':
        return connected(*select(args[1]))
    if command == 'rename':
        dv.update(args[1], name=args[2])
        return {'ok': True, 'devices': device_list()}
    if command == 'forget':
        dv.forget(args[1])
        return {'ok': True, 'devices': device_list()}
    if command == 'convert':
        log = io.StringIO()
        with contextlib.redirect_stdout(log):
            output = kp.convert(Path(args[1]))
        return {'ok': True, 'output': str(output), 'message': '已保存到本机', 'details': log.getvalue()}
    if command == 'send':
        # The id pins the send to the Kindle the user chose, wherever its address has moved.
        host, device = verify(args[1], args[3] if len(args) > 3 else None)
        source = Path(args[2])
        log = io.StringIO()
        with contextlib.redirect_stdout(log):
            epub = kp.convert(source)
            sent = kp.send(epub, {'host': host, 'alias': device['alias']})
        # A PDF sent as image volumes: point the row at the first volume.
        epub = sent[0] if sent and sent[0] != epub else epub
        return {'ok': True, 'host': host, 'device': device['name'], 'output': str(epub),
                'message': '已发送并校验', 'details': log.getvalue(),
                'sha256': hashlib.sha256(epub.read_bytes()).hexdigest()}
    raise ValueError('未知操作。')


def cancelled(*_):
    # The app cancels a transfer with SIGTERM. Raising here unwinds subprocess.run, which kills
    # its ssh child; the Kindle sees the connection drop and discards the partial file.
    raise SystemExit(130)


if __name__ == '__main__':
    import signal
    signal.signal(signal.SIGTERM, cancelled)
    try:
        result = handle(sys.argv[1:])
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or b'').decode(errors='replace') if isinstance(error.stderr, bytes) else str(error.stderr or '')
        result = {'ok': False, 'message': '连接或转换未完成。请检查 Kindle Wi-Fi 和 KOReader，然后重试。', 'details': detail[-2000:]}
    except Exception as error:
        result = {'ok': False, 'message': str(error)}
    print(json.dumps(result, ensure_ascii=False))
