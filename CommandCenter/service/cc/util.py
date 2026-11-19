"""Shared helpers: where things live, small JSON files written safely, the event log and the metrics history."""
import os, sys, json, time, threading, collections

CC_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))   # ...\CommandCenter
DATA = os.path.join(CC_DIR, 'data')
WEB = os.path.join(CC_DIR, 'web')
IS_WIN = os.name == 'nt'
PORT = 18770                      # this PC only (127.0.0.1)
VERSION = '0.5.2'

os.makedirs(DATA, exist_ok=True)
_lock = threading.RLock()


def read_json(path, default=None):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, obj):
    """Writes to a temp file first so a crash never leaves half a file."""
    tmp = path + '.tmp'
    with _lock:
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(obj, f, indent=1, ensure_ascii=False)
        os.replace(tmp, path)


def data(name):
    return os.path.join(DATA, name)


def now():
    return time.time()


def stamp(t=None):
    return time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(t or time.time()))


def nice(t=None):
    """'Tue 1:05 PM' style, for people."""
    s = time.strftime('%a %I:%M %p', time.localtime(t or time.time()))
    return s.replace(' 0', ' ')


# ---------------- event log (what happened, newest last) ----------------
EVENTS = data('events.jsonl')
_recent = collections.deque(maxlen=400)


def _load_recent():
    try:
        with open(EVENTS, encoding='utf-8') as f:
            for line in f.readlines()[-400:]:
                try: _recent.append(json.loads(line))
                except ValueError: pass
    except OSError:
        pass


_load_recent()


LISTENERS = []      # things that want to hear about events (the Discord alerts)


def event(kind, text, level='info', **extra):
    """kind: crash, freeze, memory, restart, start, stop, update, backup, restore, kick, ban, unban, whitelist,
    join, leave, levelup, schedule, service, error.  level: info, good, warn, bad."""
    e = {'t': round(time.time()), 'kind': kind, 'level': level, 'text': text}
    e.update(extra)
    with _lock:
        _recent.append(e)
        try:
            with open(EVENTS, 'a', encoding='utf-8') as f:
                f.write(json.dumps(e, ensure_ascii=False) + '\n')
        except OSError:
            pass
    for fn in LISTENERS:
        try: fn(e)
        except Exception: pass
    return e


def recent_events(limit=100, kinds=None):
    with _lock:
        out = [e for e in _recent if not kinds or e['kind'] in kinds]
    return out[-limit:]


def trim_file(path, keep_lines):
    try:
        with open(path, encoding='utf-8') as f:
            lines = f.readlines()
        if len(lines) > keep_lines:
            with open(path + '.tmp', 'w', encoding='utf-8') as f:
                f.writelines(lines[-keep_lines:])
            os.replace(path + '.tmp', path)
    except OSError:
        pass


# ---------------- metrics history (one row a minute: fps, players, memory) ----------------
METRICS = data('metrics.jsonl')


def add_metric(row):
    with _lock:
        try:
            with open(METRICS, 'a', encoding='utf-8') as f:
                f.write(json.dumps(row) + '\n')
        except OSError:
            pass


def metrics_since(seconds):
    cut = time.time() - seconds
    out = []
    try:
        with open(METRICS, encoding='utf-8') as f:
            for line in f:
                try:
                    r = json.loads(line)
                    if r.get('t', 0) >= cut: out.append(r)
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def log_error(where, exc):
    event('error', f'{where}: {exc}', 'warn')
