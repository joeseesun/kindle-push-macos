import tempfile
import unittest
from pathlib import Path

import names


class NameTests(unittest.TestCase):
    def check(self, cases, smart):
        for before, after in cases:
            with self.subTest(before=before):
                self.assertEqual(names.tidy(before, smart), after)

    def test_conservative_keeps_subtitles(self):
        self.check([
            ('银行业专业人员职业资格考试应试辅导及考点预测 银行业专业实务 个人理财 初级 2017最新版 (z-library.sk, 1lib.sk, z-lib.sk)',
             '银行业专业人员职业资格考试应试辅导及考点预测 银行业专业实务 个人理财 初级'),
            ('Who_Not_How_The_Formula_to_Achieve_Bi_z_library_sk,_1lib_sk,', 'Who Not How The Formula to Achieve Bi'),
            ('Who Not How: The Formula', 'Who Not How - The Formula'),
            ('Diamond Age (Stephenson Neal) (z-library.sk, 1lib.sk, z-lib.sk)', 'Diamond Age (Stephenson Neal)'),
            ('Clean Code [www.allitebooks.com]', 'Clean Code'),
            ('The.Great.Gatsby', 'The Great Gatsby'),
            ('人类简史 第二版', '人类简史'),
            ('1984', '1984'), ('Zlib Compression Explained', 'Zlib Compression Explained'),
        ], smart=False)

    def test_smart_keeps_the_main_title(self):
        self.check([
            ('银行业专业人员职业资格考试应试辅导及考点预测 银行业专业实务 个人理财 初级 2017最新版', '银行业专业人员职业资格考试应试辅导及考点预测'),
            ('Who Not How: The Formula to Achieve Bigger Goals', 'Who Not How'),
            ('Python Crash Course, 3rd Edition (Eric Matthes) (Z-Library)', 'Python Crash Course'),
            ('人类简史：从动物到上帝', '人类简史'), ('三体（典藏版）', '三体'),
        ], smart=True)

    def test_suggestion_prefers_the_book_title_and_can_add_the_author(self):
        path = '/books/Who_Not_How_z_library_sk.epub'
        self.assertEqual(names.suggest(path), 'Who Not How.epub')
        self.assertEqual(names.suggest(path, 'Who Not How: The Formula', 'Dan Sullivan', with_author=True),
                         'Who Not How - Dan Sullivan.epub')
        self.assertEqual(names.suggest('/books/a (z-lib.org).fb2.zip'), 'a.fb2.zip')


if __name__ == '__main__':
    unittest.main()
