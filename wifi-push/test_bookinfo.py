import base64
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import bookinfo
import translation as tr

PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6N1sAAAAASUVORK5CYII=')
OPF = '''<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
<metadata><dc:title>钻石年代</dc:title><dc:creator>Neal Stephenson</dc:creator><meta name="cover" content="c"/></metadata>
<manifest><item id="c" href="img/cover.png" media-type="image/png"/></manifest></package>'''


class BookInfoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.patch = patch.object(bookinfo, 'COVERS', self.root / 'covers'); self.patch.start()

    def tearDown(self):
        self.patch.stop(); self.temp.cleanup()

    def test_epub_title_author_and_cover(self):
        book = self.root / 'Diamond Age (Stephenson Neal) (z-library.sk, 1lib.sk, z-lib.sk).epub'
        with zipfile.ZipFile(book, 'w') as z:
            z.writestr('mimetype', 'application/epub+zip')
            z.writestr('META-INF/container.xml', '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>')
            z.writestr('OEBPS/content.opf', OPF); z.writestr('OEBPS/img/cover.png', PNG)
        result = bookinfo.info(book)
        self.assertEqual((result['title'], result['author']), ('钻石年代', 'Neal Stephenson'))
        self.assertEqual(Path(result['cover']).read_bytes(), PNG)

    def test_fallbacks_clean_shadow_library_names(self):
        broken = self.root / 'Diamond Age (Stephenson Neal) (z-library.sk, 1lib.sk, z-lib.sk).epub'
        broken.write_text('not a zip')
        self.assertEqual(bookinfo.info(broken)['title'], 'Diamond Age (Stephenson Neal)')
        note = self.root / 'note.md'; note.write_text('---\ntitle: 慢读\nauthor: 乔木\n---\n# 别的')
        self.assertEqual((bookinfo.info(note)['title'], bookinfo.info(note)['author']), ('慢读', '乔木'))

    def test_remaining_time_text(self):
        self.assertEqual(tr.remaining_seconds('6:10:27'), 22227)
        self.assertIsNone(tr.remaining_seconds('?'))
        self.assertEqual(tr.remaining_text(22227), '还剩约 6.2 小时')
        self.assertEqual(tr.remaining_text(1500), '还剩约 25 分钟')


if __name__ == '__main__':
    unittest.main()
