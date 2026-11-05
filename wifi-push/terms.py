"""A book-wide glossary made before translation, so parallel chapters spell names the same way.

Chapters translated at once never see each other; without a shared list, one chapter's
"Seldon" can become 谢顿 and another's 塞尔登. One request, made once per book, reads the
names that recur in the text and fixes a Chinese rendering for each. Anything that goes
wrong here only means the run goes on without the list: it never fails a translation.
"""
from collections import Counter
import html
import json
import re
import time
import urllib.error
import urllib.request
import zipfile
from xml.etree import ElementTree

NS = {'opf': 'http://www.idpf.org/2007/opf', 'dc': 'http://purl.org/dc/elements/1.1/',
      'c': 'urn:oasis:names:tc:opendocument:xmlns:container'}
# One to three capitalised words: "Seldon", "Hari Seldon", "Second Foundation".
NAME = re.compile(r"\b[A-Z][a-z]+(?:[ \-][A-Z][a-z]+){0,2}\b")
WORD = re.compile(r"[A-Za-z]+")
# Sentence starters a short or dialogue-heavy book may never write in lower case.
STOP = set('a an and as at but by for from he her his how i if in it its my no not now of oh on or our she so '
           'that the then there these they this those to we what when where which while who why with yes you your '
           'chapter part book mr mrs ms dr st sir lord lady january february march april may june july august '
           'september october november december monday tuesday wednesday thursday friday saturday sunday'.split())
LIMIT = 150          # candidates sent to the model
MAX_TERMS = 300      # lines kept
TEXT_BUDGET = 6_000_000


def book_meta(path):
    """Title and author from the OPF, or blanks; never raises."""
    try:
        with zipfile.ZipFile(path) as book:
            root = ElementTree.fromstring(book.read('META-INF/container.xml'))
            opf = ElementTree.fromstring(book.read(root.find('.//c:rootfile', NS).get('full-path')))
            return ((opf.findtext('.//dc:title', '', NS) or '').strip()[:120],
                    (opf.findtext('.//dc:creator', '', NS) or '').strip()[:80])
    except Exception:
        return '', ''


def book_text(path):
    """The readable text of every (X)HTML file, in archive order, up to a budget."""
    parts, size = [], 0
    with zipfile.ZipFile(path) as book:
        for name in book.namelist():
            if not name.lower().endswith(('.xhtml', '.html', '.htm')) or 'nav' in name.lower().rsplit('/', 1)[-1]:
                continue
            raw = book.read(name).decode('utf-8', 'ignore')
            raw = re.sub(r'(?is)<(script|style|head)\b.*?</\1>', ' ', raw)
            text = html.unescape(re.sub(r'<[^>]+>', ' ', raw))
            parts.append(re.sub(r'\s+', ' ', text))
            size += len(parts[-1])
            if size > TEXT_BUDGET:
                break
    return ' '.join(parts)


def candidates(text, limit=LIMIT):
    """Names worth fixing: capitalised often, rarely written in lower case (so not "The" or "When")."""
    lower = Counter(w for w in WORD.findall(text) if w.islower())
    found = Counter()
    for match in NAME.findall(text):
        words = match.replace('-', ' ').split()
        # "When Seldon" at a sentence start is really "Seldon"; "New York" stays whole.
        while words and words[0].lower() in STOP:
            match = match[len(words.pop(0)):].lstrip(' -')
        if words:
            found[match] += 1
    keep = []
    for term, count in found.most_common():
        if count < 3:
            break
        words = term.replace('-', ' ').split()
        # A lone word that is also written in lower case is an ordinary word ("Board", "Journal");
        # a longer name needs one word that is not ("New York", not "The Board").
        common = [w.lower() in STOP or lower[w.lower()] > count * 0.3 for w in words]
        if all(common):
            continue
        keep.append((term, count))
        if len(keep) >= limit:
            break
    examples = {}
    for term, _ in keep:
        hit = re.search(r'[^.!?]{0,90}\b' + re.escape(term) + r'\b[^.!?]{0,90}', text)
        examples[term] = hit.group(0).strip()[:200] if hit else ''
    return [{'term': t, 'count': c, 'example': examples[t]} for t, c in keep]


PROMPT = """你在为一本英文书的中译本统一译名。书名：{title}；作者：{author}。
下面是书中反复出现的大写词组，附出现次数和一句例句。请挑出其中的人名、地名、机构名、作品名和书中自造的专有名词，给出简体中文译名：
- 有通行译名的用通行译名（如 Napoleon -> 拿破仑）；人名按新华社译名习惯音译，名和姓之间用「·」。
- 普通词、头衔、月份星期、国籍或语言形容词（American、Chinese）、只是句首大写的词不要列出。
- 同一个人的全名和单独的姓要一致（Hari Seldon -> 哈里·谢顿，Seldon -> 谢顿）。
- 只是更长名称一部分的词不要单独列出（有 New York 就不列 York，有 Commanding Heights 就不列 Heights）。
- 普通名词即使大写也不要列（Board、Department、Journal、Council、Inc、East）。
- 中国人的拼音名字（Echo Wang、Liang）无法确定汉字时不要列。宁缺毋滥：拿不准的一律不列。
- note 很短：人物写性别（男 / 女，看不出就不写），有别名写别名（如「即 Hari Seldon」）；其他留空。中文要分「他」「她」，所以性别要依据例句判断，拿不准就不写。
只输出 JSON：{{"terms": [{{"en": "原文", "zh": "译名", "note": "男"}}]}}，不要解释。

{items}"""
# Any other target: the same rules, asked in English, with the rendering in that language.
PROMPT_OTHER = """You are fixing the names for a {language} translation of a book. Title: {title}; author: {author}.
Below are capitalised phrases that recur in the book, each with its count and one example sentence. Pick out the names of people, places, organisations and works, and terms the book coins, and give each one its rendering in {language}:
- Use the established rendering where there is one; otherwise transliterate the usual way for {language}.
- A full name and the surname alone must agree.
- Leave out ordinary words, titles, months and weekdays, nationality or language adjectives, words capitalised only because they start a sentence, and words that are only part of a longer listed name.
- When unsure, leave it out.
- "note" is short: a person's gender (male / female) when the example shows it, or an alias; otherwise empty.
Output only JSON: {{"terms": [{{"en": "original", "zh": "rendering in {language}", "note": ""}}]}}, with no explanation.

{items}"""


# Ways endpoints spell "answer without reasoning first"; a 400 moves to the next one.
NO_THINKING = ({'reasoning_effort': 'none'}, {'enable_thinking': False},
               {'thinking': {'type': 'disabled'}}, {})


def prompt(title, author, items, language=''):
    """The glossary request; Chinese has its own, any other target is named in the English one."""
    lines = '\n'.join(f"{i['term']}（{i['count']}次）：{i['example']}" if not language
                      else f"{i['term']} ({i['count']}x): {i['example']}" for i in items)
    if not language:
        return PROMPT.format(title=title or '未知', author=author or '未知', items=lines)
    return PROMPT_OTHER.format(language=language, title=title or 'unknown', author=author or 'unknown', items=lines)


def ask(base, model, key, title, author, items, deadline=120, first_token=25, language=''):
    """The model's reply, streamed. Some gateways now and then hold a request open without ever
    answering it while the same request sent again returns in seconds, so a request that has
    produced nothing after `first_token` seconds is dropped and sent again, until `deadline`."""
    body = {'model': model, 'temperature': 0.2, 'max_tokens': 6000, 'stream': True,
            'messages': [{'role': 'user', 'content': prompt(title, author, items, language)}]}
    end = time.monotonic() + deadline
    controls = list(NO_THINKING)
    while controls and time.monotonic() < end:
        control = controls[0]
        request = urllib.request.Request(base.rstrip('/') + '/chat/completions', data=json.dumps({**body, **control}).encode(),
                                         headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + key})
        started, reply = time.monotonic(), []
        try:
            with urllib.request.urlopen(request, timeout=min(first_token, max(1, end - started))) as response:
                for raw in response:
                    now = time.monotonic()
                    if now > end or (not reply and now - started > first_token):
                        raise TimeoutError('no answer yet')
                    raw = raw.strip()
                    if not raw.startswith(b'data:') or raw.endswith(b'[DONE]'):
                        continue
                    choices = json.loads(raw[5:]).get('choices') or [{}]
                    piece = (choices[0].get('delta') or {}).get('content') or ''
                    if piece:
                        reply.append(piece)
            return ''.join(reply)
        except urllib.error.HTTPError as error:
            if error.code not in (400, 422) or not control:
                raise
            controls.pop(0)          # this endpoint does not know that spelling; try the next
        except (TimeoutError, OSError):
            continue                 # held open or dropped: send it again
    raise TimeoutError('glossary took too long')


def parse(reply, allowed, chinese=True):
    """`en -> zh` lines for terms the model was actually asked about (`zh` in the target language)."""
    start, end = reply.find('{'), reply.rfind('}')
    if start < 0 or end <= start:
        return []
    try:
        terms = json.loads(reply[start:end + 1]).get('terms', [])
    except (json.JSONDecodeError, AttributeError):
        return []
    allowed = set(allowed)
    lines, seen = [], set()
    for item in terms if isinstance(terms, list) else []:
        if not isinstance(item, dict):
            continue
        en, zh = str(item.get('en', '')).strip(), str(item.get('zh', '')).strip()
        # A rendering must be Chinese, short, and safe for the engine's one-line format.
        if (en not in allowed or en in seen or not zh or len(zh) > (30 if chinese else 60)
                or (chinese and not re.search(r'[一-鿿]', zh)) or (not chinese and zh == en)
                or any(c in zh + en for c in '#\n\r') or '->' in zh or '→' in zh):
            continue
        seen.add(en)
        note = re.sub(r'[#\n\r]|->|→', ' ', str(item.get('note') or '')).strip()[:20]
        lines.append(f'{en} -> {zh}' + (f' # {note}' if note else ''))
    return lines[:MAX_TERMS]


def merge(user, auto):
    """The user's own lines win; an automatic line never overrides a term the user pinned."""
    pinned = {re.split(r'\s*(?:->|→)\s*', line, maxsplit=1)[0].strip().lower()
              for line in user.splitlines() if line.strip() and not line.startswith('#')}
    extra = [line for line in auto if line.split(' -> ', 1)[0].lower() not in pinned]
    return '\n'.join([line for line in [user.strip(), '# 自动整理的人名和术语'] if line] + extra) if extra else user.strip()


def build(path, base, model, key, goal='zh'):
    """The automatic lines for one book; [] when the book has too few names or anything fails.
    Names are found by Latin capitals, so a Chinese or Japanese book simply gets no list."""
    try:
        items = candidates(book_text(path))
        if len(items) < 3:
            return []
        title, author = book_meta(path)
        import languages
        language = '' if languages.target(goal) == 'zh' else languages.TARGETS[languages.target(goal)][3]
        return parse(ask(base, model, key, title, author, items, language=language), [i['term'] for i in items],
                     chinese=languages.chinese(goal))
    except Exception:
        return []
