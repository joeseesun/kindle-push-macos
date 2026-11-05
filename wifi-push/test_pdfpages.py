import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import kindle_push as kp
import pdfpages

PNG = bytes.fromhex('89504e470d0a1a0a0000000d4948445200000001000000010800000000'
                    '3a7e9b550000000a49444154789c63600000000200015e2b5ba10000000049454e44ae426082')


class PdfPagesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.pages = []
        for n in range(1, 8):
            page = self.root / f'p{n:04d}.png'
            page.write_bytes(PNG + b'\0' * 100)
            self.pages.append(page)

    def tearDown(self):
        self.temp.cleanup()

    def test_volumes_respect_the_limit_and_keep_order(self):
        groups = pdfpages.volumes(self.pages, limit=len(PNG) * 3 + 300)
        self.assertEqual([len(g) for g in groups], [3, 3, 1])
        self.assertEqual(sum(groups, []), self.pages)

    def test_epub_is_valid_and_numbered(self):
        path = self.root / 'b.epub'
        pdfpages.write_epub(path, 'Book & <1>', self.pages[3:], 4)
        kp.validate_epub(path)
        with zipfile.ZipFile(path) as book:
            self.assertEqual(book.infolist()[0].filename, 'mimetype')
            self.assertIn('OEBPS/p4.xhtml', book.namelist())
            self.assertIn('Book &amp; &lt;1&gt;', book.read('OEBPS/content.opf').decode())

    def test_build_splits_and_reuses(self):
        pdf = self.root / '书 名.pdf'
        pdf.write_bytes(b'%PDF-1.4')
        out = self.root / 'out'
        with patch.object(pdfpages, 'render', return_value=self.pages), \
             patch.object(pdfpages, 'VOLUME_BYTES', len(PNG) * 4 + 400):
            made = pdfpages.build(pdf, out)
            self.assertEqual([p.name for p in made], ['书 名（图片版 1-2）.epub', '书 名（图片版 2-2）.epub'])
            with patch.object(pdfpages, 'render', side_effect=AssertionError('rendered again')):
                self.assertEqual(pdfpages.build(pdf, out), made)

    def test_old_receiver_gets_pdf_as_epub(self):
        pdf = self.root / 'a.pdf'
        pdf.write_bytes(b'%PDF-1.4')
        volume = self.root / 'a（图片版）.epub'
        sent = []
        with patch.object(kp, 'ssh', return_value=b'kindle-push-v1\n'), \
             patch.object(pdfpages, 'renderer', return_value='/app'), \
             patch.object(pdfpages, 'build', return_value=[volume]), \
             patch.object(kp, 'send_file', side_effect=lambda p, c: sent.append(p)):
            self.assertEqual(kp.send(pdf, {'host': 'x'}), [volume])
        self.assertEqual(sent, [volume])
        with patch.object(kp, 'ssh', return_value=b'kindle-push-v2\n'), \
             patch.object(kp, 'send_file', side_effect=lambda p, c: sent.append(p)):
            self.assertEqual(kp.send(pdf, {'host': 'x'}), [pdf])


if __name__ == '__main__':
    unittest.main()
