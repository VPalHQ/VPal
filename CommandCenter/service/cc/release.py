"""VPal's own updates (not the game's): is a newer VPal out, and installing it with one click from the control panel.

Each VPal release on VPal's GitHub page carries two files:
    vpal-update.json              the newest version, what's new, and the SHA-256 and size of the update zip
    VPal-update-<version>.zip     VPal's program files
Once a day (and when you click Check) the watchdog reads vpal-update.json. Nothing about you or your server is sent.
When you click Update in the control panel, the watchdog downloads the zip over https, checks its SHA-256 and size,
checks that it holds only VPal's own program files and that it really is the version announced, then waits until no
restart or backup is running and hands over to vpal_updater.py, which puts the files in and starts the watchdog again.
The Palworld server keeps running and nobody is disconnected.
"""
import os, sys, re, json, time, hashlib, threading, subprocess, urllib.request, urllib.error, urllib.parse
from . import util, procs

# Where VPal's releases are announced: the newest release on VPal's GitHub page.
FEED = 'https://github.com/VPalHQ/VPal/releases/latest/download/vpal-update.json'
SERVICE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))        # ...\CommandCenter\service
ROOT = os.path.dirname(util.CC_DIR)                                          # the VPal (server) folder
UPD = util.data('updates')
STATE = util.data('vpal-update.json')
CHECK_EVERY = 24 * 3600
RETRY_AFTER = 3600                     # after a failed check
MAX_ZIP = 150 * 2**20
BUSY_STATES = ('waiting', 'downloading', 'checking', 'installing')

_run = {'state': 'idle', 'got': 0, 'total': 0, 'error': '', 'to': ''}       # what this copy of the watchdog is doing
_lock = threading.Lock()


def feed_url():
    return os.environ.get('VPAL_UPDATE_FEED') or FEED


def ver(s):
    m = re.fullmatch(r'(\d{1,4})\.(\d{1,4})(?:\.(\d{1,4}))?(?:\.(\d{1,4}))?', str(s or '').strip())
    return tuple(int(x or 0) for x in m.groups()) if m else None


def _url_ok(u):
    p = urllib.parse.urlparse(str(u or ''))
    if p.scheme == 'https' and p.hostname: return True
    return p.scheme == 'http' and p.hostname in ('127.0.0.1', 'localhost')     # only for testing on this PC


class _Redirects(urllib.request.HTTPRedirectHandler):
    """GitHub sends downloads on to its file servers. A redirect to anything but https is refused."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not _url_ok(newurl): raise urllib.error.URLError('a download link that is not https was refused')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_opener = urllib.request.build_opener(_Redirects)


def _open(url, timeout):
    if not _url_ok(url): raise urllib.error.URLError('VPal only downloads updates over https')
    return _opener.open(urllib.request.Request(url, headers={'User-Agent': f'VPal/{util.VERSION}'}), timeout=timeout)


def _why(e):
    if isinstance(e, urllib.error.HTTPError): return f"VPal's page answered {e.code}"
    if isinstance(e, urllib.error.URLError): return f'could not reach it ({e.reason})'
    if isinstance(e, (TimeoutError, OSError)): return f'could not reach it ({e.__class__.__name__})'
    return str(e)


def load():
    return util.read_json(STATE, {}) or {}


def save(st):
    util.write_json(STATE, st)


def _clean(d):
    """The release announcement, checked. Raises ValueError."""
    bad = ValueError("the update information on VPal's page didn't make sense")
    if not isinstance(d, dict) or not ver(d.get('version')): raise bad
    z, sha, size = d.get('zip'), str(d.get('sha256') or '').lower(), d.get('size')
    if not _url_ok(z) or not re.fullmatch(r'[0-9a-f]{64}', sha) or not isinstance(size, int) or not 0 < size <= MAX_ZIP: raise bad
    notes = [str(n)[:300] for n in (d.get('notes') or []) if isinstance(n, str) and n.strip()][:12]
    out = {'version': str(d['version']).strip(), 'zip': z, 'sha256': sha, 'size': size, 'notes': notes,
           'date': str(d.get('date') or '')[:20]}
    if d.get('min_from') and ver(d['min_from']): out['min_from'] = str(d['min_from']).strip()
    if d.get('setup') and _url_ok(d['setup']): out['setup'] = str(d['setup'])
    return out


def due():
    if not feed_url() or _run['state'] in BUSY_STATES: return False
    st = load()
    t = time.time()
    return t - st.get('checked', 0) > CHECK_EVERY and t - st.get('tried', 0) > RETRY_AFTER


def check(force=False):
    """Reads the release announcement. Quick (one small file)."""
    url = feed_url()
    if not url or (not force and not due()): return public()
    st = load()
    st['tried'] = round(time.time())
    try:
        with _open(url, 20) as r:
            raw = r.read(65537)
        if len(raw) > 65536: raise ValueError("the update information on VPal's page is too big")
        st['latest'] = _clean(json.loads(raw.decode('utf-8-sig')))
        st['checked'] = st['tried']
        st['error'] = ''
    except urllib.error.HTTPError as e:
        if e.code == 404:                       # VPal's page has no release yet: nothing to install, not a problem
            st.pop('latest', None)
            st['checked'] = st['tried']
            st['error'] = ''
        else:
            st['error'] = 'The update check failed: ' + _why(e) + '.'
    except Exception as e:
        st['error'] = 'The update check failed: ' + _why(e) + '.'
    save(st)
    p = public()
    if p['available'] and st.get('told') != p['version']:
        st['told'] = p['version']
        save(st)
        util.event('service', f"VPal {p['version']} is out (you have {util.VERSION}). Update it from the control panel.", 'info')
    return p


def public():
    """What the control panel shows."""
    st = load()
    lt = st.get('latest') or {}
    cur = ver(util.VERSION) or (0,)
    avail = bool(lt and ver(lt.get('version')) and ver(lt['version']) > cur)
    setup = avail and lt.get('min_from') and cur < ver(lt['min_from'])
    return {'current': util.VERSION, 'feed': bool(feed_url()), 'checked': st.get('checked', 0), 'error': st.get('error', ''),
            'published': bool(lt), 'available': avail, 'version': lt.get('version', '') if avail else '', 'notes': lt.get('notes', []) if avail else [],
            'date': lt.get('date', '') if avail else '', 'size': lt.get('size', 0) if avail else 0,
            'needsSetup': bool(setup), 'setup': lt.get('setup', '') if setup else '',
            'state': _run['state'], 'got': _run['got'], 'total': _run['total'], 'jobError': _run['error'],
            'result': st.get('result')}


def note_result():
    """When the watchdog starts: records how the last update went (the updater leaves result.json)."""
    p = os.path.join(UPD, 'result.json')
    r = util.read_json(p, None)
    if not r: return
    try: os.remove(p)
    except OSError: pass
    st = load()
    st['result'] = r
    save(st)
    if r.get('ok'):
        util.event('service', f"VPal updated from {r.get('from')} to {r.get('to')} ({r.get('changed', 0)} files updated, "
                              f"{r.get('added', 0)} added).", 'good')
    else:
        util.event('error', r.get('error') or 'The VPal update was not installed.', 'bad')


# ---------------- installing ----------------
def start(svc):
    """Starts an update (the control panel's Update button). Returns at once; the panel follows it with public()."""
    with _lock:
        if _run['state'] in BUSY_STATES: raise RuntimeError('VPal is already updating.')
        p = public()
        if not p['available']: raise RuntimeError(f'VPal {util.VERSION} is the newest version.')
        if p['needsSetup']: raise RuntimeError(f"VPal {p['version']} can't be installed from the control panel. "
                                               "Download VPal-Setup.exe from VPal's page and run it; it keeps your server, worlds and settings.")
        lt = load()['latest']
        _run.update(state='downloading', got=0, total=lt['size'], error='', to=lt['version'])
        st = load()
        st.pop('result', None)
        save(st)
    threading.Thread(target=_install, args=(svc, lt), daemon=True).start()
    return public()


def _download(lt, path):
    h = hashlib.sha256()
    got = 0
    with _open(lt['zip'], 60) as r, open(path + '.part', 'wb') as f:
        while True:
            b = r.read(1 << 16)
            if not b: break
            got += len(b)
            if got > lt['size']: raise ValueError('the download is bigger than announced')
            h.update(b)
            f.write(b)
            _run['got'] = got
    if got != lt['size']: raise ValueError('the download was cut off')
    if h.hexdigest() != lt['sha256']: raise ValueError("the download doesn't match the fingerprint on VPal's page")
    os.replace(path + '.part', path)


def _install(svc, lt):
    zp = os.path.join(UPD, f"VPal-update-{lt['version']}.zip")
    try:
        sys.path.insert(0, SERVICE)
        import vpal_updater as vu
        os.makedirs(UPD, exist_ok=True)
        try:
            _download(lt, zp)
        except Exception as e:
            raise RuntimeError(_why(e))
        _run['state'] = 'checking'
        try:
            vu.plan(zp)
            zv = vu.zip_version(zp)
            if zv != lt['version']: raise vu.Refused(f"the zip holds version {zv or 'unknown'}, not {lt['version']}")
        except vu.Refused as e:
            raise RuntimeError(str(e))
        # never in the middle of a restart, a restore or a backup
        _run['state'] = 'waiting'
        t0 = time.time()
        while svc.busy() or svc.bg:
            if time.time() - t0 > 1800: raise RuntimeError('the watchdog stayed busy for half an hour. Try again later')
            time.sleep(1)
        _run['state'] = 'installing'
        updater = os.path.join(UPD, 'vpal_updater.py')                 # runs from here, so nothing it replaces is in use
        with open(os.path.join(SERVICE, 'vpal_updater.py'), 'rb') as a, open(updater, 'wb') as b:
            b.write(a.read())
        job = {'zip': zp, 'root': ROOT, 'updates': UPD, 'from': util.VERSION, 'to': lt['version'], 'pid': os.getpid(),
               'restart': [sys.executable, os.path.join(SERVICE, 'ccservice.py')]}
        jp = os.path.join(UPD, 'job.json')
        util.write_json(jp, job)
        util.event('service', f"Installing VPal {lt['version']}. The watchdog is back in about a minute; the server keeps running.", 'info')
        kw = {'creationflags': procs.NO_WINDOW | 0x00000008 | 0x00000200} if util.IS_WIN else {'start_new_session': True}
        subprocess.Popen([sys.executable, '-I', updater, jp], cwd=UPD, close_fds=True, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kw)
        try: svc.tracker.save()
        except Exception: pass
        time.sleep(1.5)                                               # long enough for the control panel to see 'installing'
        os._exit(0)
    except Exception as e:
        _run.update(state='failed', error=f"VPal {lt['version']} wasn't installed: {e}. Nothing was changed.")
        util.event('error', _run['error'], 'warn')
        for f in (zp, zp + '.part'):
            try: os.remove(f)
            except OSError: pass
