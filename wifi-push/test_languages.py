import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import bookinfo
import languages as lang
import terms
import translation as tr

ENGLISH = ('<p>It was the best of times, it was the worst of times. The house that he had built for his '
           'family was not far from the river, and they walked there with their friends every day.</p>') * 20
CHINESE = '<p>这是一个关于时间、记忆和家庭的故事。他们每天沿着河边散步，谈论过去和未来。偶尔会提到 iPhone。</p>' * 20
JAPANESE = '<p>これは時間と記憶についての物語です。彼らは毎日川沿いを散歩しました。</p>' * 20
FRENCH = '<p>Il était une fois une maison dans la forêt, et les enfants qui sont venus pour jouer avec elle.</p>' * 20


def book(path, body, tag='en'):
    with zipfile.ZipFile(path, 'w') as epub:
        epub.writestr('mimetype', 'application/epub+zip')
        epub.writestr('META-INF/container.xml', '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                      '<rootfiles><rootfile full-path="content.opf"/></rootfiles></container>')
        epub.writestr('content.opf', '<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">'
                      f'<metadata><dc:title>Sample</dc:title><dc:language>{tag}</dc:language></metadata></package>')
        epub.writestr('text/ch1.xhtml', f'<html><head><title>x</title></head><body>{body}</body></html>')
    return path


class LanguageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_text_detection(self):
        self.assertEqual(lang.from_text(ENGLISH), 'en')
        self.assertEqual(lang.from_text(CHINESE), 'zh')
        self.assertEqual(lang.from_text(JAPANESE), 'ja')
        self.assertEqual(lang.from_text(FRENCH), 'fr')
        self.assertEqual(lang.from_text('Chapter 1'), '')

    def test_text_wins_over_a_wrong_tag_and_tag_is_the_fallback(self):
        self.assertEqual(lang.detect(book(self.root / 'a.epub', CHINESE, 'en')), 'zh')
        self.assertEqual(lang.detect(book(self.root / 'b.epub', '<p>1 2 3</p>', 'en-US')), 'en')
        self.assertEqual(lang.detect(book(self.root / 'c.epub', '<p>1</p>', '')), '')
        broken = self.root / 'd.epub'; broken.write_bytes(b'not a zip')
        self.assertEqual(lang.detect(broken), '')

    def test_book_info_reports_language_for_epub_only(self):
        with patch.object(bookinfo, 'COVERS', self.root / 'covers'):
            info = bookinfo.info(book(self.root / 'e.epub', ENGLISH))
            self.assertEqual(info['language'], 'en')
            self.assertGreater(info['textSize'], 1000)
            note = self.root / 'note.md'; note.write_text('# Title\n\nSome English text.')
            self.assertEqual(bookinfo.info(note)['language'], '')

    def test_labels_follow_the_target(self):
        self.assertEqual(lang.pair_label('en', 'zh'), '中英对照')
        self.assertEqual(lang.pair_label('zh', 'en'), '中英对照')
        self.assertEqual(lang.pair_label('en', 'ja'), '英日对照')
        self.assertEqual(lang.pair_label('ja', 'zh'), '中日对照')
        self.assertEqual(lang.pair_label('', 'zh'), '双语对照')
        self.assertEqual(lang.only_label('en'), '英文')
        self.assertEqual(lang.base('zh-Hans-CN'), 'zh')


class TargetLanguageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        config = {'base': 'https://example.com/v1', 'model': 'deepseek-v4-pro', 'service': 'test', 'account': 'test'}
        self.patches = [patch.object(tr, 'DATA', self.root), patch.object(tr, 'JOBS', self.root / 'jobs'),
                        patch.object(tr, 'RUNTIME', self.root / 'runtime'),
                        patch.object(tr.kp, 'OUT', self.root / 'output'),
                        patch.object(tr, 'read_key', return_value='test-only-not-a-real-key'),
                        patch.object(tr, 'settings', return_value=config)]
        for item in self.patches: item.start()

    def tearDown(self):
        for item in reversed(self.patches): item.stop()
        self.temp.cleanup()

    def test_chinese_identities_are_unchanged_and_targets_are_separate(self):
        digest, config = 'd' * 64, tr.settings()
        # 1.13 called a translation alone 'chinese'; its checkpoints must still resume.
        self.assertEqual(tr.job_id(digest, config, False, 'target-only'), tr.job_id(digest, config, False, 'chinese'))
        jobs = {tr.job_id(digest, config, False, mode, goal) for mode in tr.MODES for goal in ('zh', 'en', 'ja')}
        self.assertEqual(len(jobs), 6)
        self.assertEqual(tr.job_id(digest, config, False), tr.job_id(digest, config, False, 'bilingual', 'zh'))

    def test_command_and_prompt_follow_the_target(self):
        args = tr.command(self.root, tr.settings(), False, 'target-only', 'en')
        self.assertEqual(args[args.index('--language') + 1], 'en')
        self.assertIn('--single_translate', args)
        prompt = json.loads(Path(args[args.index('--prompt') + 1]).read_text())
        self.assertIn('English', prompt['system'])
        self.assertNotIn('简体中文', prompt['system'])
        zh = tr.command(self.root, tr.settings(), False)
        self.assertEqual(zh[zh.index('--language') + 1], 'zh-hans')
        self.assertIn('简体中文', json.loads(Path(zh[zh.index('--prompt') + 1]).read_text())['system'])
        ja = tr.command(self.root, {**tr.settings(), 'style': 'literary'}, False, 'bilingual', 'ja')
        self.assertIn('Japanese', json.loads(Path(ja[ja.index('--prompt') + 1]).read_text())['system'])

    def test_unknown_target_is_rejected(self):
        source = book(self.root / 'x.epub', ENGLISH)
        with self.assertRaisesRegex(ValueError, '目标语言'):
            tr.start(source, False, 'bilingual', 'xx')

    def test_output_name_has_the_language_pair_and_polish_is_chinese_only(self):
        for number, (goal, source, mode, expected, polished) in enumerate((('ja', 'en', 'bilingual', '（英日对照）', False),
                                                       ('en', 'zh', 'target-only', '（英文）', False),
                                                       ('zh', 'en', 'bilingual', '（中英对照）', True))):
            job = str(number) * 24
            folder = tr.job_dir(job)
            folder.mkdir(parents=True)
            book(folder / 'book.epub', ENGLISH)
            tr.atomic_json(folder / 'state.json', {'state': 'queued', 'pid': 1})
            tr.atomic_json(folder / 'request.json', {'config': tr.settings(), 'preview': False, 'mode': mode,
                                                     'target': goal, 'source': source, 'title': 'Sample'})
            (folder / 'glossary-auto.txt').write_text('')
            code = "import shutil;shutil.copyfile('book.epub','book_bilingual.epub')"
            with patch.object(tr, 'command', return_value=[sys.executable, '-c', code]), \
                    patch.object(tr.polish, 'epub') as polish:
                tr.worker(job)
            state = json.loads((folder / 'state.json').read_text())
            self.assertEqual(state['state'], 'done', state)
            self.assertIn(expected, Path(state['output']).name)
            self.assertEqual(polish.called, polished)

    def test_glossary_prompt_and_parse_follow_the_target(self):
        items = [{'term': 'Seldon', 'count': 3, 'example': 'Seldon said.'}]
        self.assertIn('Japanese', terms.prompt('T', 'A', items, 'Japanese'))
        self.assertIn('简体中文', terms.prompt('T', 'A', items))
        reply = '{"terms": [{"en": "Seldon", "zh": "セルダン"}]}'
        self.assertEqual(terms.parse(reply, ['Seldon']), [])            # Chinese needs Han characters
        self.assertEqual(terms.parse(reply, ['Seldon'], chinese=False), ['Seldon -> セルダン'])


if __name__ == '__main__':
    unittest.main()
