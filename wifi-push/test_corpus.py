"""EPUBs laid out the ways real ones are, because shops and tools disagree on almost everything.

Each past bug here came from one of these shapes (Snow Crash: an OPF at the top of the zip). The
books are built in the test, so no copyrighted text sits in the repository.
"""
import posixpath
import re
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path
from urllib.parse import quote

import bookinfo
import chunks
import kindle_push as kp
import languages

ENGLISH = 'The old keeper climbed the stairs with all of his tools and they were not afraid of the storm. '
GERMAN = 'Der alte Mann und die Frau waren nicht in dem Haus, aber das Kind ist mit einem Hund auf der Straße. '
CHINESE = '老人每天晚上都沿着楼梯走上灯塔，他们并不害怕北方来的风暴，这是一个很长的故事。'
PNG = b'\x89PNG\r\n\x1a\n' + b'\0' * 32


def page(text, paragraphs, wrap='{}', ext_entities=False):
    amp = ' &amp; &#8212; ' if ext_entities else ' '
    inner = ''.join(f'<p>{i}{amp}{text * 6}</p>\n' for i in range(paragraphs))
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title>'
            '<style>p{margin:0}</style></head>\n<body>' + wrap.format('\n<h1>Chapter</h1>\n' + inner) + '</body></html>')


def build(path, opf_name, files, title='The Lighthouse', author='A. Keeper', tag='en', cover='meta', quote_style='"',
          extra_meta='', href=quote):
    """A book with `files` {name relative to the OPF: text} in spine order."""
    base = posixpath.dirname(opf_name)
    q = quote_style
    items, refs = [], []
    for number, name in enumerate(files):
        items.append(f'<item id="c{number}" href="{href(name)}" media-type="application/xhtml+xml"/>')
        refs.append(f'<itemref idref="c{number}"/>')
    items.append('<item id="img" href="images/front.png" media-type="image/png"'
                 + (' properties="cover-image"' if cover == 'property' else '') + '/>')
    meta = '<meta name="cover" content="img"/>' if cover == 'meta' else '<meta name="cover" content="front.png"/>' if cover == 'filename' else ''
    opf = (f'<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
           f'<dc:title>{title}</dc:title><dc:creator>{author}</dc:creator><dc:language>{tag}</dc:language>{meta}{extra_meta}</metadata>'
           f'<manifest>{"".join(items)}</manifest><spine>{"".join(refs)}</spine></package>')
    with zipfile.ZipFile(path, 'w') as book:
        book.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        book.writestr('META-INF/container.xml',
                      f'<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
                      f'<rootfile full-path={q}{opf_name}{q} media-type="application/oebps-package+xml"/></rootfiles></container>')
        book.writestr(opf_name, opf)
        book.writestr(posixpath.join(base, 'images/front.png'), PNG)
        for name, text in files.items():
            book.writestr(posixpath.join(base, name), text)


def engine(source, target):
    """What bilingual_book_maker does to the zip: adds a translation after each paragraph, and moves
    a book with its OPF at the top of the zip under EPUB/."""
    with zipfile.ZipFile(source) as book, zipfile.ZipFile(target, 'w') as out:
        moved = '/' not in chunks.opf_path(book)
        for info in book.infolist():
            data = book.read(info.filename)
            name = info.filename
            if name.endswith(('.xhtml', '.html')):
                data = re.sub(r'(<p>.*?</p>)', r'\1<p>译</p>', data.decode('utf-8')).encode('utf-8')
            if moved and name not in {'mimetype'} and not name.startswith('META-INF'):
                name = 'EPUB/' + name
            if name == 'META-INF/container.xml' and moved:
                data = re.sub(rb'full-path="', b'full-path="EPUB/', data)
            out.writestr(name, data)


LONG = page(ENGLISH, 400)
SHORT = page(ENGLISH, 3)
SHAPES = {
    'oebps': ('OEBPS/content.opf', {'Text/a.xhtml': LONG, 'Text/b.xhtml': SHORT}, {}),
    'top level opf': ('content.opf', {'a.xhtml': LONG, 'b.xhtml': SHORT}, {}),
    'ops and epub3 cover': ('OPS/package.opf', {'a.xhtml': LONG}, {'cover': 'property'}),
    'cover named by file': ('OEBPS/book.opf', {'a.xhtml': LONG}, {'cover': 'filename'}),
    'spaces in names': ('OEBPS/content.opf', {'Text/chapter 1.xhtml': LONG}, {}),
    'chinese names': ('OEBPS/content.opf', {'正文/第一章.xhtml': LONG}, {}),
    'deep nesting': ('OEBPS/content.opf', {'a.xhtml': page(ENGLISH, 400, '<div id="w"><section>{}</section></div>')}, {}),
    'entities': ('OEBPS/content.opf', {'a.xhtml': page(ENGLISH, 400, ext_entities=True)}, {}),
    'html extension': ('OEBPS/content.opf', {'a.html': LONG}, {}),
    'single quotes in container': ('OEBPS/content.opf', {'a.xhtml': LONG}, {'quote_style': "'"}),
}


class Corpus(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        self.addCleanup(self.folder.cleanup)
        patcher = unittest.mock.patch.object(bookinfo, 'COVERS', self.root / 'covers')
        patcher.start()
        self.addCleanup(patcher.stop)

    def each(self):
        for name, (opf, files, options) in SHAPES.items():
            path = self.root / (re.sub(r'\W', '_', name) + '.epub')
            build(path, opf, files, **options)
            yield name, path

    def test_info(self):
        for name, path in self.each():
            with self.subTest(name):
                kp.validate_epub(path)
                info = bookinfo.info(path)
                self.assertEqual(info['title'], 'The Lighthouse')
                self.assertEqual(info['author'], 'A. Keeper')
                self.assertEqual(info['language'], 'en')
                self.assertTrue(info['translatable'])
                self.assertGreater(info['textSize'], 1000)
                self.assertTrue(info['cover'], 'no cover found')
                self.assertEqual(Path(info['cover']).read_bytes(), PNG)

    def test_split_translate_join(self):
        """Every paragraph survives, once and in order, and the parts leave no trace."""
        for name, path in self.each():
            with self.subTest(name):
                work = self.root / re.sub(r'\W', '_', name)
                work.mkdir()
                plan = chunks.split(path, work / 'split.epub', 16)
                raw = work / 'raw.epub'
                engine(work / 'split.epub' if plan else path, raw)
                if not plan:
                    # A shape this code declines to cut is still fine: it just runs as one chapter.
                    continue
                self.assertTrue(plan['chapters'], name)
                chunks.join(raw, work / 'done.epub', plan)
                with zipfile.ZipFile(work / 'done.epub') as book:
                    self.assertEqual(book.testzip(), None)
                    self.assertFalse([n for n in book.namelist() if chunks.SUFFIX in n], name)
                    opf = book.read(chunks.opf_path(book)).decode()
                    self.assertNotIn(chunks.SUFFIX, opf)
                    target = chunks.opf_path(book)
                    entry = plan['chapters'][0]
                    relative = entry['file'][len(plan['base']) + 1:] if plan['base'] else entry['file']
                    text = book.read(posixpath.join(posixpath.dirname(target), relative)).decode()
                numbers = [int(n) for n in re.findall(r'<p>(\d+)\b', text)]
                self.assertEqual(numbers, list(range(400)), name)
                self.assertEqual(text.count('<p>译</p>'), 400, name)
                self.assertEqual(text.count('<body'), 1, name)

    def test_top_level_opf_is_really_moved_by_the_fake_engine(self):
        path = self.root / 'top.epub'
        build(path, 'content.opf', {'a.xhtml': LONG})
        chunks.split(path, self.root / 's.epub', 16)
        engine(self.root / 's.epub', self.root / 'r.epub')
        with zipfile.ZipFile(self.root / 'r.epub') as book:
            self.assertEqual(chunks.opf_path(book), 'EPUB/content.opf')

    def test_wrong_language_tags_lose_to_the_text(self):
        for text, tag, want in [(CHINESE, 'en', 'zh'), (ENGLISH, 'zh', 'en'), (GERMAN, 'en', 'de')]:
            with self.subTest(want):
                path = self.root / f'{want}.epub'
                build(path, 'OEBPS/content.opf', {'a.xhtml': page(text, 30)}, tag=tag)
                self.assertEqual(languages.detect(path), want)

    def test_broken_books_are_refused_clearly(self):
        bad = self.root / 'bad.epub'
        bad.write_bytes(b'not a zip')
        with self.assertRaises(ValueError):
            kp.validate_epub(bad)
        with zipfile.ZipFile(self.root / 'empty.epub', 'w') as book:
            book.writestr('mimetype', 'application/epub+zip')
        with self.assertRaises(ValueError):
            kp.validate_epub(self.root / 'empty.epub')

    @unittest.skipUnless(shutil.which('pandoc'), 'needs pandoc')
    def test_documents_become_translatable_epubs(self):
        for name, text in [('a.txt', 'Chapter 1\n\n' + ENGLISH * 3), ('b.md', '# One\n\n' + ENGLISH * 3),
                           ('c.html', f'<html><body><h1>One</h1><p>{ENGLISH * 3}</p></body></html>')]:
            with self.subTest(name):
                source = self.root / name
                source.write_text(text)
                out = self.root / (name + '.epub')
                out.write_bytes(kp.epub_for_translation(source))
                kp.validate_epub(out)
                self.assertEqual(languages.detect(out), 'en')


import unittest.mock

if __name__ == '__main__':
    unittest.main()
