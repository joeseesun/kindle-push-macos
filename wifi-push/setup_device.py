#!/usr/bin/env python3
"""Explicit one-time setup. Never ship a user's private key or host identity."""
import argparse
import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
import kindle_push as kp


def updated_settings(text):
    if not re.search(r'\breturn\s*\{', text) or not text.rstrip().endswith('}'):
        raise ValueError('无法识别 KOReader settings.reader.lua；未修改该文件。')
    settings = {'SSH_port': '"2222"', 'SSH_allow_no_password': 'false',
                'SSH_key_only_auth': 'true', 'SSH_autostart': 'true'}
    for key, value in settings.items():
        text = re.sub(r'^    \["' + key + r'"\] = [^\n]*\n', '', text, flags=re.M)
        text = text.rstrip()[:-1] + f'    ["{key}"] = {value},\n}}\n'
    return text


def atomic_write(path, content):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as file:
        file.write(content)
        temp = Path(file.name)
    try:
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


def install_usb(mount):
    mount = mount.expanduser().resolve()
    root = mount / 'koreader'
    settings = root / 'settings.reader.lua'
    if not settings.is_file() or not (root / 'dropbear').is_file() or not (mount / 'documents').is_dir():
        raise ValueError('没有找到已经运行过的 KOReader / Dropbear。请核对 Kindle 磁盘路径。')
    # Validate before any key or settings mutation.
    original = settings.read_text()
    replacement = updated_settings(original)
    kp.DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
    kp.DATA.chmod(0o700)
    key = kp.DATA / 'id_ed25519'
    if not key.exists():
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'kindle-push-macos', '-f', str(key)], check=True)
    key.chmod(0o600)
    public = subprocess.run(['/usr/bin/ssh-keygen', '-y', '-f', str(key)], capture_output=True, text=True, check=True).stdout.strip()
    (kp.DATA / 'id_ed25519.pub').write_text(public + ' kindle-push-macos\n')
    ssh = root / 'settings/SSH'
    ssh.mkdir(parents=True, exist_ok=True)
    backup = kp.DATA / 'backups' / datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    backup.mkdir(parents=True, mode=0o700)
    for path in [settings, ssh / 'authorized_keys', ssh / 'kindle-receive.sh']:
        if path.exists():
            shutil.copy2(path, backup / path.name)
            (backup / path.name).chmod(0o600)
    auth = ssh / 'authorized_keys'
    old = auth.read_text() if auth.exists() else ''
    public_blob = public.split()[1]
    # Replace only the matching application key, preserving unrelated user keys.
    keep = [line for line in old.splitlines() if public_blob not in line.split()]
    restrictions = 'command="sh /mnt/us/koreader/settings/SSH/kindle-receive.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty '
    atomic_write(auth, ('\n'.join(keep + [restrictions + public]) + '\n').encode())
    atomic_write(ssh / 'kindle-receive.sh', Path(__file__).with_name('kindle-receive.sh').read_bytes())
    atomic_write(settings, replacement.encode())
    print('USB 接收配置已写入。备份：' + str(backup))
    print('请在 Finder 安全弹出 Kindle，拔线；连接同一个 Wi-Fi，打开 KOReader。')
    print('然后运行：python3 wifi-push/setup_device.py pair-host <Kindle 的 IPv4 地址>')


def lan_ip(host):
    ip = ipaddress.ip_address(host)
    if ip.version != 4 or not ip.is_private or ip.is_loopback or ip.is_unspecified or ip.is_multicast:
        raise ValueError('请输入同一 Wi-Fi 下 Kindle 的局域网 IPv4 地址。')
    return str(ip)


def host_keys(ip, timeout=4):
    scan = subprocess.run(['/usr/bin/ssh-keyscan', '-T', str(timeout), '-p', '2222', '-t', 'ed25519', ip],
                          capture_output=True, text=True, timeout=timeout + 4)
    return [line.split()[2] for line in scan.stdout.splitlines() if len(line.split()) >= 3 and line.split()[1] == 'ssh-ed25519']


def fingerprint(key):
    return 'SHA256:' + base64.b64encode(hashlib.sha256(base64.b64decode(key)).digest()).decode().rstrip('=')


def probe(ip, key):
    """The receiver version at `ip`, trusting only `key` and nothing saved; raises when it does not answer."""
    if not (kp.DATA / 'id_ed25519').exists():
        raise ValueError('还没有写入过接收配置：先用 USB 连接 Kindle。')
    with tempfile.TemporaryDirectory() as folder:
        known = Path(folder) / 'known_hosts'
        known.write_text(f'kindle-push-new ssh-ed25519 {key}\n')
        version = kp.ssh({'host': ip, 'alias': 'kindle-push-new', 'known_hosts': known}, 'ping', timeout=20).strip()
    if version not in kp.RECEIVER_VERSIONS:
        raise ValueError('接收端未正常响应。')
    return version


def pair(host, key, name=''):
    """Pair the Kindle at `host` whose host key is `key` (the one the user was shown). Returns the device."""
    import devices
    ip = lan_ip(host)
    if key not in host_keys(ip):
        raise ValueError('这个地址上的设备身份变了，没有配对。请重新寻找。')
    probe(ip, key)
    device = devices.add(key, ip, name)
    devices.update(device['id'], host=ip, select=True)
    return device


def pair_host(host, name=''):
    ip = lan_ip(host)
    if not (kp.DATA / 'id_ed25519').exists():
        raise ValueError('请先执行 usb-install。')
    keys = host_keys(ip)
    if not keys:
        raise ValueError('没有收到 SSH 主机密钥。请确认 KOReader SSH 服务器已启动。')
    blob = keys[0]
    import devices
    if devices.by_key(blob) is None:
        others = devices.load()[0]
        print(('再配对一台 Kindle：' if others else '首次配对设备：') + ip)
        if others:
            print('已配对：' + '、'.join(d['name'] for d in others) + '。新设备会加入列表，原有配对不受影响。')
        print('ED25519 主机指纹：' + fingerprint(blob))
        print('请确认这个 IP 正是 Kindle 网络信息显示的地址，并在可信局域网操作。')
        if input('信任并保存该设备身份？输入 yes 继续：').strip() != 'yes':
            raise ValueError('已取消，未保存设备身份。')
    device = pair(ip, blob, name)
    print(f'已配对：{device["name"]}（{ip}）。可以在应用里改名，或切换发送到哪台 Kindle。')
    print('配对成功。现在可以打开 乔木 Kindle 助手.app，之后换 Wi-Fi 不需要重新插 USB。')


def kindle_volumes():
    """Mounted Kindles with KOReader, and whether this Mac's receiver is already written to each."""
    found = []
    public = kp.DATA / 'id_ed25519.pub'
    blob = public.read_text().split()[1] if public.exists() else None
    for mount in sorted(Path('/Volumes').iterdir()):
        root = mount / 'koreader'
        if not ((root / 'settings.reader.lua').is_file() and (mount / 'documents').is_dir()):
            continue
        auth = root / 'settings/SSH/authorized_keys'
        installed = bool(blob) and (root / 'settings/SSH/kindle-receive.sh').is_file() and auth.is_file() \
            and any(blob in line.split() for line in auth.read_text(errors='ignore').splitlines())
        found.append({'path': str(mount), 'name': mount.name, 'ready': (root / 'dropbear').is_file(), 'installed': installed})
    return found


def main():
    parser = argparse.ArgumentParser(description='乔木 Kindle 助手首次配置')
    sub = parser.add_subparsers(dest='command', required=True)
    usb = sub.add_parser('usb-install')
    usb.add_argument('--mount', type=Path, default=Path('/Volumes/Kindle'))
    pair = sub.add_parser('pair-host')
    pair.add_argument('host')
    pair.add_argument('--name', default='', help='这台 Kindle 的名字，例如「卧室 Paperwhite」')
    args = parser.parse_args()
    try:
        if args.command == 'usb-install': install_usb(args.mount)
        else: pair_host(args.host, args.name)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('未完成：' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
