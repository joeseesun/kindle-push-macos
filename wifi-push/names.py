"""Clean book file names: drop shadow-library marks, messy separators and edition suffixes.

Works on names only; the book itself is never changed here.
"""
import json
import re
from pathlib import Path

LIBRARY = r'(?:z-?lib(?:rary)?(?:[ ._-]?(?:sk|org|is|se|rs|io|id))?|1lib(?:[ ._-]?(?:sk|org|net))?|libgen(?:[ ._-]?\w{2,3})?|anna\'?s[ _-]?archive|b-ok(?:[ ._-]?\w{2,3})?)'
# "(z-library.sk, 1lib.sk, z-lib.sk)", "[Z-Library]", "【www.xxx.com】" and the like.
MARKED_GROUP = re.compile(r'\s*[(\[【（]([^()\[\]【】（）]*)[)\]】）]\s*')
LIBRARY_WORD = re.compile(LIBRARY, re.I)
SITE = re.compile(r'(?:www\.)?[a-z0-9-]+\.(?:com|net|org|cn|cc|me|top)\b', re.I)
# A mark left without brackets, often mangled: "..._z_library_sk,_1lib_sk,".
TRAILING_LIBRARY = re.compile(r'[\s,;-]*\b(?:z[\s-]?lib(?:rary)?|1lib|libgen|anna\'?s\s?archive)\b.*$', re.I)
EDITION = re.compile(
    r'(?:[\s,，(（\[【-]*)(?:'
    r'(?:19|20)\d{2}\s*(?:年)?\s*(?:最新|全新|修订|新)?\s*版'          # 2017最新版
    r'|第\s*[0-9一二三四五六七八九十]+\s*版'                              # 第二版
    r'|(?:最新|全新|修订|增订|珍藏|典藏|精装|平装|插图|彩图|完整|新)\s*版'  # 修订版
    r'|\d+(?:st|nd|rd|th)\s+(?:ed(?:ition)?\.?)'                       # 2nd Edition
    r'|(?:revised|updated|new)\s+edition'
    r'|[(（\[]\s*(?:19|20)\d{2}\s*[)）\]]'                              # (2017)
    r')[)）\]】]*\s*$', re.I)
YEAR = re.compile(r'[\s_-]+(?:19|20)\d{2}$')
CJK = re.compile(r'[㐀-鿿]')


def _strip_marks(name):
    def group(match):
        inner = match.group(1)
        return ' ' if LIBRARY_WORD.search(inner) or SITE.fullmatch(inner.strip()) else match.group(0)
    name = MARKED_GROUP.sub(group, name)
    return TRAILING_LIBRARY.sub('', name)


def _separators(name):
    if ' ' not in name and name.count('.') >= 2:
        name = name.replace('.', ' ')  # The.Great.Gatsby
    name = name.replace('_', ' ')
    name = re.sub(r'\s+', ' ', name)
    name = re.sub(r'\s+([,，;；:：!！?？)）\]】])', r'\1', name)
    return name.strip(' ,，;；-_.·')


def _strip_edition(name):
    for _ in range(3):  # "... 初级 2017最新版" may hide a year behind an edition
        shorter = YEAR.sub('', EDITION.sub('', name)).strip(' ,，;；-_.·')
        if not shorter or shorter == name:
            break
        name = shorter
    return name


def _main_title(name):
    """Keep the main title: no subtitle, no trailing author or publisher in brackets."""
    while True:
        shorter = re.sub(r'\s*[(\[（【][^()\[\]（）【】]*[)\]）】]\s*$', '', name).strip()
        if not shorter or shorter == name:
            break
        name = shorter
    for mark in (':', '：', ' - ', ' — ', '——', ' | '):
        head = name.split(mark, 1)[0].strip()
        if head and head != name and len(head) >= 2:
            return head
    if CJK.search(name):
        # Chinese titles carry their description after a space: 书名 银行业专业实务 个人理财 初级
        head = name.split(' ', 1)[0]
        if len(head) >= 2 and CJK.search(head) and ' ' in name:
            return head
    return name


def tidy(name, smart=True):
    """A clean title for a file name. `smart` also drops subtitles and bracketed extras."""
    original = name
    name = _separators(_strip_marks(name))
    name = _separators(TRAILING_LIBRARY.sub('', name))  # once more, now that "_" is a space
    name = _strip_edition(name)
    if smart:
        name = _strip_edition(_main_title(name))
    name = re.sub(r'\s*:\s*', ' - ', name)  # Finder cannot show ":" in a name
    name = re.sub(r'[\x00-\x1f/\\*?"<>|]', ' ', name)
    name = re.sub(r'\s+', ' ', name).strip(' .')[:80].strip()
    return name or original.strip() or '书籍'


def file_stem(path, suffix):
    name = Path(path).name
    return name[:-len(suffix)] if suffix and name.lower().endswith(suffix) else Path(path).stem


def unique_output(folder, title, suffix, owner):
    """`folder/title+suffix`, kept per owner so resending replaces the same file,
    while two different books with the same title get `title 2`, `title 3`."""
    index_file = folder / '.names.json'
    try:
        index = json.loads(index_file.read_text())
    except (OSError, ValueError):
        index = {}
    for number in range(1, 1000):
        name = (title if number == 1 else f'{title} {number}') + suffix
        holder = index.get(name)
        if holder == owner or (holder is None and not (folder / name).exists()):
            index[name] = owner
            temp = index_file.with_suffix('.tmp')
            temp.write_text(json.dumps(index, ensure_ascii=False, indent=1))
            temp.replace(index_file)
            return folder / name
    raise ValueError('同名文件太多：' + title)


def suggest(path, title='', author='', smart=True, with_author=False):
    """A new file name for the original, from the book's own title when it has one."""
    import kindle_push as kp
    source = Path(path)
    suffix = kp.extension(source)
    base = tidy(title, smart) if title.strip() else tidy(file_stem(source, suffix), smart)
    author = tidy(author, smart=True) if author.strip() else ''
    if with_author and author and author not in base:
        base = f'{base} - {author}'
    return base + suffix
