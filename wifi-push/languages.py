"""Which language a book is written in, and the names a target language goes by.

Detection runs on this Mac and never calls a model: the OPF's `dc:language` is read, then a
sample of the text is checked by script (Han, kana, Hangul, Cyrillic) and, for Latin text, by
common words. The text wins when it is clear, because publishers often stamp the wrong tag
(Chinese translations labelled `en`, every book of a shop labelled `zh`).
"""
import html
import re
import zipfile
from xml.etree import ElementTree

NS = {'dc': 'http://purl.org/dc/elements/1.1/', 'c': 'urn:oasis:names:tc:opendocument:xmlns:container'}

# code: (engine --language, name in a Chinese UI, one character for 中英对照, name in prompts)
TARGETS = {
    'zh': ('zh-hans', '中文', '中', 'Simplified Chinese'),
    'en': ('en', '英文', '英', 'English'),
    'ja': ('ja', '日文', '日', 'Japanese'),
    'ko': ('ko', '韩文', '韩', 'Korean'),
    'fr': ('fr', '法文', '法', 'French'),
    'de': ('de', '德文', '德', 'German'),
    'es': ('es', '西班牙文', '西', 'Spanish'),
    'zh-hant': ('zh-hant', '繁体中文', '繁', 'Traditional Chinese'),
    'ru': ('ru', '俄文', '俄', 'Russian'),
    'it': ('it', '意大利文', '意', 'Italian'),
    'pt': ('pt', '葡萄牙文', '葡', 'Portuguese'),
    'nl': ('nl', '荷兰文', '荷', 'Dutch'),
    'pl': ('pl', '波兰文', '波', 'Polish'),
    'tr': ('tr', '土耳其文', '土', 'Turkish'),
    'uk': ('uk', '乌克兰文', '乌', 'Ukrainian'),
    'ar': ('ar', '阿拉伯文', '阿', 'Arabic'),
    'hi': ('hi', '印地文', '印地', 'Hindi'),
    'id': ('id', '印尼文', '印尼', 'Indonesian'),
    'vi': ('vi', '越南文', '越', 'Vietnamese'),
    'th': ('th', '泰文', '泰', 'Thai'),
}
# Any of these can be a book's language and a target; detection finds only some of them.
NAMES = {code: value[1] for code, value in TARGETS.items()}
CHARS = {code: value[2] for code, value in TARGETS.items()}

# A few very common words per Latin-script language; shared words count for none.
WORDS = {
    'en': 'the and of to is was that with for his her this which have from they not but are you',
    'fr': 'le la les et des est une dans que pour qui sur pas avec il elle sont au du nous',
    'de': 'der die und das ist nicht ein eine zu den mit sich auf dem des sie ich es war',
    'es': 'el la los las que de y en por una con para es se del su al como pero',
    'it': 'il di che la e non per una sono gli con del della le si ma come anche',
    'pt': 'o a os as que de e em um uma para com não se do da no na mas',
    'nl': 'de het een en van is dat niet op te zijn met voor hij ze maar ook',
}
WORDS = {code: set(words.split()) for code, words in WORDS.items()}
SAMPLE = 20_000


def target(code):
    """A supported target language code; Chinese when unknown."""
    return code if code in TARGETS else 'zh'


def base(tag):
    """'zh-Hans-CN' -> 'zh', 'EN_us' -> 'en'; '' when there is no tag."""
    tag = (tag or '').strip().lower().replace('_', '-')
    return re.split('[-;, ]', tag, maxsplit=1)[0][:3] if tag else ''


def from_text(text):
    """The language of a sample of text, or '' when it is not clear."""
    han = len(re.findall(r'[一-鿿]', text))
    kana = len(re.findall(r'[぀-ヿ]', text))
    hangul = len(re.findall(r'[가-힯]', text))
    cyrillic = len(re.findall(r'[Ѐ-ӿ]', text))
    latin = len(re.findall(r'[A-Za-zÀ-ɏ]', text))
    total = han + kana + hangul + cyrillic + latin
    if total < 40:
        return ''
    if kana > 0.05 * total:
        return 'ja'
    if hangul > 0.2 * total:
        return 'ko'
    # A Chinese book quotes English now and then; Han characters carry far more per letter.
    if han * 3 > latin and han > 0.2 * total:
        return 'zh'
    if cyrillic > 0.5 * total:
        return 'ru'
    if latin < 0.6 * total:
        return ''
    words = re.findall(r'[a-zà-ÿ]+', text.lower())
    scores = {code: sum(1 for w in words if w in vocab) for code, vocab in WORDS.items()}
    best = max(scores, key=scores.get)
    ranked = sorted(scores.values(), reverse=True)
    if ranked[0] < 5 or ranked[0] < ranked[1] * 1.3:
        return ''
    return best


def sample(book):
    """Body text from the middle of the book's documents, skipping the front matter."""
    documents = [n for n in book.namelist() if n.lower().endswith(('.xhtml', '.html', '.htm'))
                 and not re.search(r'nav|toc|cover|title|copyright', n.lower().rsplit('/', 1)[-1])]
    documents = documents[len(documents) // 4:] + documents[:len(documents) // 4]
    parts, size = [], 0
    for name in documents:
        raw = book.read(name)[:200_000].decode('utf-8', 'ignore')
        raw = re.sub(r'(?is)<(script|style|head)\b.*?</\1>', ' ', raw)
        text = re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', raw))).strip()
        parts.append(text)
        size += len(text)
        if size > SAMPLE:
            break
    return ' '.join(parts)[:SAMPLE]


def stated(book):
    """The OPF's dc:language, as a base code."""
    container = ElementTree.fromstring(book.read('META-INF/container.xml'))
    opf = ElementTree.fromstring(book.read(container.find('.//c:rootfile', NS).get('full-path')))
    return base(opf.findtext('.//dc:language', '', NS))


def detect(path):
    """The book's language as a base code ('en', 'zh', …), or '' when it cannot be told. Never raises."""
    try:
        with zipfile.ZipFile(path) as book:
            try:
                tag = stated(book)
            except Exception:
                tag = ''
            found = from_text(sample(book))
    except Exception:
        return ''
    return found or tag


def chinese(goal):
    """Simplified or Traditional: both get Chinese punctuation and a Han-only glossary."""
    return target(goal) in ('zh', 'zh-hant')


def pair_label(source, goal):
    """'中英对照' for English and Chinese either way round, '英日对照' for English into Japanese,
    '中英对照·繁体' into Traditional Chinese."""
    goal = target(goal)
    if goal == 'zh-hant':
        return pair_label(source, 'zh') + '·繁体'

    if source not in CHARS or source == goal:
        return '双语对照'
    first, second = CHARS[source], CHARS[goal]
    if goal == 'zh' or source == 'zh':
        first, second = '中', second if source == 'zh' else first
    return f'{first}{second}对照'


def only_label(goal):
    """The file label of a translation without the original: '中文', '英文'."""
    return TARGETS[target(goal)][1]
