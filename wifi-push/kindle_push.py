#!/opt/homebrew/bin/python3
"""Local article/ebook → EPUB (or native KOReader format) → key-authenticated Kindle transfer."""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import zipfile
from html import escape
from markdown_support import prepare_markdown, vault_root
from urllib.parse import quote, unquote

DATA = Path.home() / 'Library/Application Support/KindlePush'
CONFIG = DATA / 'config.json'
OUT = Path.home() / 'Documents/Kindle推送/已转换'
PANDOC = next((p for p in ['/opt/homebrew/bin/pandoc', '/usr/local/bin/pandoc', shutil.which('pandoc')] if p and Path(p).is_file()), '/opt/homebrew/bin/pandoc')
CSS = Path(__file__).with_name('ebook.css')

MARKDOWN = {'.md', '.markdown'}
# Converted to EPUB by Pandoc for chapters, encoding detection and the reading stylesheet.
DOCUMENTS = {'.txt': 'html', '.html': 'html', '.htm': 'html', '.xhtml': 'html',
             '.docx': 'docx', '.odt': 'odt', '.rtf': 'rtf'}
# Every other book format KOReader registers (credocument/pdfdocument/djvudocument/picdocument);
# sent unchanged. Needs receiver protocol v2. Must match kindle-receive.sh.
NATIVE = {'.pdf', '.xps', '.djvu', '.djv', '.cbz', '.cbr', '.cbt',
          '.mobi', '.azw', '.azw3', '.prc', '.pdb', '.tcr', '.fb2', '.fb3', '.chm', '.doc', '.docm',
          '.fb2.zip', '.txt.zip', '.html.zip', '.htm.zip', '.htmlz', '.rtf.zip', '.md.zip',
          '.png', '.jpg', '.jpeg', '.gif', '.webp', '.tif', '.tiff'}
MOBI = {'.mobi', '.azw', '.azw3', '.prc'}
RECEIVER_VERSIONS = {b'kindle-push-v1', b'kindle-push-v2'}
SUPPORTED = {'.epub'} | MARKDOWN | set(DOCUMENTS) | NATIVE
CHAPTER = re.compile(r'^\s*(第[0-9０-９零〇一二三四五六七八九十百千万两]+[章节回卷部集篇幕]|序章|序言|楔子|引子|尾声|后记|番外|(chapter|part)\s+[0-9ivxlc]+\b)', re.I)

def extension(path):
    """'.fb2.zip' for zipped books, otherwise the plain suffix."""
    double = ''.join(path.suffixes[-2:]).lower()
    return double if double in NATIVE else path.suffix.lower()

def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def validate_epub(path):
    try:
        with zipfile.ZipFile(path) as archive:
            if archive.read('mimetype').strip() != b'application/epub+zip' or 'META-INF/container.xml' not in archive.namelist() or archive.testzip():
                raise ValueError('EPUB 结构或内容校验失败：' + path.name)
    except (zipfile.BadZipFile, KeyError) as error:
        raise ValueError('不是有效的 EPUB 文件：' + path.name) from error


def decode_text(data):
    for encoding in ('utf-8-sig', 'gb18030', 'big5', 'utf-16'):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    raise ValueError('无法识别文本编码，请另存为 UTF-8 后再试。')


def text_to_html(source):
    """Plain text: one paragraph per line, recognised chapter lines become headings."""
    lines = decode_text(source.read_bytes()).replace('\r\n', '\n').replace('\r', '\n').split('\n')
    body = []
    for line in lines:
        line = line.strip().strip('\u3000')
        if not line:
            continue
        tag = 'h2' if len(line) <= 40 and CHAPTER.match(line) else 'p'
        body.append(f'<{tag}>{escape(line)}</{tag}>')
    if not body:
        raise ValueError('文本是空的：' + source.name)
    return f'<html><head><title>{escape(source.stem)}</title></head><body>\n' + '\n'.join(body) + '\n</body></html>'


def validate_native(source):
    head = source.open('rb').read(4096)
    suffix = extension(source)
    if suffix == '.pdf' and not head.startswith(b'%PDF'):
        raise ValueError('不是有效的 PDF 文件：' + source.name)
    if suffix == '.djvu' and not head.startswith(b'AT&TFORM'):
        raise ValueError('不是有效的 DjVu 文件：' + source.name)
    if (suffix == '.cbz' or suffix.endswith('.zip') or suffix == '.htmlz') and not zipfile.is_zipfile(source):
        raise ValueError('不是有效的压缩包：' + source.name)
    if suffix in MOBI | {'.pdb'} and len(head) < 78:
        raise ValueError('文件不完整：' + source.name)
    if suffix in MOBI:
        if head[60:68] != b'BOOKMOBI':
            if suffix == '.prc' and head[60:68] == b'TEXtREAd':
                return
            raise ValueError('不是有效的 MOBI/AZW 文件：' + source.name)
        record0 = int.from_bytes(head[78:82], 'big')
        with source.open('rb') as file:
            file.seek(record0 + 12)
            if int.from_bytes(file.read(2), 'big'):
                raise ValueError('这本书带有 DRM 保护，KOReader 无法打开：' + source.name)


def pandoc_document(source, reader, folder):
    epub = Path(folder) / 'book.epub'
    log = Path(folder) / 'pandoc.json'
    if source.suffix.lower() == '.txt':
        draft = Path(folder) / 'book.html'
        draft.write_text(text_to_html(source), encoding='utf-8')
    else:
        draft = source
    parsed = run([PANDOC, str(draft), '--from=' + reader, '--to=json'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    meta = json.loads(parsed.stdout)['meta']
    metadata = [] if 'title' in meta else ['--metadata=title:' + source.stem]
    if 'lang' not in meta: metadata.append('--metadata=lang:zh-CN')
    run([PANDOC, str(draft), '--from=' + reader, '--to=epub3', '--resource-path=' + str(source.parent),
         *metadata, '--css=' + str(CSS), '--toc', '--toc-depth=2', '--split-level=2',
         '--standalone', '--log=' + str(log), '--output=' + str(epub)],
        cwd=source.parent, stderr=subprocess.PIPE, timeout=300)
    # Office/HTML sources often carry styling Pandoc drops; report, do not stop.
    for entry in json.loads(log.read_text()):
        if entry.get('verbosity') in {'WARNING', 'ERROR'} and entry.get('type') not in {'CouldNotLoadTranslations', 'NoTranslation'}:
            print('提示：' + entry.get('pretty', str(entry)))
    validate_epub(epub)
    return epub.read_bytes()


def convert(source):
    source = source.expanduser().resolve(strict=True)
    OUT.mkdir(parents=True, exist_ok=True)
    suffix = extension(source)
    if suffix == '.epub':
        validate_epub(source)
        content = source.read_bytes()
    elif suffix in NATIVE:
        validate_native(source)
        content = source.read_bytes()
    elif suffix in DOCUMENTS:
        with tempfile.TemporaryDirectory(prefix='kindle-push-') as folder:
            content = pandoc_document(source, DOCUMENTS[suffix], folder)
        suffix = '.epub'
    elif suffix in MARKDOWN:
        suffix = '.epub'

        markdown, warnings = prepare_markdown(source)
        for warning in warnings:
            print('提示：' + warning)
        with tempfile.TemporaryDirectory(prefix='kindle-push-') as folder:
            draft = Path(folder) / 'article.md'
            epub = Path(folder) / 'article.epub'
            log = Path(folder) / 'pandoc.json'
            draft.write_text(markdown, encoding='utf-8')
            reader = 'markdown+task_lists+pipe_tables+strikeout+autolink_bare_uris'
            parsed = run([PANDOC, str(draft), '--from=' + reader, '--to=json'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
            meta = json.loads(parsed.stdout)['meta']
            metadata = []
            if 'title' not in meta: metadata.append('--metadata=title:' + source.stem)
            if 'lang' not in meta: metadata.append('--metadata=lang:zh-CN')
            run([PANDOC, str(draft), '--from=' + reader, '--to=epub3',
                 '--resource-path=' + str(source.parent) + os.pathsep + str(vault_root(source)),
                 *metadata, '--css=' + str(CSS), '--toc', '--toc-depth=3', '--syntax-highlighting=none',
                 '--standalone', '--log=' + str(log), '--output=' + str(epub)],
                cwd=source.parent, stderr=subprocess.PIPE, timeout=120)
            messages = json.loads(log.read_text())
            problems = [entry for entry in messages if entry.get('verbosity') in {'WARNING', 'ERROR'}
                        and entry.get('type') not in {'CouldNotLoadTranslations', 'NoTranslation'}]
            if problems:
                raise ValueError('转换需处理：' + '; '.join(e.get('pretty', str(e)) for e in problems))
            validate_epub(epub)
            content = epub.read_bytes()
    else:
        raise ValueError('暂不支持这种格式：' + source.name)
    # Stable per-source name: repeated sends replace that article, without clutter.
    stem = source.name[:-len(extension(source))] if source.name.lower().endswith(extension(source)) else source.stem
    title = re.sub(r'[\x00-\x1f/\\:]', '-', stem).strip('. ')[:60] or '文章'
    identity = hashlib.sha256(str(source).encode()).hexdigest()[:8]
    # KOReader registers KF8 books as .azw only; the bytes are the same.
    output = OUT / (f'{title}-{identity}' + ('.azw' if suffix == '.azw3' else suffix))
    if len(content) > 100 * 1024 * 1024:
        raise ValueError('文件超过 100 MB，请压缩后再发送。')
    with tempfile.NamedTemporaryFile(dir=OUT, suffix=suffix, delete=False) as handle:
        handle.write(content)
        temporary = Path(handle.name)
    try:
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return output

def get_config(host=None):
    config = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    if host:
        address = ipaddress.ip_address(host.strip())
        if address.version != 4 or not address.is_private or address.is_loopback:
            raise ValueError('请输入 Kindle 在同一 Wi-Fi 下的局域网 IPv4 地址。')
        config['host'] = str(address)
        DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
        CONFIG.write_text(json.dumps(config, indent=2) + '\n')
    if not config.get('host'):
        raise ValueError('还没设置 Kindle IP。首次运行时输入 KOReader 网络信息里的 IP。')
    return config

def ssh(config, operation, content=b''):
    key = DATA / 'id_ed25519'
    if not key.exists():
        raise ValueError('USB 首次配置尚未完成。')
    result = run(['/usr/bin/ssh', '-F', '/dev/null', '-T', '-p', '2222', '-i', str(key),
        '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=yes', '-o', 'HostKeyAlias=kindle-push',
        '-o', 'HostKeyAlgorithms=ssh-ed25519',
        '-o', 'UserKnownHostsFile="' + str(DATA / 'known_hosts') + '"',
        '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=10',
        '-o', 'ServerAliveCountMax=3', 'root@' + config['host'], operation],
        input=content, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
    return result.stdout

def send(epub, config):
    content = epub.read_bytes()
    version = ssh(config, 'ping').strip()
    if version not in RECEIVER_VERSIONS:
        raise ValueError('接收端未配置好。')
    if extension(epub) != '.epub' and version == b'kindle-push-v1':
        raise ValueError('Kindle 上的接收端是旧版，只收 EPUB。发送 ' + extension(epub)[1:].upper()
                         + ' 需要用 USB 连接 Kindle，重新运行一次首次配置；EPUB、Markdown、TXT、Word 等不受影响。')
    filename = epub.name.encode('utf-8') + b'\n'
    response = ssh(config, 'put', filename + str(len(content)).encode() + b'\n' + content)
    if response.strip() != b'OK':
        raise ValueError('Kindle 没有确认接收。')
    received = ssh(config, 'get', filename)
    if hashlib.sha256(received).digest() != hashlib.sha256(content).digest():
        raise ValueError('传输校验未通过，请重试。')
    print('已发送并校验：' + epub.name)
    print('Kindle → 文件浏览器 → documents → 我的文章')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('files', nargs='*', type=Path)
    parser.add_argument('--host')
    parser.add_argument('--convert-only', action='store_true')
    parser.add_argument('--interactive', action='store_true')
    args = parser.parse_args()
    if args.interactive:
        print('乔木 Kindle 助手：两台设备连接同一 Wi-Fi，Kindle 打开 KOReader。\n')
        if not args.files:
            raw = input('把文章或电子书拖进这个窗口，然后按回车：\n').strip()
            args.files = [Path(p) for p in shlex.split(raw)]
        previous = json.loads(CONFIG.read_text()).get('host', '') if CONFIG.exists() else ''
        args.host = input('Kindle IP' + (f'（回车沿用 {previous}）' if previous else '') + '：').strip() or previous
    if not args.files:
        parser.error('请指定至少一个文件：' + '、'.join(sorted(SUPPORTED)))
    config = None if args.convert_only else get_config(args.host)
    for source in args.files:
        epub = convert(source)
        print('已转换：' + str(epub))
        if config:
            send(epub, config)

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('\n未完成：' + str(error), file=sys.stderr)
        print('如连接失败：确认 Kindle 打开 KOReader、Wi-Fi 已开启，IP 地址正确。', file=sys.stderr)
        sys.exit(1)
