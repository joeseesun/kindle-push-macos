"""Title, author and cover for the article list. Reads only the chosen file; covers are cached on this Mac."""
import hashlib
import posixpath
import re
import zipfile
from pathlib import Path
from xml.etree import ElementTree

import kindle_push as kp
import languages
import names

COVERS = kp.DATA / 'covers'
NS = {'opf': 'http://www.idpf.org/2007/opf', 'dc': 'http://purl.org/dc/elements/1.1/',
      'c': 'urn:oasis:names:tc:opendocument:xmlns:container'}
IMAGE = {'.jpg', '.jpeg', '.png', '.gif', '.webp'}
def cache_path(source, suffix):
    stat = source.stat()
    key = hashlib.sha1(f'{source}|{stat.st_mtime_ns}|{stat.st_size}'.encode()).hexdigest()[:20]
    return COVERS / (key + suffix)


def epub_info(source):
    with zipfile.ZipFile(source) as book:
        container = ElementTree.fromstring(book.read('META-INF/container.xml'))
        rootfile = container.find('.//c:rootfile', NS)
        opf_path = rootfile.get('full-path')
        opf = ElementTree.fromstring(book.read(opf_path))
        title = (opf.findtext('.//dc:title', '', NS) or '').strip()
        author = (opf.findtext('.//dc:creator', '', NS) or '').strip()
        items = {i.get('id'): i for i in opf.iterfind('.//opf:manifest/opf:item', NS)}
        cover = next((i for i in items.values() if 'cover-image' in (i.get('properties') or '').split()), None)
        if cover is None:
            meta = opf.find(".//opf:metadata/opf:meta[@name='cover']", NS)
            if meta is not None:
                # Often the item id; in hand-made books sometimes the image's file name instead.
                name = meta.get('content') or ''
                cover = items.get(name) or next((i for i in items.values()
                                                 if posixpath.basename(i.get('href', '')) == name), None)
        if cover is None:
            cover = guide_cover(book, opf, opf_path, items)
        if cover is None:
            cover = next((i for i in items.values() if (i.get('media-type') or '').startswith('image/')
                          and 'cover' in (i.get('id', '') + i.get('href', '')).lower()), None)
        cover_file = None
        if cover is not None and (cover.get('media-type') or '').startswith('image/'):
            href = posixpath.normpath(posixpath.join(posixpath.dirname(opf_path), cover.get('href')))
            suffix = Path(href).suffix.lower()
            if suffix in IMAGE:
                target = cache_path(source, suffix)
                if not target.exists():
                    data = book.read(href)
                    if len(data) <= 8 * 1024 * 1024:
                        COVERS.mkdir(parents=True, exist_ok=True, mode=0o700)
                        target.write_bytes(data)
                cover_file = str(target) if target.exists() else None
        # Size of the text documents, for a rough translation time.
        text_size = sum(i.file_size for i in book.infolist() if i.filename.lower().endswith(('.xhtml', '.html', '.htm')))
    return {'title': title, 'author': author, 'cover': cover_file, 'textSize': text_size}


def guide_cover(book, opf, opf_path, items):
    """The first image on the page the guide marks as the cover."""
    reference = opf.find(".//opf:guide/opf:reference[@type='cover']", NS)
    if reference is None:
        return None
    page = posixpath.normpath(posixpath.join(posixpath.dirname(opf_path), reference.get('href', '').split('#')[0]))
    try:
        html = book.read(page).decode('utf-8', 'replace')
    except KeyError:
        return None
    found = re.search(r'<(?:img[^>]+src|image[^>]+href)\s*=\s*["\']([^"\']+)', html, re.I)
    if not found:
        return None
    target = posixpath.normpath(posixpath.join(posixpath.dirname(page), found.group(1)))
    base = posixpath.dirname(opf_path)
    return next((i for i in items.values()
                 if posixpath.normpath(posixpath.join(base, i.get('href', ''))) == target), None)


def markdown_info(source):
    text = source.read_text(encoding='utf-8', errors='replace')[:4000]
    front = re.match(r'---\n(.*?)\n---', text, re.S)
    fields = dict(re.findall(r'^(title|author):\s*["\']?(.+?)["\']?\s*$', front.group(1), re.M)) if front else {}
    heading = re.search(r'^#\s+(.+)$', text, re.M)
    return {'title': fields.get('title') or (heading.group(1).strip() if heading else ''),
            'author': fields.get('author', ''), 'cover': None}


def info(path):
    source = Path(path).expanduser().resolve(strict=True)
    suffix = kp.extension(source)
    result = {'title': '', 'author': '', 'cover': None}
    try:
        if suffix == '.epub':
            result = epub_info(source)
        elif suffix in kp.MARKDOWN:
            result = markdown_info(source)
        elif suffix in IMAGE:
            result['cover'] = str(source)
    except (zipfile.BadZipFile, KeyError, ElementTree.ParseError, OSError, AttributeError, TypeError):
        pass  # Fall back to the cleaned file name; a broken book is reported when it is sent.
    stem = source.name[:-len(suffix)] if source.name.lower().endswith(suffix) else source.stem
    result['title'] = result['title'] or names.tidy(stem, smart=False)
    # Translation handles EPUB only, so only an EPUB needs its language; '' means unknown.
    result['language'] = languages.detect(source) if suffix == '.epub' else ''
    return {'ok': True, **result}
