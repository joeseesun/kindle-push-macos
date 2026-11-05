"""Paired Kindles: each is known by its SSH host key, a name, and the address it was last seen at.

All devices share this Mac's one client key; each has its own host-key alias in known_hosts
(`kindle-push` for the first one, as earlier versions wrote it), so StrictHostKeyChecking still
pins every connection to the Kindle it was meant for. The list lives in config.json; `host`
there stays the current device's address for the command line.

`selected` is the set of Kindles a book goes to; `current` is always one of them, the one the
connection status follows. With one selected, the two are the same and it behaves as before.
"""
import json
import re
import tempfile
from pathlib import Path
import kindle_push as kp

FIRST_ALIAS = 'kindle-push'


def _read():
    return json.loads(kp.CONFIG.read_text()) if kp.CONFIG.exists() else {}


def _known():
    """(alias, key) pairs from known_hosts, in file order."""
    path = kp.DATA / 'known_hosts'
    if not path.exists():
        return []
    pairs = []
    for line in path.read_text().splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[0].startswith(FIRST_ALIAS) and fields[1] == 'ssh-ed25519':
            pairs.append((fields[0], fields[2]))
    return pairs


def _write(path, text, mode=0o600):
    kp.DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile('w', dir=path.parent, delete=False) as file:
        file.write(text)
        temp = Path(file.name)
    temp.chmod(mode)
    temp.replace(path)


def load():
    """(devices, current id). Pairings from before the list existed are adopted on first read."""
    config = _read()
    devices = config.get('devices')
    if devices is None:
        devices = []
        for index, (alias, key) in enumerate(_known()):
            devices.append({'id': 'k%d' % (index + 1), 'name': '我的 Kindle' if index == 0 else 'Kindle %d' % (index + 1),
                            'alias': alias, 'key': key, 'host': config.get('host', '') if index == 0 else ''})
    current = config.get('current')
    if devices and not any(d['id'] == current for d in devices):
        current = devices[0]['id']
    return devices, current


def selected():
    """Ids of the Kindles books go to, in list order. Never empty while any Kindle is paired."""
    devices, chosen = load()
    wanted = _read().get('selected') or []
    ids = [d['id'] for d in devices if d['id'] in wanted]
    return ids or ([chosen] if chosen else [])


def set_selected(ids):
    """Choose which Kindles books go to. The current one stays if it is still chosen."""
    devices, chosen = load()
    ids = [d['id'] for d in devices if d['id'] in ids]
    if not ids:
        raise ValueError('至少要选一台 Kindle。')
    save(devices, chosen if chosen in ids else ids[0], ids)
    return ids


def save(devices, current, chosen_set=None):
    config = _read()
    existing = {d['id'] for d in devices}
    wanted = [i for i in (chosen_set if chosen_set is not None else config.get('selected') or []) if i in existing]
    config['devices'] = devices
    config['current'] = current
    config['selected'] = wanted or ([current] if current else [])
    chosen = next((d for d in devices if d['id'] == current), None)
    config['host'] = chosen['host'] if chosen else ''
    if not chosen:
        config.pop('host')
    _write(kp.CONFIG, json.dumps(config, indent=2, ensure_ascii=False) + '\n', 0o644)
    _write(kp.DATA / 'known_hosts', ''.join(f'{d["alias"]} ssh-ed25519 {d["key"]}\n' for d in devices))
    if not devices:
        (kp.DATA / 'known_hosts').unlink(missing_ok=True)


def current():
    devices, chosen = load()
    return next((d for d in devices if d['id'] == chosen), None)


def by_key(key):
    return next((d for d in load()[0] if d['key'] == key), None)


def find(device_id):
    device = next((d for d in load()[0] if d['id'] == device_id), None)
    if not device:
        raise ValueError('没有这台 Kindle 的配对记录。')
    return device


def add(key, host, name=''):
    """Pair a Kindle, or, for one already paired, note its new address. Returns the device."""
    devices, chosen = load()
    device = next((d for d in devices if d['key'] == key), None)
    if device is None:
        aliases = {d['alias'] for d in devices}
        alias = FIRST_ALIAS if FIRST_ALIAS not in aliases else next(
            f'{FIRST_ALIAS}-{n}' for n in range(2, 1000) if f'{FIRST_ALIAS}-{n}' not in aliases)
        ids = {d['id'] for d in devices}
        number = next(n for n in range(1, 1000) if 'k%d' % n not in ids)
        device = {'id': 'k%d' % number, 'alias': alias, 'key': key, 'host': host,
                  'name': clean_name(name) or ('我的 Kindle' if not devices else 'Kindle %d' % (len(devices) + 1))}
        devices.append(device)
    else:
        device['host'] = host
        if name.strip():
            device['name'] = clean_name(name)
    save(devices, chosen or device['id'])
    return device


def update(device_id, **fields):
    devices, chosen = load()
    for device in devices:
        if device['id'] == device_id:
            if 'name' in fields:
                name = clean_name(fields['name'])
                if not name:
                    raise ValueError('名字不能为空。')
                device['name'] = name
            if 'host' in fields:
                device['host'] = fields['host']
            if fields.get('select'):
                # One selected: it simply moves. Several: the set is kept, and this one joins it.
                wanted = _read().get('selected') or []
                wanted = [i for i in wanted if any(d['id'] == i for d in devices)]
                keep = wanted + [device_id] if len(wanted) > 1 and device_id not in wanted else (wanted if len(wanted) > 1 else [device_id])
                save(devices, device_id, keep)
            else:
                save(devices, chosen)
            return device
    raise ValueError('没有这台 Kindle 的配对记录。')


def forget(device_id):
    devices, chosen = load()
    remaining = [d for d in devices if d['id'] != device_id]
    if len(remaining) == len(devices):
        raise ValueError('没有这台 Kindle 的配对记录。')
    save(remaining, chosen if chosen != device_id else (remaining[0]['id'] if remaining else None))


def clean_name(name):
    return re.sub(r'\s+', ' ', name or '').strip()[:30]


def public(device, chosen=None, online=None, targets=None):
    item = {'id': device['id'], 'name': device['name'], 'host': device.get('host', ''),
            'current': device['id'] == chosen,
            'selected': device['id'] in targets if targets is not None else device['id'] == chosen}
    if online is not None:
        item['online'] = online
    return item
