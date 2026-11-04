import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import translation as tr


def epub(path):
    with zipfile.ZipFile(path, 'w') as book:
        book.writestr('mimetype', 'application/epub+zip')
        book.writestr('META-INF/container.xml', '<container/>')


class TranslationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.patches = [patch.object(tr, 'DATA', self.root), patch.object(tr, 'JOBS', self.root / 'jobs'),
                        patch.object(tr, 'SETTINGS', self.root / 'settings.json'),
                        patch.object(tr, 'RUNTIME', self.root / 'runtime'),
                        patch.object(tr.kp, 'OUT', self.root / 'output'),
                        patch.object(tr, 'read_key', return_value='test-only-not-a-real-key'),
                        patch.object(tr, 'settings', return_value={'base': 'https://example.com/v1',
                                                                 'model': 'deepseek-flash', 'service': 'test', 'account': 'test'})]
        for item in self.patches: item.start()
        executable = tr.RUNTIME / 'bin/bbook_maker'
        executable.parent.mkdir(parents=True)
        executable.touch()
        self.source = self.root / 'original.epub'
        epub(self.source)

    def tearDown(self):
        for item in reversed(self.patches): item.stop()
        self.temp.cleanup()

    def setup_job(self, preview=False):
        job = 'a' * 24
        folder = tr.job_dir(job)
        folder.mkdir(parents=True)
        epub(folder / 'book.epub')
        tr.atomic_json(folder / 'state.json', {'state': 'queued', 'pid': os.getpid()})
        tr.atomic_json(folder / 'request.json', {'config': tr.settings(), 'preview': preview, 'title': 'Sample'})
        return job, folder

    def test_resume_only_with_checkpoint_and_no_secret_in_command(self):
        folder = self.root
        args = tr.command(folder, tr.settings(), False)
        self.assertNotIn('--resume', args)
        self.assertNotIn('--test', args)
        self.assertNotIn('test-only-not-a-real-key', ' '.join(args))
        (folder / '.book.temp.bin').write_bytes(b'checkpoint')
        self.assertIn('--resume', tr.command(folder, tr.settings(), False))
        self.assertIn('--test', tr.command(folder, tr.settings(), True))

    def test_chatgpt_route_uses_codex_without_key_or_parallel(self):
        args = tr.command(self.root, {'provider': 'chatgpt', 'base': '', 'model': 'gpt-6-luna', 'workers': 4}, False)
        self.assertEqual(args[args.index('--api_format') + 1], 'codex')
        for flag in ['--api_base', '--no-thinking', '--parallel-workers', '--use_context']:
            self.assertNotIn(flag, args)

    def test_provider_does_not_change_identity_of_existing_api_jobs(self):
        base = {'base': 'https://example.com/v1', 'model': 'm', 'service': 's', 'account': 'a'}
        jobs = []
        for config in [base, {**base, 'provider': 'deepseek'}]:
            with patch.object(tr, 'settings', return_value=config):
                jobs.append(tr.start(self.source)['job'])
        self.assertEqual(jobs[0], jobs[1])

    def test_save_chatgpt_and_api_services(self):
        with patch.object(tr, 'settings', return_value={'base': 'https://old.example/v1', 'model': 'm', 'service': 's', 'account': 'a'}), \
             patch.object(tr, 'has_key', return_value=False), \
             patch.object(tr.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
            tr.save_settings(base='', model='gpt-6-luna', provider='chatgpt')
            saved = json.loads(tr.SETTINGS.read_text())
            self.assertEqual((saved['provider'], saved['base'], saved['service']), ('chatgpt', '', ''))
            tr.save_settings(base='https://api.deepseek.com/v1/', model='deepseek-flash', provider='deepseek', workers='2')
            saved = json.loads(tr.SETTINGS.read_text())
            self.assertEqual((saved['base'], saved['workers'], saved['service']), ('https://api.deepseek.com/v1', 2, tr.KEY_SERVICE))
            with self.assertRaisesRegex(ValueError, '模型'):
                tr.save_settings(base='https://api.deepseek.com/v1', model=' ', provider='deepseek')

    def test_find_reports_existing_job_without_starting_one(self):
        self.assertEqual(tr.find(self.source)['state'], 'none')
        self.assertFalse(tr.JOBS.exists() and any(tr.JOBS.iterdir()))
        digest = hashlib.sha256(self.source.read_bytes()).hexdigest()
        folder = tr.job_dir(tr.job_id(digest, tr.settings(), False)); folder.mkdir(parents=True)
        tr.atomic_json(folder / 'state.json', {'state': 'cancelled', 'message': '翻译已停止'})
        self.assertEqual(tr.find(self.source)['state'], 'cancelled')
        tr.atomic_json(folder / 'state.json', {'state': 'done', 'output': str(self.root / 'missing.epub')})
        self.assertEqual(tr.find(self.source)['state'], 'none')

    def test_chinese_only_is_its_own_job_and_flag(self):
        digest = 'd' * 64
        bilingual = tr.job_id(digest, tr.settings(), False)
        self.assertEqual(bilingual, tr.job_id(digest, tr.settings(), False, 'bilingual'))
        self.assertNotEqual(bilingual, tr.job_id(digest, tr.settings(), False, 'chinese'))
        self.assertIn('--single_translate', tr.command(self.root, tr.settings(), False, 'chinese'))
        self.assertNotIn('--single_translate', tr.command(self.root, tr.settings(), False))
        with self.assertRaisesRegex(ValueError, '版本'):
            tr.start(self.source, False, 'french')

    def test_speed_and_quality_options(self):
        config = {**tr.settings(), 'workers': 4, 'style': 'literary', 'glossary': 'Hari Seldon -> 哈里·谢顿'}
        args = tr.command(self.root, config, False)
        self.assertEqual(args[args.index('--parallel-workers') + 1], '4')
        prompt = json.loads(Path(args[args.index('--prompt') + 1]).read_text())
        self.assertIn('{text}', prompt['user']); self.assertIn('文学', prompt['system'])
        self.assertIn('哈里·谢顿', Path(args[args.index('--glossary') + 1]).read_text())
        preview = tr.command(self.root, {**config, 'workers': 1, 'style': 'natural', 'glossary': ''}, True)
        self.assertNotIn('--parallel-workers', preview)
        natural = json.loads(Path(preview[preview.index('--prompt') + 1]).read_text())
        self.assertIn('避免翻译腔', natural['system'])
        self.assertEqual(args[args.index('--temperature') + 1], '0.3')
        self.assertEqual(args[args.index('--max-batch-units') + 1], '10')   # deepseek-flash is a small model
        big = tr.command(self.root, {**config, 'model': 'deepseek-v4-pro'}, False)
        self.assertNotIn('--max-batch-units', big)
        codex = tr.command(self.root, {**config, 'provider': 'chatgpt', 'model': 'gpt-6-luna'}, False)
        self.assertNotIn('--temperature', codex)
        with self.assertRaisesRegex(ValueError, '->'):
            tr.glossary_lines('no arrow here')
        self.assertIn('--no-thinking', args)

    def test_preview_and_full_use_separate_jobs_and_original_is_untouched(self):
        before = self.source.read_bytes()
        with patch.object(tr.subprocess, 'Popen') as launch, \
                patch.object(tr.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='test-birth')):
            launch.return_value.pid = os.getpid()
            preview = tr.start(self.source, True)
            full = tr.start(self.source, False)
            self.assertNotEqual(preview['job'], full['job'])
            self.assertEqual(launch.call_count, 2)
            # Duplicate clicks reuse the active task, rather than bill twice.
            again = tr.start(self.source, True)
            self.assertEqual(again['job'], preview['job'])
            self.assertEqual(launch.call_count, 2)
        self.assertEqual(self.source.read_bytes(), before)

    def test_bad_input_rejected_before_credential_access(self):
        bad = self.root / 'not.epub'; bad.write_text('not an epub')
        with patch.object(tr, 'read_key') as key:
            with self.assertRaises(ValueError): tr.start(bad)
            key.assert_not_called()
        with self.assertRaises(ValueError): tr.job_dir('../elsewhere')

    def test_failed_engine_cannot_publish_stale_output(self):
        job, folder = self.setup_job()
        epub(folder / 'book_bilingual.epub')
        with patch.object(tr, 'command', return_value=[sys.executable, '-c', 'raise SystemExit(1)']):
            tr.worker(job)
        self.assertEqual(json.loads((folder / 'state.json').read_text())['state'], 'failed')
        self.assertFalse(tr.kp.OUT.exists())
        self.assertFalse((folder / 'book_bilingual.epub').exists())

    def test_malformed_engine_output_is_not_published(self):
        job, folder = self.setup_job()
        code = "from pathlib import Path;Path('book_bilingual.epub').write_text('broken')"
        with patch.object(tr, 'command', return_value=[sys.executable, '-c', code]): tr.worker(job)
        self.assertEqual(json.loads((folder / 'state.json').read_text())['state'], 'failed')
        self.assertFalse(tr.kp.OUT.exists())

    def test_completed_output_has_readable_epub_and_digest(self):
        job, folder = self.setup_job(preview=True)
        code = "import shutil;shutil.copyfile('book.epub','book_bilingual.epub')"
        with patch.object(tr, 'command', return_value=[sys.executable, '-c', code]): tr.worker(job)
        state = json.loads((folder / 'state.json').read_text())
        self.assertEqual(state['state'], 'done')
        output = Path(state['output'])
        self.assertIn('试译3段', output.name)
        self.assertEqual(state['sha256'], hashlib.sha256(output.read_bytes()).hexdigest())

    def test_cancel_does_not_publish_and_preserves_checkpoint(self):
        job, folder = self.setup_job()
        (folder / '.book.temp.bin').write_bytes(b'checkpoint')
        tr.cancel(job)
        with patch.object(tr, 'command', return_value=[sys.executable, '-c', 'import time;time.sleep(30)']):
            tr.worker(job)
        self.assertEqual(json.loads((folder / 'state.json').read_text())['state'], 'cancelled')
        self.assertEqual((folder / '.book.temp.bin').read_bytes(), b'checkpoint')
        self.assertFalse(tr.kp.OUT.exists())

    def test_insecure_or_credential_embedded_endpoints_are_rejected(self):
        for value in ['http://example.com/v1', 'https://user:secret@example.com', 'https://example.com?key=secret']:
            with self.assertRaises(ValueError): tr.endpoint(value)
        self.assertEqual(tr.endpoint('http://localhost:11434/v1/'), 'http://localhost:11434/v1')

    def test_changed_endpoint_never_inherits_old_api_key(self):
        with patch.object(tr.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
            tr.save_settings('https://another.example/v1', 'deepseek-flash')
        saved = json.loads(tr.SETTINGS.read_text())
        self.assertEqual(saved['service'], tr.KEY_SERVICE)
        self.assertEqual(saved['account'], tr.own_account('https://another.example/v1'))
        self.assertNotEqual(saved['account'], 'test')


if __name__ == '__main__': unittest.main()


class AutoGlossaryTests(unittest.TestCase):
    TEXT = ('When Hari Seldon spoke, Gaal Dornick listened. Seldon smiled at Dornick. '
            'The Encyclopedia Galactica waited on Terminus. ') * 4 + 'The end came. But then the sun rose. ' * 20

    def test_candidates_skip_sentence_words(self):
        found = {c['term'] for c in __import__('terms').candidates(self.TEXT)}
        self.assertTrue({'Hari Seldon', 'Seldon', 'Dornick', 'Terminus'} <= found, found)
        self.assertFalse(found & {'When', 'The', 'But'})

    def test_parse_keeps_only_asked_chinese_terms(self):
        import terms
        reply = 'ok ```json {"terms": [{"en": "Seldon", "zh": "谢顿"}, {"en": "Invented", "zh": "发明"},'
        reply += ' {"en": "Terminus", "zh": "Terminus"}, {"en": "Dornick", "zh": "多尼克 # x"}]} ```'
        self.assertEqual(terms.parse(reply, ['Seldon', 'Terminus', 'Dornick']), ['Seldon -> 谢顿'])
        self.assertEqual(terms.parse('not json', ['Seldon']), [])

    def test_user_glossary_wins(self):
        import terms
        merged = terms.merge('Seldon -> 塞尔登', ['Seldon -> 谢顿', 'Terminus -> 端点星'])
        self.assertIn('Seldon -> 塞尔登', merged); self.assertNotIn('谢顿', merged); self.assertIn('端点星', merged)
        self.assertEqual(terms.merge('', []), '')

    def test_command_uses_auto_glossary_and_failure_is_silent(self):
        import terms
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root)
            (folder / 'glossary-auto.txt').write_text('Seldon -> 谢顿\n')
            config = {'base': 'https://example.com/v1', 'model': 'm', 'glossary': ''}
            args = tr.command(folder, config, False)
            self.assertIn('谢顿', Path(args[args.index('--glossary') + 1]).read_text())
            with patch.object(terms, 'ask', side_effect=OSError('offline')):
                self.assertEqual(terms.build(folder / 'missing.epub', 'https://x', 'm', 'k'), [])


class MigrationTests(unittest.TestCase):
    def test_old_fast_choices_become_new_default(self):
        with tempfile.TemporaryDirectory() as root, patch.object(tr, 'SETTINGS', Path(root) / 's.json'):
            for old, new in ((3, 16), (4, 16), (1, 1), (2, 2)):
                tr.SETTINGS.write_text(json.dumps({'base': 'https://x', 'model': 'm', 'workers': old}))
                self.assertEqual(tr.settings()['workers'], new)
            tr.SETTINGS.write_text(json.dumps({'base': 'https://x', 'model': 'm', 'workers': 3, 'partsEra': True}))
            self.assertEqual(tr.settings()['workers'], 3)
        base = {'base': 'https://x', 'model': 'm', 'service': 's', 'account': 'a'}
        self.assertEqual(tr.job_id('d', base, False), tr.job_id('d', {**base, 'partsEra': True, 'workers': 16}, False))


class GlossaryRequestTests(unittest.TestCase):
    def test_stalled_request_is_sent_again(self):
        import contextlib, terms
        calls = []
        def fake(request, timeout):
            calls.append(json.loads(request.data))
            if len(calls) == 1:
                raise TimeoutError('held open')
            return contextlib.nullcontext([b': keep-alive', b'data: {"choices":[{"delta":{"content":"{\\"terms\\": []}"}}]}', b'data: [DONE]'])
        with patch('urllib.request.urlopen', fake):
            self.assertEqual(terms.ask('https://x/v1', 'm', 'k', 't', 'a', [{'term': 'Seldon', 'count': 3, 'example': ''}]), '{"terms": []}')
        self.assertEqual(len(calls), 2); self.assertTrue(calls[0]['stream'])

