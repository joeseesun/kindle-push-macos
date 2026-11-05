import tempfile
import unittest
import zipfile
from pathlib import Path

import chunks
import polish

OPF = '''<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf"><manifest>
<item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>
<item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/>
</manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>'''


def page(paragraphs):
    body = ''.join(f'<p>Paragraph {i} {"word " * 60}</p>\n' for i in range(paragraphs))
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title>'
            f'<style>p{{a:b}}</style></head>\n<body><section id="s1" class="c">\n<h1>Title</h1>\n{body}<hr/>\n<br>\n</section></body></html>')


def book(path, pages):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('mimetype', 'application/epub+zip')
        z.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>')
        z.writestr('OEBPS/content.opf', OPF)
        for name, text in pages.items():
            z.writestr('OEBPS/text/' + name, text)


class ChunkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.long, self.short = page(200), page(3)
        book(self.root / 'b.epub', {'c1.xhtml': self.long, 'c2.xhtml': self.short})

    def tearDown(self):
        self.temp.cleanup()

    def test_split_cuts_long_chapter_only_and_join_restores_it(self):
        plan = chunks.split(self.root / 'b.epub', self.root / 's.epub', 16)
        self.assertEqual([c['file'] for c in plan['chapters']], ['OEBPS/text/c1.xhtml'])
        parts = plan['chapters'][0]['parts']
        self.assertGreater(len(parts), 2)
        with zipfile.ZipFile(self.root / 's.epub') as z:
            opf = z.read('OEBPS/content.opf').decode()
            self.assertIn('idref="c1__kp2"', opf); self.assertIn('href="text/c1__kp2.xhtml"', opf)
            self.assertLess(opf.index('idref="c1__kp2"'), opf.index('idref="c2"'))
            second = z.read(parts[1]).decode()
            self.assertIn('<section class="c">', second)   # wrapper reopened without its id
            self.assertIn('<style>', second)
            self.assertEqual(z.infolist()[0].filename, 'mimetype')
        chunks.join(self.root / 's.epub', self.root / 'j.epub', plan)
        with zipfile.ZipFile(self.root / 'j.epub') as z:
            self.assertEqual(z.read('OEBPS/text/c1.xhtml').decode(), self.long)
            self.assertEqual(z.read('OEBPS/content.opf').decode(), OPF)
            self.assertFalse([n for n in z.namelist() if '__kp' in n])

    def test_join_takes_engine_output_with_added_translations(self):
        plan = chunks.split(self.root / 'b.epub', self.root / 's.epub', 16)
        translated = {}
        with zipfile.ZipFile(self.root / 's.epub') as z:
            for name in z.namelist():
                data = z.read(name).decode()
                translated[name] = data.replace('</p>', '</p><p>译文</p>') if name.endswith('.xhtml') else data
        with zipfile.ZipFile(self.root / 't.epub', 'w') as z:
            for name, data in translated.items(): z.writestr(name, data)
        chunks.join(self.root / 't.epub', self.root / 'j.epub', plan)
        with zipfile.ZipFile(self.root / 'j.epub') as z:
            text = z.read('OEBPS/text/c1.xhtml').decode()
        self.assertEqual(text.count('<p>译文</p>'), 200)
        self.assertEqual(text.count('<section'), 1); self.assertEqual(text.count('</body>'), 1)

    def test_join_finds_parts_the_engine_moved_into_its_own_folder(self):
        # content.opf at the top of the zip: the engine writes everything under EPUB/ (Snow Crash).
        opf = OPF.replace('text/', '')
        with zipfile.ZipFile(self.root / 'top.epub', 'w') as z:
            z.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>')
            z.writestr('content.opf', opf)
            z.writestr('c1.xhtml', self.long)
        plan = chunks.split(self.root / 'top.epub', self.root / 's.epub', 16)
        self.assertTrue(plan and plan['chapters'][0]['parts'][1].startswith('c1__kp'))
        with zipfile.ZipFile(self.root / 's.epub') as z, zipfile.ZipFile(self.root / 't.epub', 'w') as out:
            out.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="EPUB/content.opf"/></rootfiles></container>')
            for name in z.namelist():
                if name != 'META-INF/container.xml':
                    out.writestr('EPUB/' + name, z.read(name))
        chunks.join(self.root / 't.epub', self.root / 'j.epub', plan)
        with zipfile.ZipFile(self.root / 'j.epub') as z:
            self.assertEqual(z.read('EPUB/c1.xhtml').decode(), self.long)
            self.assertFalse([n for n in z.namelist() if '__kp' in n])
            self.assertNotIn('__kp', z.read('EPUB/content.opf').decode())
        # Plans saved before `base` existed still work; a part truly missing is said plainly.
        chunks.join(self.root / 't.epub', self.root / 'j2.epub', {k: v for k, v in plan.items() if k != 'base'})
        broken = dict(plan, chapters=[dict(plan['chapters'][0], parts=plan['chapters'][0]['parts'] + ['gone.xhtml'])])
        with self.assertRaisesRegex(ValueError, '重试'):
            chunks.join(self.root / 't.epub', self.root / 'j3.epub', broken)

    def test_short_or_odd_books_are_left_alone(self):
        book(self.root / 'small.epub', {'c1.xhtml': self.short, 'c2.xhtml': self.short})
        self.assertIsNone(chunks.split(self.root / 'small.epub', self.root / 'x.epub', 16))
        self.assertIsNone(chunks.cut('<html><body><p>' + 'word ' * 9000 + '</p></body></html>', 4000))


class PolishTests(unittest.TestCase):
    def test_chinese_punctuation_only_after_chinese(self):
        self.assertEqual(polish.text('他说,我们走吧.然后呢?'), '他说，我们走吧。然后呢？')
        self.assertEqual(polish.text('他说"你好"(真的)'), '他说“你好”（真的）')
        self.assertEqual(polish.text('版本 3.5, U.S. 用户'), '版本 3.5, U.S. 用户')
        self.assertEqual(polish.text('Plain English, stays.'), 'Plain English, stays.')
        self.assertEqual(polish.text('等等...'), '等等……')

    def test_markup_leaves_tags_and_styles(self):
        doc = '<html><head><title>a,b</title><style>p,q{x:y}</style></head><body><p class="a,b">好,的.</p><p>Hi, there.</p></body></html>'
        self.assertEqual(polish.markup(doc), doc.replace('好,的.', '好，的。'))


if __name__ == '__main__':
    unittest.main()
