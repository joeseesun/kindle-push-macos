#!/usr/bin/env python3
"""Every Chinese sentence the app can show, as templates with {} for what is filled in.

The app keeps Chinese in its code and state, and translates what it is about to draw (see
I18n.swift). So this reads the Swift and Python sources, and a test checks the catalog has them all.
"""
import ast
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HAN = re.compile(r'[一-鿿]')
# Written into books or prompts, or matched against them: never shown as interface text.
SKIP_PY = {'terms.py', 'polish.py', 'markdown_support.py'}
SKIP_PY_NAMES = {'RULES', 'STYLES', 'RULES_OTHER', 'STYLES_OTHER', 'ENGINE_PROMPT', 'TARGETS', 'CALLOUTS', 'COMMON', 'STOPWORDS'}


def swift_literals(text):
    """Yield string literals with \\(…) replaced by {}, ignoring comments."""
    i, n = 0, len(text)
    while i < n:
        if text.startswith('//', i):
            i = text.find('\n', i)
            i = n if i < 0 else i
        elif text.startswith('/*', i):
            i = text.find('*/', i) + 2
        elif text[i] == '"':
            raw = i > 0 and text[i - 1] == '#'
            i += 1
            out = []
            while i < n and text[i] != '"':
                if text[i] == '\\' and not raw and text[i + 1] == '(':
                    depth, i = 1, i + 2
                    while depth:
                        if text[i] == '"':       # A string inside the interpolation.
                            i += 1
                            while text[i] != '"':
                                i += 2 if text[i] == '\\' else 1
                        elif text[i] == '(':
                            depth += 1
                        elif text[i] == ')':
                            depth -= 1
                        i += 1
                    out.append('{}')
                elif text[i] == '\\' and not raw:
                    out.append(text[i:i + 2])
                    i += 2
                else:
                    out.append(text[i])
                    i += 1
            i += 1
            yield ''.join(out)
        else:
            i += 1


def py_template(node):
    """A string expression as a template, or None when it holds no text of its own."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        return ''.join(v.value if isinstance(v, ast.Constant) else '{}' for v in node.values)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left, right = py_template(node.left), py_template(node.right)
        return (left if left is not None else '{}') + (right if right is not None else '{}')
    return None


def py_strings(source):
    tree = ast.parse(source)
    skipped = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(getattr(t, 'id', '') in SKIP_PY_NAMES for t in node.targets):
            skipped.update(id(n) for n in ast.walk(node))
    inner = set()
    for node in ast.walk(tree):
        if id(node) in skipped or id(node) in inner:
            continue
        if isinstance(node, (ast.BinOp, ast.JoinedStr, ast.Constant)):
            found = py_template(node)
            if found is not None:
                inner.update(id(n) for n in ast.walk(node) if n is not node)
                yield found


# Never drawn: patterns, documentation, what goes into books, or fragments of a sentence the catalog has whole.
NOT_INTERFACE = re.compile(r'''^(\(\?:|\^\\s|\[|<|'中英|PKCE|The\ file\ label|Documents/Kindle|%\.1f|\.0 |\{\}（图片版\*|
    \{\}\{\}对照|\s*(小时|套餐)$|书会发给\ $|接收端可以升级：$|提示：|已改为发到$|正在下载$|。重试|然后运行：|目录$)''', re.X)


def normal(literal):
    return literal.replace('\\n', '\n').replace('\\"', '"').strip('\n')


def collect():
    found = set()
    for path in sorted((ROOT / 'mac-app/Sources').rglob('*.swift')):
        for literal in swift_literals(path.read_text()):
            if HAN.search(literal):
                found.add(literal)
    for path in sorted((ROOT / 'wifi-push').glob('*.py')):
        if path.name.startswith('test_') or path.name in SKIP_PY:
            continue
        for literal in py_strings(path.read_text()):
            if HAN.search(literal):
                found.add(literal)
    return sorted(k for k in map(normal, found) if not NOT_INTERFACE.match(k))


if __name__ == '__main__':
    json.dump(collect(), sys.stdout, ensure_ascii=False, indent=0)
