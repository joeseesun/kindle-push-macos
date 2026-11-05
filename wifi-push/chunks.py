"""Split long chapters into parts before translation, and join them back afterwards.

The engine translates chapters in parallel but each chapter's requests one after another,
so a book waits on its longest chapter however many workers it has. Cutting long chapters
into parts lets every worker stay busy; the reader never sees the parts, because the
translated parts are joined back into the original file under its original name.

Everything works on the file text, not a parsed tree, so the source XHTML is kept byte for
byte: a part is the chapter's own prefix (head, body and wrapper tags), a run of its
top-level blocks, and its own suffix. Joining reads the engine's output the same way.
"""
import json
import posixpath
import re
import shutil
import zipfile
from urllib.parse import unquote

TAG = re.compile(r'<!--.*?-->|<!\[CDATA\[.*?\]\]>|<[?!][^>]*>'
                 r'|<(/?)([A-Za-z][\w:.-]*)((?:\s+[^\s=>/]+(?:\s*=\s*(?:"[^"]*"|\'[^\']*\'|[^\s>]+))?)*)\s*(/?)>', re.S)
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr'}
WRAPPERS = {'div', 'section', 'article', 'main'}
SUFFIX = '__kp'
MIN_PART, MAX_PART = 3000, 20000   # characters of text per part


def text_length(markup):
    return len(re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', markup)).strip())


def children(markup, start, end):
    """Top-level element spans in markup[start:end]: (tag, open_start, open_end, close_start, close_end)."""
    spans, depth, current = [], 0, None
    for match in TAG.finditer(markup, start, end):
        name = match.group(2)
        if not name:
            continue
        name = name.lower().split(':')[-1]
        closing, selfclosing = match.group(1) == '/', match.group(4) == '/' or name in VOID
        if closing:
            depth -= 1
            if depth == 0 and current:
                spans.append((*current, match.start(), match.end()))
                current = None
            if depth < 0:
                raise ValueError('unbalanced')
        elif selfclosing:
            if depth == 0:
                spans.append((name, match.start(), match.end(), match.end(), match.end()))
        else:
            if depth == 0:
                current = (name, match.start(), match.end())
            depth += 1
    if depth:
        raise ValueError('unbalanced')
    return spans


def body(markup):
    """(inner_start, inner_end) of <body>."""
    opening = re.search(r'<body\b[^>]*>', markup, re.I)
    closing = None
    for closing in re.finditer(r'</body\s*>', markup, re.I):
        pass
    if not opening or not closing or closing.start() < opening.end():
        raise ValueError('no body')
    return opening.end(), closing.start()


def container(markup):
    """Descend through single wrappers (body > section > div …) to the list of blocks worth cutting.

    Returns (depth, inner_start, inner_end)."""
    start, end = body(markup)
    depth = 0
    while True:
        spans = children(markup, start, end)
        loose = re.sub(r'<!--.*?-->', '', markup[start:end], flags=re.S)
        for span in spans:
            loose = loose.replace(markup[span[1]:span[4]], '', 1)
        if len(spans) == 1 and spans[0][0] in WRAPPERS and not loose.strip():
            start, end = spans[0][2], spans[0][3]
            depth += 1
            continue
        return depth, start, end


def descend(markup, depth):
    """The same container in the engine's output: the first element child, `depth` times."""
    start, end = body(markup)
    for _ in range(depth):
        spans = [s for s in children(markup, start, end)]
        if not spans:
            raise ValueError('structure changed')
        start, end = spans[0][2], spans[0][3]
    return start, end


def cut(markup, size):
    """Parts of one chapter, or None when it is short enough or its structure is not plain."""
    if text_length(markup) < size * 1.6:
        return None
    depth, start, end = container(markup)
    spans = children(markup, start, end)
    if len(spans) < 4:
        return None
    groups, current, length = [], [], 0
    for span in spans:
        current.append(span)
        length += text_length(markup[span[1]:span[4]])
        if length >= size:
            groups.append(current)
            current, length = [], 0
    if current:
        # A short tail rides with the previous part.
        if groups and length < size / 3:
            groups[-1] += current
        else:
            groups.append(current)
    if len(groups) < 2:
        return None
    prefix, suffix = markup[:start], markup[end:]
    # Later parts reopen the same wrappers; their ids stay only on the first part.
    at = prefix.lower().rfind('<body')
    later = prefix[:at] + re.sub(r'(<(?:body|section|div|article|main)\b[^>]*?)\s+id\s*=\s*("[^"]*"|\'[^\']*\')',
                                 r'\1', prefix[at:])
    parts = []
    for index, group in enumerate(groups):
        first = start if index == 0 else group[0][1]
        last = end if index == len(groups) - 1 else group[-1][4]
        parts.append((prefix if index == 0 else later) + markup[first:last] + suffix)
    return depth, parts


def opf_path(book):
    container_xml = book.read('META-INF/container.xml').decode('utf-8', 'ignore')
    return re.search(r'full-path\s*=\s*"([^"]+)"', container_xml).group(1)


def attribute(tag, name):
    found = re.search(r'\b' + name + r'\s*=\s*("([^"]*)"|\'([^\']*)\')', tag)
    return (found.group(2) if found.group(2) is not None else found.group(3)) if found else None


def set_attribute(tag, name, value):
    return re.sub(r'(\b' + name + r'\s*=\s*)("[^"]*"|\'[^\']*\')', lambda m: m.group(1) + '"' + value + '"', tag, count=1)


def split(source, target, workers):
    """Write `target` with long chapters cut into parts; return the plan, or None if nothing was cut."""
    with zipfile.ZipFile(source) as book:
        opf_name = opf_path(book)
        opf = book.read(opf_name).decode('utf-8')
        base = posixpath.dirname(opf_name)
        items = {attribute(m.group(0), 'id'): m for m in re.finditer(r'<item\b[^>]*>', opf)}
        spine = [attribute(m.group(0), 'idref') for m in re.finditer(r'<itemref\b[^>]*>', opf)]
        documents = []
        for idref in spine:
            item = items.get(idref)
            if item is None or 'xhtml' not in (attribute(item.group(0), 'media-type') or '') \
                    or 'nav' in (attribute(item.group(0), 'properties') or '').split():
                continue
            name = posixpath.normpath(posixpath.join(base, unquote(attribute(item.group(0), 'href') or '')))
            if name in book.namelist():
                documents.append((idref, name))
        texts = {name: book.read(name).decode('utf-8') for _, name in documents}
        total = sum(text_length(t) for t in texts.values())
        size = int(min(MAX_PART, max(MIN_PART, total / max(1, workers * 2))))
        plan, files = [], {}
        for idref, name in documents:
            try:
                result = cut(texts[name], size)
            except (ValueError, AttributeError):
                result = None
            if not result:
                continue
            depth, parts = result
            stem, ext = posixpath.splitext(name)
            names = [name] + [f'{stem}{SUFFIX}{i}{ext}' for i in range(2, len(parts) + 1)]
            plan.append({'id': idref, 'file': name, 'depth': depth, 'parts': names})
            files.update(zip(names, (p.encode('utf-8') for p in parts)))
        if not plan:
            return None
        for entry in plan:
            item = items[entry['id']].group(0)
            href = attribute(item, 'href')
            stem, ext = posixpath.splitext(href)
            new_items = ''.join(
                '\n    ' + set_attribute(set_attribute(item, 'id', f'{entry["id"]}{SUFFIX}{i}'), 'href', f'{stem}{SUFFIX}{i}{ext}')
                for i in range(2, len(entry['parts']) + 1))
            opf = opf.replace(item, item + new_items, 1)
            ref = re.search(r'<itemref\b[^>]*idref\s*=\s*["\']' + re.escape(entry['id']) + r'["\'][^>]*>', opf).group(0)
            new_refs = ''.join('\n    ' + set_attribute(ref, 'idref', f'{entry["id"]}{SUFFIX}{i}')
                               for i in range(2, len(entry['parts']) + 1))
            opf = opf.replace(ref, ref + new_refs, 1)
        files[opf_name] = opf.encode('utf-8')
        with zipfile.ZipFile(target, 'w') as out:
            names = book.namelist()
            if 'mimetype' in names:
                out.writestr(zipfile.ZipInfo('mimetype'), book.read('mimetype'), compress_type=zipfile.ZIP_STORED)
            for info in book.infolist():
                if info.filename == 'mimetype':
                    continue
                out.writestr(info, files.pop(info.filename, None) or book.read(info.filename),
                             compress_type=zipfile.ZIP_DEFLATED)
            for name, data in files.items():
                out.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)
    return {'size': size, 'chapters': plan, 'base': base}


def join(source, target, plan):
    """Write `target` from the engine's translated `source`, each chapter whole again."""
    with zipfile.ZipFile(source) as book:
        names = set(book.namelist())
        replaced, dropped = {}, set()
        # The engine may move everything into a folder of its own: a book with content.opf at the
        # top of the zip comes back under EPUB/. Parts are found relative to the book's OPF.
        base = plan.get('base', '')
        moved_to = posixpath.dirname(opf_path(book))

        def located(part):
            relative = part[len(base) + 1:] if base and part.startswith(base + '/') else part
            for candidate in (part, posixpath.join(moved_to, relative)):
                if candidate in names:
                    return candidate
            raise ValueError('译文已保存，但拼回章节时找不到其中一段。点「重试」不会重新翻译；还不行就用「重新翻译」。')

        for entry in plan['chapters']:
            parts = [located(p) for p in entry['parts']]
            texts = [book.read(p).decode('utf-8') for p in parts]
            inner = []
            for text in texts:
                start, end = descend(text, entry['depth'])
                inner.append(text[start:end])
            start, end = descend(texts[0], entry['depth'])
            replaced[parts[0]] = (texts[0][:start] + '\n'.join(inner) + texts[0][end:]).encode('utf-8')
            dropped.update(parts[1:])
        opf_name = opf_path(book)
        opf = book.read(opf_name).decode('utf-8')
        opf = re.sub(r'\s*<item(?:ref)?\b[^>]*["\'][^"\']*' + SUFFIX + r'\d+[^"\']*["\'][^>]*>', '', opf)
        replaced[opf_name] = opf.encode('utf-8')
        temp = str(target) + '.part'
        with zipfile.ZipFile(temp, 'w') as out:
            for info in book.infolist():
                if info.filename in dropped:
                    continue
                data = replaced.get(info.filename)
                out.writestr(info, data if data is not None else book.read(info.filename),
                             compress_type=zipfile.ZIP_STORED if info.filename == 'mimetype' else zipfile.ZIP_DEFLATED)
    shutil.move(temp, target)


def save_plan(path, plan):
    path.write_text(json.dumps(plan, ensure_ascii=False))
