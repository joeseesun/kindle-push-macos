"""Title, author and cover for the article list. Reads only the chosen file; covers are cached on this Mac."""
import hashlib
import posixpath
import re
import zipfile
from pathlib import Path
from xml.etree import ElementTree

import kindle_push as kp

COVERS = kp.DATA / 'covers'
NS = {'opf': 'http://www.idpf.org/2007/opf', 'dc': 'http://purl.org/dc/elements/1.1/',
      'c': 'urn:oasis:names:tc:opendocument:xmlns:container'}
IMAGE = {'.jpg', '.jpeg', '.png', '.gif', '.webp'}
# Shadow-library suffixes such as "(z-library.sk, 1lib.sk, z-lib.sk)".
NOISE = re.compile(r'\s*\((?:[^()]*\b(?:z-?lib|1lib|libgen|annas?-archive)[^()]*)\)\s*', re.I)


def clean_name(stem):
    return NOISE.sub(' ', stem).strip() or stem


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
            cover = items.get(meta.get('content')) if meta is not None else None
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
    return {'title': title, 'author': author, 'cover': cover_file}


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
    result['title'] = result['title'] or clean_name(stem)
    return {'ok': True, **result}
