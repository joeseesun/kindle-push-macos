"""What this app keeps on the Mac, and clearing the parts that can safely go."""
import json
import shutil
from pathlib import Path

import kindle_push as kp
import translation as tr

COVERS = kp.DATA / 'covers'
# All a finished job needs to keep answering "already translated" while its book exists.
KEEP = {'state.json', 'request.json', 'lock'}


def size_of(path):
    if not path.exists():
        return 0
    if path.is_file():
        return path.stat().st_size
    return sum(p.stat().st_size for p in path.rglob('*') if p.is_file() and not p.is_symlink())


def jobs():
    """(folder, state) of each translation job, unreadable ones counted as interrupted."""
    if not tr.JOBS.is_dir():
        return
    for folder in tr.JOBS.iterdir():
        if folder.is_dir():
            try:
                yield folder, tr.progress(folder.name).get('state', 'failed')
            except (OSError, ValueError, KeyError):
                yield folder, 'failed'


def working_files(folder):
    return [path for path in folder.iterdir() if path.name not in KEEP]


def running():
    return any(state in {'queued', 'running'} for _, state in jobs())


def usage():
    done = [folder for folder, state in jobs() if state == 'done' and working_files(folder)]
    return {'ok': True,
            'jobsBytes': sum(size_of(path) for folder in done for path in working_files(folder)), 'jobs': len(done),
            'coversBytes': size_of(COVERS),
            'runtimeBytes': size_of(tr.RUNTIME),
            'outputBytes': size_of(kp.OUT), 'outputPath': str(kp.OUT),
            'running': running()}


def clean(what, keep=()):
    """Unfinished jobs always stay: their checkpoints are translation already paid for. A finished
    job loses its working files only, so a book waiting to be sent is not translated a second time.
    The books in the output folder are the user's and are never touched."""
    if what == 'jobs':
        for folder, state in list(jobs()):
            if state == 'done':
                for path in working_files(folder):
                    shutil.rmtree(path) if path.is_dir() else path.unlink(missing_ok=True)
    elif what == 'covers':
        wanted = {str(Path(path)) for path in keep}
        if COVERS.is_dir():
            for path in COVERS.iterdir():
                if str(path) not in wanted:
                    path.unlink(missing_ok=True)
    elif what == 'runtime':
        if running():
            raise ValueError('还有书在翻译，等它结束后再卸载翻译组件。')
        shutil.rmtree(tr.RUNTIME, ignore_errors=True)
    else:
        raise ValueError('未知的清理项。')
    return usage()


def request(args, stdin):
    if args[0] == 'data-usage':
        return usage()
    return clean(args[1], json.loads(stdin or '{}').get('keep', ()))
