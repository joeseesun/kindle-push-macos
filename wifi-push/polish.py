"""Chinese punctuation in the translated text: full-width marks after Chinese, curly quotes.

Models often end a Chinese sentence with "." or put "," between two Chinese clauses. Only
text that contains Chinese is touched, and only a mark that follows a Chinese character, so
the English original, numbers (3.5), abbreviations (U.S.) and code stay exactly as they were.
"""
import re
import shutil
import zipfile

HAN = '㐀-䶿一-鿿豈-﫿　-〿＀-￯'
HAS_HAN = re.compile(f'[一-鿿]')
AFTER_HAN = {',': '，', ';': '；', ':': '：', '?': '？', '!': '！'}
SKIP = re.compile(r'(?is)<(script|style|code|pre)\b.*?</\1\s*>')
TEXT = re.compile(r'(?s)(<[^>]*>)')


def text(value):
    if not HAS_HAN.search(value):
        return value
    value = re.sub(f'(?<=[{HAN}])\\s*([,;:?!])(?!\\d)', lambda m: AFTER_HAN[m.group(1)], value)
    # A full stop after Chinese, unless it starts an ellipsis or a number.
    value = re.sub(f'(?<=[{HAN}])\\.(?![.\\d])', '。', value)
    value = re.sub(f'(?<=[{HAN}])\\.{{3,}}', '……', value)
    value = re.sub(f'\\((?=[{HAN}])', '（', value)
    value = re.sub(f'(?<=[{HAN}])\\)', '）', value)
    value = re.sub(r'（([^()（）]*)\)', r'（\1）', value)
    # Straight double quotes, when they pair up inside this run of text.
    if value.count('"') and value.count('"') % 2 == 0:
        marks = iter('“”' * (value.count('"') // 2))
        value = re.sub('"', lambda m: next(marks), value)
    # No space between Chinese and a full-width mark.
    value = re.sub(r'\s+([，。；：？！”）])', r'\1', value)
    value = re.sub(r'([“（])\s+', r'\1', value)
    return value


def markup(document):
    """Apply `text` to the character data of an XHTML document, never to tags or scripts."""
    out, last = [], 0
    for skip in SKIP.finditer(document):
        out.append(_runs(document[last:skip.start()]))
        out.append(skip.group(0))
        last = skip.end()
    out.append(_runs(document[last:]))
    return ''.join(out)


def _runs(chunk):
    body = chunk.lower().find('<body')
    head, rest = (chunk[:body], chunk[body:]) if body >= 0 else ('', chunk)
    return head + ''.join(part if part.startswith('<') else text(part) for part in TEXT.split(rest))


def epub(path):
    """Polish every content document of the EPUB at `path` in place."""
    temp = str(path) + '.polish'
    with zipfile.ZipFile(path) as book, zipfile.ZipFile(temp, 'w') as out:
        for info in book.infolist():
            data = book.read(info.filename)
            if info.filename.lower().endswith(('.xhtml', '.html', '.htm')):
                try:
                    data = markup(data.decode('utf-8')).encode('utf-8')
                except UnicodeDecodeError:
                    pass
            out.writestr(info, data, compress_type=zipfile.ZIP_STORED if info.filename == 'mimetype' else zipfile.ZIP_DEFLATED)
    shutil.move(temp, path)
