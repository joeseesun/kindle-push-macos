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
import threading
import zipfile
from html import escape
from markdown_support import prepare_markdown, vault_root
import names
from urllib.parse import quote, unquote

DATA = Path.home() / 'Library/Application Support/KindlePush'
CONFIG = DATA / 'config.json'
OUT = Path.home() / 'Documents/Kindle推送/已转换'
# The copy inside the app first; a source checkout uses whatever is installed.
PANDOC = next((p for p in [str(Path(__file__).resolve().parent / 'runtime/pandoc'), '/opt/homebrew/bin/pandoc',
                           '/usr/local/bin/pandoc', shutil.which('pandoc')] if p and Path(p).is_file()), 'pandoc')
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
RECEIVER_LATEST = b'kindle-push-v2'
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


def calibre():
    """Calibre's converter when it is installed: the only way this app can read MOBI/AZW text."""
    found = shutil.which('ebook-convert') or '/Applications/calibre.app/Contents/MacOS/ebook-convert'
    return found if Path(found).is_file() else None


def translatable(source):
    """Whether this file's text can be made into an EPUB to translate."""
    suffix = extension(source)
    if suffix in {'.epub', '.fb2'} | MARKDOWN | set(DOCUMENTS):
        return True
    return suffix in {'.mobi', '.azw', '.azw3'} and calibre() is not None


def epub_for_translation(source):
    """EPUB bytes of a book in any format `translatable` accepts."""
    suffix = extension(source)
    if suffix == '.epub':
        validate_epub(source)
        return source.read_bytes()
    if suffix == '.fb2':
        with tempfile.TemporaryDirectory(prefix='kindle-push-') as folder:
            return pandoc_document(source, 'fb2', folder)
    if suffix in {'.mobi', '.azw', '.azw3'}:
        validate_native(source)
        tool = calibre()
        if not tool:
            raise ValueError('翻译 MOBI/AZW 需要 Calibre 来提取文字。安装 Calibre 后再试，或换成 EPUB。')
        with tempfile.TemporaryDirectory(prefix='kindle-push-') as folder:
            target = Path(folder) / 'book.epub'
            run([tool, str(source), str(target)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=600)
            validate_epub(target)
            return target.read_bytes()
    if suffix in DOCUMENTS or suffix in MARKDOWN:
        return converted_content(source, suffix)[0]
    raise ValueError(suffix[1:].upper() + ' 是固定版式，暂时不能翻译。可以直接发送。')


def converted_content(source, suffix):
    """(bytes, suffix) of what is sent for `source`."""
    if suffix == '.epub':
        validate_epub(source)
        return source.read_bytes(), suffix
    if suffix in NATIVE:
        validate_native(source)
        return source.read_bytes(), suffix
    if suffix in DOCUMENTS:
        with tempfile.TemporaryDirectory(prefix='kindle-push-') as folder:
            return pandoc_document(source, DOCUMENTS[suffix], folder), '.epub'
    if suffix in MARKDOWN:

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
            return epub.read_bytes(), '.epub'
    raise ValueError('暂不支持这种格式：' + source.name)


def convert(source):
    source = source.expanduser().resolve(strict=True)
    OUT.mkdir(parents=True, exist_ok=True)
    suffix = extension(source)
    # Already one of our own files (a translation added back to the list): send it as it is.
    # Copying it would only make `title 2` next to itself.
    # (.azw3 still goes through: it is sent under the name .azw.)
    if source.parent == OUT.resolve() and suffix != '.azw3' and (suffix == '.epub' or suffix in NATIVE):
        converted_content(source, suffix)
        return source
    content, suffix = converted_content(source, suffix)
    # A clean, stable per-source name: repeated sends replace that article, without clutter.
    title = names.tidy(names.file_stem(source, extension(source)), smart=False)[:60].strip() or '文章'
    # KOReader registers KF8 books as .azw only; the bytes are the same.
    output = names.unique_output(OUT, title, '.azw' if suffix == '.azw3' else suffix, str(source))
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

def ssh_command(config, operation):
    key = DATA / 'id_ed25519'
    if not key.exists():
        raise ValueError('USB 首次配置尚未完成。')
    return ['/usr/bin/ssh', '-F', '/dev/null', '-T', '-p', '2222', '-i', str(key),
        '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=yes', '-o', 'HostKeyAlias=' + config.get('alias', 'kindle-push'),
        '-o', 'HostKeyAlgorithms=ssh-ed25519',
        '-o', 'UserKnownHostsFile="' + str(config.get('known_hosts') or DATA / 'known_hosts') + '"',
        '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=10',
        '-o', 'ServerAliveCountMax=3', 'root@' + config['host'], operation]


def ssh(config, operation, content=b'', timeout=180):
    return run(ssh_command(config, operation), input=content, stdout=subprocess.PIPE,
               stderr=subprocess.PIPE, timeout=timeout).stdout


def report_progress(percent, stage='send'):
    """For the app, which reads this file while a transfer runs. Off unless it asks."""
    path = os.environ.get('KINDLEPUSH_PROGRESS')
    if not path:
        return
    temp = path + '.tmp'
    with open(temp, 'w') as file:
        json.dump({'percent': percent, 'stage': stage}, file)
    os.replace(temp, path)


def put(config, header, content, timeout):
    """Stream a file to the receiver, reporting how far it has got. Returns its answer."""
    command = ssh_command(config, 'put')
    expired = threading.Event()
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        def expire():
            expired.set()
            process.kill()
        timer = threading.Timer(timeout, expire)
        timer.start()
        try:
            try:
                process.stdin.write(header)
                step, last = 64 * 1024, -1
                for start in range(0, len(content), step):
                    process.stdin.write(content[start:start + step])
                    percent = min((start + step) * 100 // max(1, len(content)), 100)
                    if percent != last:
                        last = percent
                        report_progress(percent)
                process.stdin.close()
            except (BrokenPipeError, ValueError):
                pass  # The connection went away; the exit code and stderr say why.
            output, errors = process.stdout.read(), process.stderr.read()
            code = process.wait()
        finally:
            # Dropping ssh mid-file makes the Kindle discard the part it got.
            timer.cancel()
            if process.poll() is None:
                process.kill()
    if expired.is_set():
        raise subprocess.TimeoutExpired(command, timeout)
    if code:
        raise subprocess.CalledProcessError(code, command, output, errors)
    return output


def send(epub, config):
    """Send one file, or, to a receiver that takes only EPUB, a PDF as page-image EPUB volumes.

    Returns the files that reached the Kindle."""
    version = ssh(config, 'ping').strip()
    if version not in RECEIVER_VERSIONS:
        raise ValueError('接收端未配置好。')
    files = [epub]
    if extension(epub) != '.epub' and version == b'kindle-push-v1':
        import pdfpages
        if extension(epub) != '.pdf' or not pdfpages.renderer():
            raise ValueError('Kindle 上的接收端是旧版，只收 EPUB。发送 ' + extension(epub)[1:].upper()
                             + ' 需要用 USB 连接 Kindle，在「添加 Kindle」里点一次「写入」；EPUB、Markdown、TXT、Word 等不受影响。')
        print('Kindle 接收端是旧版，只收 EPUB：已把 PDF 逐页转成图片版 EPUB 发送。')
        files = pdfpages.build(epub, OUT)
    for path in files:
        send_file(path, config)
    return files


def send_file(path, config):
    content = path.read_bytes()
    # Big files over Kindle Wi-Fi: allow about 256 KB/s on top of the usual limit.
    timeout = 180 + len(content) // (256 * 1024)
    filename = path.name.encode('utf-8') + b'\n'
    response = put(config, filename + str(len(content)).encode() + b'\n', content, timeout)
    if response.strip() != b'OK':
        raise ValueError('Kindle 没有确认接收。')
    report_progress(100, 'verify')
    received = ssh(config, 'get', filename, timeout)
    if hashlib.sha256(received).digest() != hashlib.sha256(content).digest():
        raise ValueError('传输校验未通过，请重试。')
    print('已发送并校验：' + path.name)
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
    if config:
        import devices
        # Pinned to the chosen Kindle's host key: another Kindle at that address is refused.
        chosen = devices.current()
        config['alias'] = chosen['alias'] if chosen else 'kindle-push'
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
