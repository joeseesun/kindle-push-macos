"""A PDF as page-image EPUBs, for a Kindle whose receiver predates PDF support and takes only EPUB.

The app renders each page with macOS PDFKit (`KindlePush --render-pdf`, in the app binary) as a
16-gray PNG sized for the screen; this module wraps the pages into EPUBs that KOReader shows one
page per screen. A book larger than the receiver accepts is split into volumes. Text is not
selectable in this form; upgrading the receiver once over USB sends the PDF itself instead.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid
import zipfile
from xml.sax.saxutils import escape

VOLUME_BYTES = 90 * 1024 * 1024     # the receiver takes at most 100 MB per file
SCREEN = ('1072', '1448')            # Paperwhite and Oasis class screens


def renderer():
    app = os.environ.get('KINDLEPUSH_APP', '')
    return app if app and os.access(app, os.X_OK) else None


def render(pdf, folder):
    app = renderer()
    if not app:
        raise ValueError('这台 Mac 上的应用组件不完整，无法转换 PDF。')
    result = subprocess.run([app, '--render-pdf', str(pdf), str(folder), *SCREEN],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3600)
    lines = result.stdout.decode('utf-8', 'replace').strip().splitlines()
    reply = json.loads(lines[-1]) if lines else {}
    if result.returncode or not reply.get('ok'):
        raise ValueError(reply.get('message') or '无法把这个 PDF 转成 Kindle 能收的格式。')
    return sorted(Path(folder).glob('p*.png'))


def volumes(pages, limit=None):
    """Consecutive runs of pages, each under `limit` bytes of images."""
    limit = limit or VOLUME_BYTES
    total = sum(page.stat().st_size for page in pages)
    # Even volumes (two of 63 MB, not 90 + 36): each transfer is shorter and no volume is a stub.
    count = max(1, -(-total // limit))
    limit = min(limit, -(-total // count) + max((page.stat().st_size for page in pages), default=0))
    groups, current, size = [], [], 0
    for page in pages:
        length = page.stat().st_size
        if current and size + length > limit:
            groups.append(current)
            current, size = [], 0
        current.append(page)
        size += length
    if current:
        groups.append(current)
    return groups


def write_epub(path, title, pages, first_number):
    book_id = 'urn:uuid:' + str(uuid.uuid4())
    items, spine, nav = [], [], []
    for offset, page in enumerate(pages):
        n = first_number + offset
        items.append(f'<item id="i{n}" href="images/{page.name}" media-type="image/png"'
                     + (' properties="cover-image"' if offset == 0 else '') + '/>')
        items.append(f'<item id="p{n}" href="p{n}.xhtml" media-type="application/xhtml+xml"/>')
        spine.append(f'<itemref idref="p{n}"/>')
        if offset == 0 or n % 50 == 0:
            nav.append(f'<li><a href="p{n}.xhtml">第 {n} 页</a></li>')
    opf = ('<?xml version="1.0" encoding="UTF-8"?>\n'
           '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
           '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
           f'<dc:identifier id="id">{book_id}</dc:identifier><dc:title>{escape(title)}</dc:title>'
           '<dc:language>zh</dc:language><meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>'
           '</metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
           '<item id="css" href="page.css" media-type="text/css"/>' + ''.join(items) + '</manifest>'
           '<spine>' + ''.join(spine) + '</spine></package>')
    css = ('@page{margin:0}html,body{margin:0;padding:0;height:100%}'
           'div{text-align:center;height:100%;page-break-after:always}'
           'img{max-width:100%;max-height:100%;height:auto}')
    with zipfile.ZipFile(path, 'w') as book:
        book.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        book.writestr('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" '
                      'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
                      '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
                      '</rootfiles></container>')
        book.writestr('OEBPS/content.opf', opf, compress_type=zipfile.ZIP_DEFLATED)
        book.writestr('OEBPS/page.css', css, compress_type=zipfile.ZIP_DEFLATED)
        book.writestr('OEBPS/nav.xhtml', '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" '
                      'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body>'
                      '<nav epub:type="toc"><ol>' + ''.join(nav) + '</ol></nav></body></html>',
                      compress_type=zipfile.ZIP_DEFLATED)
        for offset, page in enumerate(pages):
            n = first_number + offset
            book.writestr(f'OEBPS/p{n}.xhtml', '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml">'
                          f'<head><title>{n}</title><link rel="stylesheet" href="page.css"/></head>'
                          f'<body><div><img src="images/{page.name}" alt=""/></div></body></html>',
                          compress_type=zipfile.ZIP_DEFLATED)
            # PNG is already compressed; storing it keeps packing fast.
            book.write(page, f'OEBPS/images/{page.name}', compress_type=zipfile.ZIP_STORED)


def build(pdf, out):
    """The EPUB volumes for `pdf` in `out`, made once and reused while the PDF is unchanged."""
    pdf = Path(pdf)
    stem = pdf.stem[:80]
    out.mkdir(parents=True, exist_ok=True)
    existing = sorted(out.glob(f'{glob_escape(stem)}（图片版*.epub'))
    if existing and all(p.stat().st_mtime >= pdf.stat().st_mtime for p in existing):
        return existing
    with tempfile.TemporaryDirectory() as temp:
        groups = volumes(render(pdf, temp))
        for old in existing:
            old.unlink()
        made, number = [], 1
        for index, group in enumerate(groups, 1):
            label = '（图片版）' if len(groups) == 1 else f'（图片版 {index}-{len(groups)}）'
            path = out / f'{stem}{label}.epub'
            write_epub(path, stem + ('' if len(groups) == 1 else f' {index}/{len(groups)}'), group, number)
            number += len(group)
            made.append(path)
    return made


def glob_escape(text):
    return ''.join(f'[{c}]' if c in '*?[]' else c for c in text)
