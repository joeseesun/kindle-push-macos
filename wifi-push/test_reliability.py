"""Failure wording, usage tallies, formats, transfer streaming and clean-up."""
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import bookinfo
import devices as dv
import kindle_push as kp
import languages
import names
import storage
import translation as tr


class Diagnose(unittest.TestCase):
    def test_each_problem(self):
        for text, want in [('Error code: 401 - {}', 'key'), ('openai.AuthenticationError: x', 'key'),
                           ('Error code: 402', 'balance'), ('insufficient_quota', 'balance'),
                           ('CodexQuotaExhausted', 'balance'), ('Error code: 429', 'rate'),
                           ('RateLimitError', 'rate'), ('Error code: 404', 'model'), ('model_not_found', 'model'),
                           ('Error code: 503', 'server'), ('APIConnectionError', 'network')]:
            self.assertEqual(tr.diagnose(text)[0], want, text)

    def test_last_error_wins(self):
        self.assertEqual(tr.diagnose('Error code: 429\nretry\nError code: 401')[0], 'key')

    def test_unknown_and_book_text_stay_generic(self):
        self.assertEqual(tr.diagnose('Error code: 400'), ('', tr.UNKNOWN_FAILURE))
        # A provider's own words never reach the UI, however they read.
        for sentence in (tr.diagnose('Error code: 402 secret book line')[1],):
            self.assertNotIn('secret book line', sentence)


class Tokens(unittest.TestCase):
    def test_real_lines(self):
        self.assertEqual(tr.tokens_used('tokens: in 877.8k, out 382.0k, cached 0 (548 requests)'), (877800, 382000))
        self.assertEqual(tr.tokens_used('tokens: in 415, out 66, cached 0 (1 request)'), (415, 66))
        self.assertEqual(tr.tokens_used('tokens: in 1.2M, out 1.8k, cached 512 (4 requests)'), (1200000, 1800))
        self.assertIsNone(tr.tokens_used('nothing here'))

    def test_last_tally_counts(self):
        self.assertEqual(tr.tokens_used('tokens: in 1, out 1, cached 0 (1 request)\ntokens: in 2, out 3, cached 0 (1 request)'), (2, 3))


class Formats(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        self.addCleanup(self.folder.cleanup)

    def test_translatable(self):
        for name, want in [('a.epub', True), ('a.txt', True), ('a.md', True), ('a.docx', True), ('a.fb2', True),
                           ('a.pdf', False), ('a.cbz', False)]:
            self.assertEqual(kp.translatable(Path(name)), want, name)

    def test_mobi_needs_calibre(self):
        with patch.object(kp, 'calibre', return_value=None):
            self.assertFalse(kp.translatable(Path('a.mobi')))
        with patch.object(kp, 'calibre', return_value='/x/ebook-convert'):
            self.assertTrue(kp.translatable(Path('a.azw3')))

    def test_text_of_txt_html_rtf_docx(self):
        (self.root / 'a.txt').write_text('Hello   there')
        self.assertEqual(languages.text_of(self.root / 'a.txt', '.txt'), 'Hello there')
        (self.root / 'b.txt').write_bytes('你好，世界'.encode('gb18030'))
        self.assertEqual(languages.text_of(self.root / 'b.txt', '.txt'), '你好，世界')
        (self.root / 'a.html').write_text('<html><head><title>no</title></head><body><p>Hi &amp; bye</p></body></html>')
        self.assertEqual(languages.text_of(self.root / 'a.html', '.html'), 'Hi & bye')
        (self.root / 'a.rtf').write_text(r'{\\rtf1\\ansi Hello \\b world}')
        self.assertIn('Hello', languages.text_of(self.root / 'a.rtf', '.rtf'))
        with zipfile.ZipFile(self.root / 'a.docx', 'w') as book:
            book.writestr('word/document.xml', '<w:t>Inside the &amp; doc</w:t>')
        self.assertEqual(languages.text_of(self.root / 'a.docx', '.docx'), 'Inside the & doc')

    def test_info_for_text(self):
        path = self.root / 'book.txt'
        path.write_text('The quick brown fox and the lazy dog were in the house with all of them. ' * 40)
        result = bookinfo.info(path)
        self.assertTrue(result['translatable'])
        self.assertEqual(result['language'], 'en')
        self.assertGreater(result['textSize'], 1000)

    def test_info_for_pdf_is_not_translatable(self):
        path = self.root / 'a.pdf'
        path.write_bytes(b'%PDF-1.4')
        self.assertFalse(bookinfo.info(path)['translatable'])


class NoSecondCopy(unittest.TestCase):
    def test_file_already_in_output_is_sent_as_it_is(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder).resolve()
            path = out / '书（中英对照）.mobi'
            path.write_bytes(b'x' * 100)
            with patch.object(kp, 'OUT', out), patch.object(kp, 'validate_native'):
                self.assertEqual(kp.convert(path), path)
            self.assertEqual(sorted(p.name for p in out.iterdir() if not p.name.startswith('.')), [path.name])


class Streaming(unittest.TestCase):
    def fake(self, script):
        return patch.object(kp, 'ssh_command', return_value=[sys.executable, '-c', script])

    def test_put_streams_and_reports(self):
        with tempfile.TemporaryDirectory() as folder:
            mark = Path(folder) / 'p.json'
            got = Path(folder) / 'got'
            code = f"import sys;open({str(got)!r},'wb').write(sys.stdin.buffer.read());print('OK')"
            with self.fake(code), patch.dict(os.environ, {'KINDLEPUSH_PROGRESS': str(mark)}):
                self.assertEqual(kp.put({}, b'name\n5\n', b'x' * 300_000, 30).strip(), b'OK')
            self.assertEqual(got.read_bytes(), b'name\n5\n' + b'x' * 300_000)
            self.assertEqual(json.loads(mark.read_text()), {'percent': 100, 'stage': 'send'})

    def test_failure_raises_with_stderr(self):
        with self.fake("import sys;sys.stderr.write('Connection refused');sys.exit(255)"):
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                kp.put({}, b'', b'x', 30)
            self.assertIn(b'refused', caught.exception.stderr)

    def test_stalled_transfer_is_killed(self):
        with self.fake('import time;time.sleep(30)'), self.assertRaises(subprocess.TimeoutExpired):
            kp.put({}, b'', b'x', 0.3)

    def test_silent_without_the_env_var(self):
        with patch.dict(os.environ):
            os.environ.pop('KINDLEPUSH_PROGRESS', None)
            kp.report_progress(50)


class Locks(unittest.TestCase):
    def test_concurrent_adds_lose_nothing(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            config = root / 'config.json'
            script = (f"import sys;sys.path.insert(0,{str(Path(__file__).parent)!r});from pathlib import Path\n"
                      "import kindle_push as kp,devices as dv\n"
                      f"kp.DATA=Path({folder!r});kp.CONFIG=Path({str(config)!r})\n"
                      "dv.add(sys.argv[1],'10.0.0.1')\n")
            processes = [subprocess.Popen([sys.executable, '-B', '-c', script, 'ssh-ed25519 KEY%d' % i]) for i in range(8)]
            for process in processes:
                self.assertEqual(process.wait(), 0)
            self.assertEqual(len(json.loads(config.read_text())['devices']), 8)

    def test_nested_lock_does_not_deadlock(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(kp, 'DATA', Path(folder)):
            with dv._locked():
                with dv._locked():
                    pass

    def test_names_claim_is_unique(self):
        with tempfile.TemporaryDirectory() as folder:
            out, seen = Path(folder), []
            def claim(i):
                seen.append(names.unique_output(out, '书', '.epub', f'owner{i}').name)
            threads = [threading.Thread(target=claim, args=(i,)) for i in range(10)]
            [t.start() for t in threads]
            [t.join() for t in threads]
            self.assertEqual(len(set(seen)), 10)


class EngineHealth(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.runtime = Path(self.folder.name) / 'runtime'
        patcher = patch.object(tr, 'RUNTIME', self.runtime)
        patcher.start()
        self.addCleanup(patcher.stop)

    def make(self, python):
        (self.runtime / 'bin').mkdir(parents=True)
        (self.runtime / 'bin/bbook_maker').touch()
        (self.runtime / 'bin/python3').symlink_to(python)

    def test_missing(self):
        self.assertFalse(tr.runtime_ready())

    def test_python_that_is_gone_is_not_ready(self):
        self.make('/nonexistent/python3')
        with patch.object(tr.subprocess, 'run', side_effect=OSError):
            self.assertFalse(tr.runtime_ready())

    def test_repaired_when_the_pointer_can_be_fixed(self):
        self.make('/nonexistent/python3')
        (self.runtime / 'lib' / f'python{sys.version_info.major}.{sys.version_info.minor}').mkdir(parents=True)
        answers = iter([False, True])
        with patch.object(tr, 'engine_runs', side_effect=lambda: next(answers)), patch.object(tr.subprocess, 'run') as run:
            self.assertTrue(tr.runtime_ready())
        self.assertIn('--upgrade', run.call_args[0][0])

    def test_another_pythons_environment_is_left_alone(self):
        self.make('/nonexistent/python3')
        (self.runtime / 'lib/python2.7').mkdir(parents=True)
        with patch.object(tr, 'engine_runs', return_value=False), patch.object(tr.subprocess, 'run') as run:
            self.assertFalse(tr.runtime_ready())
        run.assert_not_called()

    def test_healthy_does_not_touch_it(self):
        self.make('/usr/bin/true')
        with patch.object(tr, 'engine_runs', return_value=True), patch.object(tr.subprocess, 'run') as run:
            self.assertTrue(tr.runtime_ready())
        run.assert_not_called()


class Storage(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        root = Path(self.folder.name)
        self.jobs, self.covers, self.runtime = root / 'jobs', root / 'covers', root / 'runtime'
        for patcher in (patch.object(tr, 'JOBS', self.jobs), patch.object(storage, 'COVERS', self.covers),
                        patch.object(tr, 'RUNTIME', self.runtime), patch.object(kp, 'OUT', root / 'out')):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.job('a' * 24, 'done')
        self.job('b' * 24, 'failed')
        self.covers.mkdir()
        (self.covers / 'used.jpg').write_bytes(b'1')
        (self.covers / 'gone.jpg').write_bytes(b'22')
        self.runtime.mkdir()
        (self.runtime / 'x').write_bytes(b'333')

    def job(self, name, state):
        folder = self.jobs / name
        folder.mkdir(parents=True)
        (folder / 'state.json').write_text(json.dumps({'state': state}))
        (folder / 'book.epub').write_bytes(b'book')

    def test_clean_jobs_keeps_checkpoints(self):
        self.assertEqual(storage.usage()['jobs'], 1)
        result = storage.clean('jobs')
        self.assertEqual([p.name for p in (self.jobs / ('a' * 24)).iterdir()], ['state.json'])
        self.assertTrue((self.jobs / ('b' * 24) / 'book.epub').exists())
        self.assertEqual(result['jobs'], 0)

    def test_clean_covers_keeps_the_ones_in_the_list(self):
        storage.clean('covers', [str(self.covers / 'used.jpg')])
        self.assertEqual([p.name for p in self.covers.iterdir()], ['used.jpg'])

    def test_runtime_refused_while_translating(self):
        with patch.object(storage, 'running', return_value=True), self.assertRaises(ValueError):
            storage.clean('runtime')
        self.assertTrue(self.runtime.exists())
        with patch.object(storage, 'running', return_value=False):
            storage.clean('runtime')
        self.assertFalse(self.runtime.exists())

    def test_unknown_item(self):
        with self.assertRaises(ValueError):
            storage.clean('everything')


if __name__ == '__main__':
    unittest.main()
