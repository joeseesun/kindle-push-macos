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


def pair_host(host):
    ip = ipaddress.ip_address(host)
    if ip.version != 4 or not ip.is_private or ip.is_loopback or ip.is_unspecified or ip.is_multicast:
        raise ValueError('请输入同一 Wi-Fi 下 Kindle 的局域网 IPv4 地址。')
    if not (kp.DATA / 'id_ed25519').exists():
        raise ValueError('请先执行 usb-install。')
    scan = subprocess.run(['/usr/bin/ssh-keyscan', '-T', '4', '-p', '2222', '-t', 'ed25519', str(ip)], capture_output=True, text=True, timeout=8)
    keys = [line.split()[2] for line in scan.stdout.splitlines() if len(line.split()) >= 3 and line.split()[1] == 'ssh-ed25519']
    if not keys:
        raise ValueError('没有收到 SSH 主机密钥。请确认 KOReader SSH 服务器已启动。')
    blob = keys[0]
    entry = 'kindle-push ssh-ed25519 ' + blob + '\n'
    known = kp.DATA / 'known_hosts'
    old = known.read_bytes() if known.exists() else None
    if old and entry.encode() != old:
        raise ValueError('本机已配对其他设备身份。未覆盖记录；请参见 docs/SETUP.md 的重新配对说明。')
    if not old:
        fingerprint = base64.b64encode(hashlib.sha256(base64.b64decode(blob)).digest()).decode().rstrip('=')
        print('首次配对设备：' + str(ip))
        print('ED25519 主机指纹：SHA256:' + fingerprint)
        print('请确认这个 IP 正是 Kindle 网络信息显示的地址，并在可信局域网操作。')
        if input('信任并保存该设备身份？输入 yes 继续：').strip() != 'yes':
            raise ValueError('已取消，未保存设备身份。')
    atomic_write(known, entry.encode())
    known.chmod(0o600)
    try:
        if kp.ssh({'host': str(ip)}, 'ping').strip() not in kp.RECEIVER_VERSIONS:
            raise ValueError('接收端未正常响应。')
    except Exception:
        if old is None:
            known.unlink(missing_ok=True)
        raise
    kp.get_config(str(ip))
    print('配对成功。现在可以打开 乔木 Kindle 助手.app，之后换 Wi-Fi 不需要重新插 USB。')


def main():
    parser = argparse.ArgumentParser(description='乔木 Kindle 助手首次配置')
    sub = parser.add_subparsers(dest='command', required=True)
    usb = sub.add_parser('usb-install')
    usb.add_argument('--mount', type=Path, default=Path('/Volumes/Kindle'))
    pair = sub.add_parser('pair-host')
    pair.add_argument('host')
    args = parser.parse_args()
    try:
        if args.command == 'usb-install': install_usb(args.mount)
        else: pair_host(args.host)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('未完成：' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
