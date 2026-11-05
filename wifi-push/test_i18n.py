"""Every sentence the app can show has an English translation, with the same blanks."""
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('i18n_collect', ROOT / 'script/i18n_collect.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


def catalog():
    entries = {}
    for line in (ROOT / 'mac-app/Assets/i18n/en.tsv').read_text().split('\n'):
        if line:
            key, value = line.split('\t', 1)
            entries[key.replace('\\n', '\n')] = value.replace('\\n', '\n')
    return entries


class Catalog(unittest.TestCase):
    def test_everything_is_translated(self):
        entries = catalog()
        missing = [k for k in collector.collect() if k not in entries]
        self.assertEqual(missing, [], f'{len(missing)} sentences need English in en.tsv')

    def test_blanks_match(self):
        for key, value in catalog().items():
            self.assertEqual(key.count('{}'), value.count('{}'), key)

    def test_english_is_not_left_in_chinese(self):
        keep = ('我的文章', '向阳乔木', '哈里', '心理史学', '简体中文', '繁體中文', '日本語')
        for key, value in catalog().items():
            if any('\u4e00' <= c <= '\u9fff' for c in value):
                self.assertTrue(any(word in value for word in keep), value)


if __name__ == '__main__':
    unittest.main()
