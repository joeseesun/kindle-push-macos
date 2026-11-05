"""Private, resumable bilingual_book_maker jobs. No book or key enters argv."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
from urllib.parse import urlsplit

import kindle_push as kp
import chunks
import languages as lang
import names
import polish
import terms

VERSION = '1.3.2'
DATA = kp.DATA
RUNTIME = DATA / 'translation-runtime'
SETTINGS = DATA / 'translation.json'
JOBS = DATA / 'translations'
KEY_SERVICE = 'local.chase.KindlePush.translation'
MAX_WORKERS = 64
DEFAULT_WORKERS = 16
# Small models drop paragraphs from big batches, and a misaligned batch is split and sent again.
SMALL_MODEL = re.compile(r'flash|mini|nano|lite|small|haiku|turbo|[^0-9][1-9]b\b|[^0-9]1[0-4]b\b', re.I)
SMALL_BATCH = 10
TEMPERATURE = '0.3'
# The engine waits 300 s for a reply; some gateways now and then accept a request and never
# answer, which held whole books for minutes. Cloud replies to one batch come in well under these.
# Runs the engine's own entry point with that one limit changed; anything unexpected runs it as is.
LAUNCH = ('import sys\n'
          'try:\n'
          '    import book_maker.translator.chatgptapi_translator as c\n'
          '    c.REQUEST_LIMITS["timeout"] = float(sys.argv.pop(1))\n'
          'except Exception:\n'
          '    sys.argv.pop(1)\n'
          'from book_maker.cli import main\n'
          'sys.argv[0] = "bbook_maker"\n'
          'sys.exit(main())\n')


def request_timeout(config):
    if config.get('provider') == 'chatgpt' or is_local(config.get('base', '')):
        return 300
    return 60 if SMALL_MODEL.search(config.get('model', '')) else 150
ENGINE_PROMPT = 'Please help me to translate,`{text}` to {language}, please return only translated content not include the origin text'
# Every style keeps these; they stop the usual ways a model shortens or edits a book.
RULES = '完整翻译每一句，不省略、不概括；不纠正原文里的错误；不回避或删改敏感内容；不加解释或译注；保持原文的段落划分。'
# System messages layered on the engine's own user template.
STYLES = {
    'natural': '你是专业的图书译者。把原文译成自然、地道的简体中文：忠实完整，不增删信息；按中文习惯调整语序，避免翻译腔；人名、地名和术语前后统一；保留原文的语气和段落结构。',
    'faithful': '你是资深译者。把原文准确、完整地译成简体中文：不增删信息，保留原文的逻辑层次与语气，专有名词前后统一。',
    'literary': '你是文学翻译家。把原文译成地道、流畅、有文采的简体中文：保留作者的语气、修辞和人物口吻，避免翻译腔，但不改写情节与信息。',
    'technical': '你是技术与学术翻译专家。把原文译成严谨、易读的简体中文：术语准确且前后统一，首次出现的专业术语在译名后用括号保留英文原词，代码、公式、命令保持原样。',
}
# The same styles for any other target language; {language} is its English name.
RULES_OTHER = ('Translate every sentence in full: never omit or summarise, never correct errors in the original, '
               'never soften or cut sensitive content, add no explanations or translator notes, and keep the '
               'original paragraph breaks.')
STYLES_OTHER = {
    'natural': 'You are a professional book translator. Translate into natural, idiomatic {language}: faithful and '
               'complete, with word order adapted to {language} so it never reads like a translation; keep names and '
               'terms consistent, and keep the tone and paragraph structure of the original.',
    'faithful': 'You are a senior translator. Translate accurately and completely into {language}: add or drop '
                'nothing, keep the logical structure and tone of the original, and keep proper names consistent.',
    'literary': 'You are a literary translator. Translate into fluent, idiomatic and elegant {language}: keep the '
                "author's voice, rhetoric and each character's way of speaking, without rewriting plot or facts.",
    'technical': 'You are a technical and academic translator. Translate into rigorous, readable {language}: terms '
                 'accurate and consistent, the original term kept in parentheses after its first translation, and '
                 'code, formulas and commands left as they are.',
}


def system_prompt(style, goal, title='', author=''):
    """The system message: which book, how to translate it, and the rules every style keeps."""
    if lang.target(goal) == 'zh':
        book = f'正在翻译的书：《{title}》' + (f'，作者 {author}' if author else '') + '。' if title else ''
        return book + STYLES.get(style, STYLES['natural']) + RULES
    language = lang.TARGETS[lang.target(goal)][3]
    book = f'The book being translated: "{title}"' + (f' by {author}' if author else '') + '. ' if title else ''
    return book + STYLES_OTHER.get(style, STYLES_OTHER['natural']).format(language=language) + ' ' + RULES_OTHER


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False))
    temp.chmod(0o600)
    temp.replace(path)


def endpoint(value):
    value = value.strip().rstrip('/')
    parts = urlsplit(value)
    if parts.username or parts.password or parts.query or parts.fragment or not parts.hostname:
        raise ValueError('服务地址不能包含密码、查询参数或片段。')
    if parts.scheme != 'https' and not (parts.scheme == 'http' and parts.hostname in {'localhost', '127.0.0.1', '::1'}):
        raise ValueError('云端服务必须使用 HTTPS；本机服务可以使用 HTTP。')
    return value


def own_account(base):
    return hashlib.sha256(base.encode()).hexdigest()


def settings():
    if SETTINGS.exists():
        config = json.loads(SETTINGS.read_text())
        # Before 1.12 the choice was 1–4 chapters, 3 recommended and 4 fastest; both mean "fast" now.
        if config.get('workers') in (3, 4) and not config.get('partsEra'):
            config['workers'] = DEFAULT_WORKERS
        return config
    # Reuse only the named, non-secret Flash route, with its existing Keychain item.
    registry = Path.home() / '.config/qiaomu-llm/registry.json'
    if registry.exists():
        route = json.loads(registry.read_text()).get('providers', {}).get('magpie-openai', {})
        ref = route.get('secret_ref', '')
        if not route.get('disabled') and ref.startswith('keychain:') and '/' in ref[9:]:
            service, account = ref[9:].split('/', 1)
            return {'base': endpoint(route['base_url']), 'model': 'deepseek/deepseek-flash',
                    'service': service, 'account': account}
    base = 'https://api.deepseek.com/v1'
    return {'base': base, 'model': 'deepseek-flash', 'service': KEY_SERVICE, 'account': own_account(base)}


def public_settings():
    config = settings()
    return {'ok': True, 'base': config['base'], 'model': config['model'], 'provider': config.get('provider', ''),
            'hasKey': has_key(config),
            'workers': config.get('workers', DEFAULT_WORKERS), 'style': config.get('style', 'natural'),
            'glossary': config.get('glossary', ''),
            'runtimeReady': (RUNTIME / 'bin/bbook_maker').is_file()}


def glossary_lines(text):
    lines = [line.strip() for line in text.replace('\r', '').split('\n')]
    lines = [line for line in lines if line]
    for line in lines:
        if not line.startswith('#') and '->' not in line:
            raise ValueError('术语表每行写成「原文 -> 译名」：' + line[:40])
    if len(lines) > 500:
        raise ValueError('术语表最多 500 行。')
    return '\n'.join(lines)


def is_local(base):
    return urlsplit(base).hostname in {'localhost', '127.0.0.1', '::1'}


def has_key(config):
    if config.get('provider') == 'chatgpt' or not config.get('service'):
        return False
    probe = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', config['service'],
                            '-a', config['account']], capture_output=True)
    return probe.returncode == 0


def save_settings(base, model, workers=None, style=None, glossary=None, provider=''):
    chatgpt = provider == 'chatgpt'
    base = '' if chatgpt else endpoint(base)
    model = model.strip()
    if not model or len(model) > 200:
        raise ValueError('请选择或填写模型。')
    if provider and not re.fullmatch(r'[a-z0-9-]{1,40}', provider):
        raise ValueError('未知的翻译服务。')
    old = settings()
    config = {'provider': provider, 'base': base, 'model': model,
              'service': '' if chatgpt else KEY_SERVICE, 'account': '' if chatgpt else own_account(base),
              'workers': old.get('workers', DEFAULT_WORKERS), 'style': old.get('style', 'natural'),
              'glossary': old.get('glossary', ''), 'partsEra': True}
    if workers is not None:
        if not str(workers).isdigit() or not 1 <= int(workers) <= MAX_WORKERS:
            raise ValueError(f'同时翻译数应为 1–{MAX_WORKERS}。')
        config['workers'] = int(workers)
    if style is not None:
        if style not in STYLES:
            raise ValueError('未知的译文风格。')
        config['style'] = style
    if glossary is not None:
        config['glossary'] = glossary_lines(glossary)
    # Preserve a borrowed credential only for its original address and when no app key exists.
    probe = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', KEY_SERVICE,
                            '-a', own_account(base)], capture_output=True) if not chatgpt else None
    if not chatgpt and probe.returncode and base == old['base'] and old.get('service'):
        config.update(service=old['service'], account=old['account'])
    atomic_json(SETTINGS, config)
    return public_settings()


def read_key(config):
    if is_local(config.get('base', '')) and not has_key(config):
        return 'local'   # Ollama and LM Studio ignore the key, but the engine wants one.
    result = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', config['service'],
                             '-a', config['account'], '-w'], capture_output=True, text=True)
    if result.returncode or not result.stdout.strip():
        raise ValueError('无法读取翻译 API Key，请在翻译设置中保存，或解锁 macOS 钥匙串。')
    return result.stdout.rstrip('\n')


def install():
    DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
    log = DATA / 'translation-install.log'
    with log.open('w') as out:
        log.chmod(0o600)
        subprocess.run([sys.executable, '-m', 'venv', str(RUNTIME)], check=True, stdout=out, stderr=out, timeout=60)
        result = subprocess.run([str(RUNTIME / 'bin/python3'), '-m', 'pip', 'install',
                                 'bbook_maker==' + VERSION], stdout=out, stderr=out, timeout=600)
    if result.returncode:
        raise ValueError('翻译组件安装失败，请检查网络后重试。原有传书不受影响。')
    return public_settings()


def job_dir(job):
    if not re.fullmatch('[0-9a-f]{24}', job):
        raise ValueError('无效的翻译任务。')
    return JOBS / job


def process_alive(state):
    pid = state.get('pid')
    if not pid:
        return False
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart='], capture_output=True, text=True)
    return result.returncode == 0 and result.stdout.strip() == state.get('birth')


def remaining_seconds(text):
    parts = text.split(':')
    if not all(p.isdigit() for p in parts) or not 1 <= len(parts) <= 3:
        return None
    seconds = 0
    for part in parts:
        seconds = seconds * 60 + int(part)
    return seconds


def remaining_text(seconds):
    if seconds < 90:
        return '马上完成'
    if seconds < 3600:
        return f'还剩约 {round(seconds / 60)} 分钟'
    hours = seconds / 3600
    return f'还剩约 {hours:.1f} 小时'.replace('.0 小时', ' 小时')


def progress(job):
    folder = job_dir(job)
    state = json.loads((folder / 'state.json').read_text())
    if state['state'] in {'queued', 'running'} and not process_alive(state):
        state.update(state='failed', message='翻译已中断。再次点击可从已保存的进度继续。')
    if state['state'] == 'running':
        log = folder / 'engine.log'
        if log.exists():
            with log.open('rb') as file:
                file.seek(max(0, log.stat().st_size - 8192))
                matches = re.findall(rb'(\d{1,3})%\|[^\[\n\r]*\[[0-9:]+<([0-9:]+|\?)', file.read())
            if matches:
                percent = min(99, int(matches[-1][0]))
                state['percent'] = percent
                state['message'] = '正在翻译 · ' + str(percent) + '%'
                left = remaining_seconds(matches[-1][1].decode())
                if left is not None:
                    state['remaining'] = left
                    state['message'] += ' · ' + remaining_text(left)
    return {'ok': state['state'] != 'failed', 'job': job, **state}


MODES = ('bilingual', 'target-only')   # side by side, or the translation alone (--single_translate)


def mode_of(value):
    """'chinese' is what 1.13 called a translation alone."""
    return 'target-only' if value == 'chinese' else value


def job_id(digest, config, preview, mode='bilingual', goal='zh'):
    # Speed does not change the translation, so a run can resume at another worker count.
    # 'provider' only matters for the ChatGPT route; elsewhere base and model already identify the service.
    quality = {k: v for k, v in config.items() if k not in {'workers', 'partsEra'} and (k not in {'style', 'glossary', 'provider'} or v not in {'', 'natural'})
               and not (k == 'provider' and v != 'chatgpt')}
    # Bilingual identities predate modes, and Chinese ones predate target languages; both stay as
    # they were, so their checkpoints still resume. Every other target is part of the identity.
    mode = mode_of(mode)
    parts = [digest, quality, preview, VERSION, 'pipeline-2'] + ([] if mode == 'bilingual' else ['chinese'] if goal == 'zh' else [mode])
    if lang.target(goal) != 'zh':
        parts.append('target:' + lang.target(goal))
    identity = json.dumps(parts, sort_keys=True).encode()
    return hashlib.sha256(identity).hexdigest()[:24]


def find(source, goal='zh'):
    """The whole-book job this EPUB already has under the current settings, without starting one."""
    source = Path(source).expanduser().resolve(strict=True)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    found = {'ok': True, 'state': 'none'}
    for mode in MODES:
        job = job_id(digest, settings(), False, mode, goal)
        if not (job_dir(job) / 'state.json').exists():
            continue
        state = progress(job)
        if state.get('state') == 'done' and not Path(state.get('output', '')).is_file():
            continue
        state = {**state, 'ok': True, 'mode': mode, 'target': goal}
        # A running job wins; otherwise the first one with a result.
        if state['state'] in {'queued', 'running'}:
            return state
        if found['state'] == 'none':
            found = state
    return found


def start(source, preview=False, mode='bilingual', goal='zh'):
    mode = mode_of(mode)
    if mode not in MODES:
        raise ValueError('未知的译文版本。')
    if goal not in lang.TARGETS:
        raise ValueError('不支持的目标语言。')
    source = Path(source).expanduser().resolve(strict=True)
    if source.suffix.lower() != '.epub':
        raise ValueError('翻译仅支持 EPUB。其他格式可以直接发送。')
    if source.stat().st_size > 100 * 1024 * 1024:
        raise ValueError('EPUB 超过 100 MB，请先缩小图片。')
    kp.validate_epub(source)
    if not (RUNTIME / 'bin/bbook_maker').is_file():
        raise ValueError('请先打开翻译设置，安装翻译组件。')
    config = settings()
    if config.get('provider') == 'chatgpt':
        import accounts
        if not accounts.codex_binary():
            raise ValueError('用 ChatGPT 翻译需要先安装 Codex 命令行工具，并在翻译设置里登录。')
    else:
        # Check before starting a background job; never persist or pass the secret.
        read_key(config)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    job = job_id(digest, config, preview, mode, goal)
    folder = job_dir(job)
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (folder / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if (folder / 'state.json').exists():
            state = progress(job)
            if state['state'] in {'queued', 'running'}:
                return state
            if state['state'] == 'done' and Path(state.get('output', '')).is_file():
                kp.validate_epub(Path(state['output']))
                if hashlib.sha256(Path(state['output']).read_bytes()).hexdigest() == state.get('sha256'):
                    return state
        snapshot = folder / 'book.epub'
        if not snapshot.exists():
            shutil.copyfile(source, snapshot)
            snapshot.chmod(0o600)
        if hashlib.sha256(snapshot.read_bytes()).hexdigest() != digest:
            raise ValueError('任务副本校验失败，原书未修改。')
        (folder / 'cancel').unlink(missing_ok=True)
        atomic_json(folder / 'request.json', {'config': config, 'preview': preview, 'mode': mode, 'target': goal,
                                                  'source': lang.detect(source), 'title': source.stem})
        with (folder / 'worker.log').open('a') as log:
            child = subprocess.Popen([sys.executable, '-B', str(Path(__file__).resolve()), 'worker', job],
                                     stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        birth = subprocess.run(['/bin/ps', '-p', str(child.pid), '-o', 'lstart='], capture_output=True, text=True).stdout.strip()
        atomic_json(folder / 'state.json', {'state': 'queued', 'pid': child.pid, 'birth': birth,
                                           'message': '正在准备翻译…'})
    return {'ok': True, 'job': job, 'state': 'queued', 'message': '正在准备翻译…'}


def cancel(job):
    folder = job_dir(job)
    (folder / 'cancel').touch(mode=0o600)
    return {'ok': True, 'job': job, 'message': '正在停止，保留已完成进度…'}


def command(folder, config, preview, mode='bilingual', goal='zh'):
    codex = config.get('provider') == 'chatgpt'
    book_file = engine_book(folder)
    args = [str(RUNTIME / 'bin/python3'), '-c', LAUNCH, str(request_timeout(config)),
            '--book_name', str(book_file), '--language', lang.TARGETS[lang.target(goal)][0]]
    args += (['--api_format', 'codex', '--model', config['model']] if codex else
             ['--api_format', 'openai', '--api_base', config['base'], '--model', config['model'], '--no-thinking'])
    if (folder / f'.{book_file.stem}.temp.bin').is_file():
        args += ['--resume']
    # Every request knows which book it is in: parallel chapters never see each other.
    title, author = terms.book_meta(folder / 'book.epub')
    system = system_prompt(config.get('style', 'natural'), goal, title, author)
    (folder / 'prompt.json').write_text(json.dumps({'user': ENGINE_PROMPT, 'system': system}, ensure_ascii=False))
    args += ['--prompt', str(folder / 'prompt.json')]
    auto = folder / 'glossary-auto.txt'
    glossary = terms.merge(config.get('glossary', ''), auto.read_text().splitlines() if auto.is_file() else [])
    if glossary:
        (folder / 'glossary.txt').write_text(glossary + '\n')
        args += ['--glossary', str(folder / 'glossary.txt')]
    if not codex:
        args += ['--temperature', TEMPERATURE]
        if SMALL_MODEL.search(config['model']):
            args += ['--max-batch-units', str(SMALL_BATCH)]
    if mode_of(mode) == 'target-only':
        args += ['--single_translate']
    if preview:
        args += ['--translate-tags', 'p', '--test', '--test_num', '3']
    else:
        args += ['--plan-classify', 'all'] + ([] if codex else ['--use_context', 'window'])
        workers = 1 if codex else config.get('workers', DEFAULT_WORKERS)
        if workers > 1:
            args += ['--parallel-workers', str(workers)]
    return args


def engine_book(folder):
    """What the engine translates: the book with long chapters cut into parts, when it was cut."""
    return folder / ('book-split.epub' if (folder / 'book-split.epub').is_file() else 'book.epub')


def prepare_parts(folder, config, preview):
    """Cut long chapters once per job, so every worker has work; a job begun without parts keeps none."""
    plan_file = folder / 'split.json'
    if preview or config.get('provider') == 'chatgpt' or plan_file.exists() or (folder / '.book.temp.bin').exists():
        return
    try:
        plan = chunks.split(folder / 'book.epub', folder / 'book-split.epub', int(config.get('workers', DEFAULT_WORKERS)))
    except Exception:
        plan = None
    if not plan:
        (folder / 'book-split.epub').unlink(missing_ok=True)
    chunks.save_plan(plan_file, plan or {})


def finish_parts(folder, raw, result, goal='zh'):
    """Join translated parts back into whole chapters, then tidy Chinese punctuation (Chinese only)."""
    plan_file = folder / 'split.json'
    plan = json.loads(plan_file.read_text()) if plan_file.is_file() else {}
    if plan.get('chapters'):
        chunks.join(raw, result, plan)
    elif raw != result:
        shutil.copyfile(raw, result)
    if lang.chinese(goal):
        polish.epub(result)


def worker(job):
    os.umask(0o077)
    folder = job_dir(job)
    # Parent releases this after recording PID and birth time.
    with (folder / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads((folder / 'state.json').read_text())
    child = None
    try:
        request = json.loads((folder / 'request.json').read_text())
        config = request['config']
        goal = lang.target(request.get('target', 'zh'))
        mode = mode_of(request.get('mode', 'bilingual'))
        env = {k: v for k, v in os.environ.items() if not any(s in k.upper() for s in ('API_KEY', 'TOKEN', 'SECRET'))}
        if config.get('provider') == 'chatgpt':
            import accounts
            env['PATH'] = accounts.codex_env()['PATH']
        else:
            env['BBM_API_KEY'] = read_key(config)
        env.update(PYTHONUNBUFFERED='1', PYTHONIOENCODING='utf-8')
        auto = folder / 'glossary-auto.txt'
        if not request['preview'] and 'BBM_API_KEY' in env and not auto.exists():
            state.update(state='running', message='正在整理书中的人名和术语…')
            atomic_json(folder / 'state.json', state)
            lines = terms.build(folder / 'book.epub', config['base'], config['model'], env['BBM_API_KEY'], goal)
            auto.write_text('\n'.join(lines) + ('\n' if lines else ''))
            auto.chmod(0o600)
        state.update(state='running', message='正在翻译，首次分析可能需要几分钟…')
        atomic_json(folder / 'state.json', state)
        prepare_parts(folder, config, request['preview'])
        # A previous failed run must never leave a stale final book eligible for delivery.
        result = folder / 'book_bilingual.epub'
        raw = folder / f'{engine_book(folder).stem}_bilingual.epub'
        result.unlink(missing_ok=True)
        raw.unlink(missing_ok=True)
        with (folder / 'engine.log').open('w') as log:
            child = subprocess.Popen(command(folder, config, request['preview'], mode, goal), cwd=folder,
                                     env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                     start_new_session=True)
            env.pop('BBM_API_KEY', None)
            deadline = time.monotonic() + 24 * 3600
            while child.poll() is None:
                if (folder / 'cancel').exists() or time.monotonic() > deadline:
                    os.killpg(child.pid, signal.SIGINT)
                    try:
                        child.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGTERM)
                        child.wait(timeout=10)
                    state.update(state='cancelled', message='翻译已停止，再次开始会继续已保存的进度。')
                    atomic_json(folder / 'state.json', state)
                    return
                time.sleep(0.5)
        if child.returncode or not raw.is_file():
            raise ValueError('翻译未完成，请检查模型设置、余额和网络后重试；已完成的进度会保留。')
        finish_parts(folder, raw, result, goal)
        kp.validate_epub(result)
        kp.OUT.mkdir(parents=True, exist_ok=True)
        title = names.tidy(request['title'], smart=False)[:60].strip() or '书籍'
        alone = mode == 'target-only'
        name = lang.TARGETS[goal][1]
        label = ('试译3段' if request['preview'] else lang.only_label(goal) if alone
                 else lang.pair_label(request.get('source', ''), goal))
        if request['preview'] and goal != 'zh':
            label = f'{lang.only_label(goal) if alone else lang.pair_label(request.get("source", ""), goal)}·试译3段'
        output = names.unique_output(kp.OUT, f'{title}（{label}）', '.epub', job)
        temp = output.with_suffix('.tmp')
        shutil.copyfile(result, temp)
        temp.chmod(0o600)
        temp.replace(output)
        state.update(state='done', message='试译完成，可先检查译文。' if request['preview'] else f'{name}版已生成。' if alone else f'{label}版已生成。',
                     output=str(output), sha256=hashlib.sha256(output.read_bytes()).hexdigest())
    except Exception as error:
        # No raw provider response, book contents or secret in UI/state files.
        message = str(error) if isinstance(error, ValueError) else '翻译组件运行失败，请检查设置后继续。'
        state.update(state='failed', message=message)
    finally:
        if child and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
        atomic_json(folder / 'state.json', state)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'worker':
        worker(sys.argv[2])
