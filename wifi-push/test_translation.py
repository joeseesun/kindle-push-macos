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

    def test_speed_and_quality_options(self):
        config = {**tr.settings(), 'workers': 4, 'style': 'literary', 'glossary': 'Hari Seldon -> 哈里·谢顿'}
        args = tr.command(self.root, config, False)
        self.assertEqual(args[args.index('--parallel-workers') + 1], '4')
        prompt = json.loads(Path(args[args.index('--prompt') + 1]).read_text())
        self.assertIn('{text}', prompt['user']); self.assertIn('文学', prompt['system'])
        self.assertIn('哈里·谢顿', Path(args[args.index('--glossary') + 1]).read_text())
        preview = tr.command(self.root, {**config, 'workers': 1, 'style': 'natural', 'glossary': ''}, True)
        self.assertNotIn('--parallel-workers', preview); self.assertNotIn('--prompt', preview)
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
