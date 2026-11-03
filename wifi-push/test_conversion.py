import base64
import re
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import kindle_push as kp
from markdown_support import prepare_markdown


class ConversionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / '.obsidian').mkdir()
        (self.root / '附件').mkdir()
        self.patch = patch.object(kp, 'OUT', self.root / 'output')
        self.patch.start()
        self.note = self.root / '原文件名.md'

    def tearDown(self):
        self.patch.stop()
        self.temp.cleanup()

    def image(self, path):
        path.write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6N1sAAAAASUVORK5CYII='))

    def test_metadata_tables_tasks_footnotes_images_and_styles(self):
        self.image(self.root / '附件/图 片.png')
        self.note.write_text('''---
title: 我的阅读文章
author: 示例作者
lang: zh-CN
---
# 开始

这是一段**粗体**、*斜体*和~~删除线~~。[[其他笔记|链接文字]]

> [!tip] 阅读提示
> 这段需要保留。

| 名称 | 内容 |
| --- | --- |
| 中文 | 长一点的内容 |

- [x] 完成
- [ ] 待办

![[图 片.png|300]]

引用脚注[^1]。

[^1]: 脚注正文。
''')
        output = kp.convert(self.note)
        with zipfile.ZipFile(output) as archive:
            names = archive.namelist()
            xhtml = '\n'.join(archive.read(n).decode() for n in names if n.endswith('.xhtml'))
            opf = '\n'.join(archive.read(n).decode() for n in names if n.endswith('.opf'))
            css = '\n'.join(archive.read(n).decode() for n in names if n.endswith('.css'))
            self.assertIn('我的阅读文章', opf)
            self.assertIn('示例作者', opf)
            self.assertIn('<table', xhtml)
            self.assertIn('<strong>粗体</strong>', xhtml)
            self.assertIn('脚注正文', xhtml)
            self.assertIn('阅读提示', xhtml)
            self.assertNotIn('[!tip]', xhtml)
            self.assertIn('链接文字', xhtml)
            self.assertTrue(any(n.endswith('.png') for n in names))
            self.assertIn('pre-wrap', css)
            self.assertIn('max-width: 100%', css)
            self.assertIsNone(archive.testzip())

    def test_multi_backtick_code_is_preserved(self):
        text = '# 代码\n\n````md\n```\n[[代码链接]]\n> [!tip] 不要改\n```\n````\n\n``[[行内]] ` test``\n\n[[普通|显示]]\n'
        self.note.write_text(text)
        converted, _ = prepare_markdown(self.note)
        self.assertIn('[[代码链接]]', converted)
        self.assertIn('> [!tip] 不要改', converted)
        self.assertIn('``[[行内]] ` test``', converted)
        self.assertTrue(converted.endswith('显示\n'))

    def test_nested_note_resolves_own_images_without_touching_code(self):
        nested = self.root / '子目录'; nested.mkdir()
        self.image(nested / '图.png')
        (nested / '被嵌入.md').write_text('---\ntitle: 子标题\n---\n## 内文\n\n![图](图.png)\n\n```md\n> [!tip] 原样保留\n```\n')
        self.note.write_text('# 主文章\n\n![[子目录/被嵌入]]\n')
        output = kp.convert(self.note)
        with zipfile.ZipFile(output) as archive:
            html = '\n'.join(archive.read(n).decode() for n in archive.namelist() if n.endswith('.xhtml'))
            self.assertIn('内文', html)
            self.assertIn('[!tip]', html)
            self.assertTrue(any(n.endswith('.png') for n in archive.namelist()))

    def test_cycle_is_reported(self):
        self.note.write_text('![[原文件名]]')
        with self.assertRaisesRegex(ValueError, '循环'):
            kp.convert(self.note)

    def test_ambiguous_images_are_reported(self):
        for folder in ['one', 'two']:
            (self.root / folder).mkdir(); self.image(self.root / folder / 'same.png')
        self.note.write_text('![[same.png]]')
        with self.assertRaisesRegex(ValueError, '重名'):
            kp.convert(self.note)

    def test_missing_image_does_not_replace_successful_output(self):
        self.note.write_text('# 成功\n\n原来的内容。')
        output = kp.convert(self.note); original = output.read_bytes()
        self.note.write_text('# 错误\n\n![图](missing.png)')
        with self.assertRaisesRegex(ValueError, '转换需处理'):
            kp.convert(self.note)
        self.assertEqual(output.read_bytes(), original)

    def test_fake_epub_is_rejected(self):
        fake = self.root / 'fake.epub'; fake.write_text('not a zip')
        with self.assertRaisesRegex(ValueError, '有效'):
            kp.convert(fake)

    def epub_text(self, path):
        with zipfile.ZipFile(path) as book:
            return ''.join(book.read(n).decode() for n in book.namelist() if n.endswith('.xhtml'))

    def test_gb18030_text_becomes_chaptered_epub(self):
        novel = self.root / '小说.txt'
        novel.write_bytes('第一章 开端\n\n\u3000\u3000他推开门。\n第二章 远行\n路很长。'.encode('gb18030'))
        output = kp.convert(novel)
        self.assertEqual(output.suffix, '.epub')
        text = self.epub_text(output)
        self.assertIn('第一章 开端', text); self.assertIn('他推开门。', text)
        self.assertRegex(text, r'<h2[^>]*>第二章 远行</h2>')

    def test_docx_and_html_convert_to_epub(self):
        draft = self.root / 'draft.md'; draft.write_text('# 报告\n\nWord 正文。')
        docx = self.root / '报告.docx'
        kp.run([kp.PANDOC, str(draft), '-o', str(docx)])
        self.assertIn('Word 正文。', self.epub_text(kp.convert(docx)))
        page = self.root / '网页.html'; page.write_text('<h1>标题</h1><p>网页正文 &amp; 符号</p>')
        self.assertIn('网页正文 &amp; 符号', self.epub_text(kp.convert(page)))

    def test_native_formats_are_validated_and_kept(self):
        pdf = self.root / '论文.pdf'; pdf.write_bytes(b'%PDF-1.7\n%%EOF')
        output = kp.convert(pdf)
        self.assertEqual(output.suffix, '.pdf'); self.assertEqual(output.read_bytes(), pdf.read_bytes())
        fake = self.root / 'fake.pdf'; fake.write_text('hello')
        with self.assertRaisesRegex(ValueError, 'PDF'):
            kp.convert(fake)

    def test_zipped_and_comic_formats_keep_their_extension(self):
        book = self.root / '小说.fb2.zip'
        with zipfile.ZipFile(book, 'w') as archive: archive.writestr('a.fb2', '<FictionBook/>')
        output = kp.convert(book)
        self.assertEqual(output.name, '小说.fb2.zip')
        (self.root / 'bad.cbz').write_text('x')
        with self.assertRaisesRegex(ValueError, '压缩包'):
            kp.convert(self.root / 'bad.cbz')

    def test_output_names_are_clean_and_do_not_collide(self):
        first = self.root / 'a' / 'Diamond_Age (z-library.sk, 1lib.sk, z-lib.sk).pdf'
        second = self.root / 'b' / 'Diamond Age.pdf'
        for book in (first, second):
            book.parent.mkdir(); book.write_bytes(b'%PDF-1.7\n%%EOF')
        self.assertEqual(kp.convert(first).name, 'Diamond Age.pdf')
        self.assertEqual(kp.convert(second).name, 'Diamond Age 2.pdf')
        self.assertEqual(kp.convert(first).name, 'Diamond Age.pdf')  # resending replaces its own file

    def test_receiver_and_converter_agree_on_formats(self):
        receiver = Path(kp.__file__).with_name('kindle-receive.sh').read_text()
        accepted = set(re.findall(r'\*(\.[a-z0-9.]+)', receiver))
        self.assertEqual(accepted - {'.azw3'}, (kp.NATIVE | {'.epub'}) - {'.azw3'})

    def mobi(self, path, encryption):
        header = bytearray(96)
        header[60:68] = b'BOOKMOBI'; header[78:82] = (96).to_bytes(4, 'big')
        record = bytearray(16); record[12:14] = encryption.to_bytes(2, 'big')
        path.write_bytes(bytes(header + record))

    def test_drm_mobi_is_rejected(self):
        self.mobi(self.root / 'free.azw3', 0)
        self.assertEqual(kp.convert(self.root / 'free.azw3').suffix, '.azw')
        self.mobi(self.root / 'locked.mobi', 2)
        with self.assertRaisesRegex(ValueError, 'DRM'):
            kp.convert(self.root / 'locked.mobi')

    def test_old_receiver_refuses_native_formats_with_guidance(self):
        pdf = kp.OUT / 'a.pdf'; kp.OUT.mkdir(parents=True, exist_ok=True); pdf.write_bytes(b'%PDF')
        with patch.object(kp, 'ssh', return_value=b'kindle-push-v1\n'):
            with self.assertRaisesRegex(ValueError, 'USB'):
                kp.send(pdf, {'host': '192.168.1.2'})

    def test_mermaid_is_preserved_and_warned(self):
        self.note.write_text('```mermaid\ngraph LR\nA-->B\n```')
        content, warnings = prepare_markdown(self.note)
        self.assertIn('A-->B', content)
        self.assertTrue(warnings)


if __name__ == '__main__':
    unittest.main()
