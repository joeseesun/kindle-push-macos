import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class ReceiverTests(unittest.TestCase):
    def test_roundtrip_rejects_truncation_traversal_and_arbitrary_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dest = root / 'received'
            receiver = root / 'receive.sh'
            receiver.write_text(Path(__file__).with_name('kindle-receive.sh').read_text().replace('dest=/mnt/us/documents/我的文章', 'dest=' + str(dest)))
            def call(op, data):
                return subprocess.run(['sh', str(receiver)], input=data, capture_output=True, env={**os.environ, 'SSH_ORIGINAL_COMMAND': op})
            data = b'payload' * 1024
            filename = '中文.epub\n'.encode()
            response = call('put', filename + str(len(data)).encode() + b'\n' + data)
            self.assertEqual(response.returncode, 0, response.stderr)
            self.assertEqual(call('get', filename).stdout, data)
            self.assertNotEqual(call('put', filename + b'12345\npartial').returncode, 0)
            self.assertEqual((dest / '中文.epub').read_bytes(), data)
            self.assertNotEqual(call('put', b'../outside.epub\n1\nx').returncode, 0)
            self.assertNotEqual(call('arbitrary shell command', b'').returncode, 0)
            self.assertEqual(call('ping', b'').stdout, b'kindle-push-v2\n')
            self.assertEqual(call('put', b'paper.pdf\n4\n%PDF').returncode, 0)
            self.assertEqual(call('put', b'novel.fb2.zip\n1\nx').returncode, 0)
            self.assertNotEqual(call('put', b'run.sh\n1\nx').returncode, 0)


if __name__ == '__main__':
    unittest.main()
