"""The Pal Planner from the Command Center: its status, the family's players and codes, invites, refreshing it, its
automatic refresh and the family link (Tailscale Funnel). Mirrors the control panel's Pal Planner tab, same files."""
import os, sys, json, time, secrets, subprocess, threading, re, socket
import psutil
from . import util, config, procs

WORDS = ('amber otter cedar comet maple falcon harbor ember willow lunar canyon pepper river summit tiger violet meadow copper orbit '
         'sparrow thunder jade glacier cobalt saffron juniper raven coral birch nova acorn badger breeze cactus cliff clover crystal dune '
         'echo fern forest frost galaxy garnet hazel island ivy lagoon lantern lotus marble mesa mint moss oak ocean opal panda pebble pine '
         'prairie quartz reef ridge robin sage shadow silver spruce storm sunset tundra valley wave wren zephyr').split()
TASK = 'Pal Planner refresh'
OLD_TASK = 'Vega Pal Planner refresh'          # the name older versions used; kept where it already exists
_task = []


def task_name():
    if not _task:
        name = TASK
        if util.IS_WIN:
            try:
                r = subprocess.run(['schtasks', '/Query', '/TN', OLD_TASK], capture_output=True, timeout=20, creationflags=procs.NO_WINDOW)
                if r.returncode == 0: name = OLD_TASK
            except (OSError, subprocess.SubprocessError):
                pass
        _task.append(name)
    return _task[0]
WEB_PORT = 18765
_busy = threading.Lock()


def pdir(sd): return os.path.join(sd, 'PalPlanner')
def engine(sd): return os.path.join(pdir(sd), 'engine', 'palplanner.py')
def installed(sd): return os.path.isfile(engine(sd))


def python_exe():
    """The Python running the Command Center (pythonw on Windows) also runs the planner."""
    exe = sys.executable
    if util.IS_WIN and exe.lower().endswith('python.exe'):
        w = exe[:-10] + 'pythonw.exe'
        if os.path.isfile(w): exe = w
    return exe


def read_status(sd):
    return util.read_json(os.path.join(pdir(sd), 'status.json'), None)


def read_players(sd):
    j = util.read_json(os.path.join(pdir(sd), 'players.json'), {}) or {}
    return [p for p in (j.get('players') or []) if p]


def write_players(sd, players):
    keep = ('real', 'game', 'uid', 'code', 'phone', 'email', 'invited')
    util.write_json(os.path.join(pdir(sd), 'players.json'), {'players': [{k: str(p.get(k) or '') for k in keep} for p in players]})


def new_code(players):
    used = {p.get('code') for p in players}
    while True:
        c = f'{secrets.choice(WORDS)}-{secrets.choice(WORDS)}-{10 + secrets.randbelow(90)}'
        if c not in used: return c


def web_running():
    s = socket.socket(); s.settimeout(0.4)
    try: return s.connect_ex(('127.0.0.1', WEB_PORT)) == 0
    finally: s.close()


def run_engine(sd, cmd, timeout=600):
    """Runs the planner engine (refresh, lock). Returns its status.json afterwards."""
    if not installed(sd): raise RuntimeError('The Pal Planner is not installed in ' + pdir(sd))
    with _busy:
        r = subprocess.run([python_exe(), engine(sd), cmd], cwd=os.path.dirname(engine(sd)), capture_output=True, text=True,
                           timeout=timeout, creationflags=procs.NO_WINDOW, errors='replace')
    return read_status(sd)


# ---------------- Tailscale (the family link) ----------------
def tailscale_exe():
    if os.environ.get('CC_TAILSCALE'): return os.environ['CC_TAILSCALE']          # tests
    if util.IS_WIN:
        p = os.path.join(os.environ.get('ProgramFiles', r'C:\Program Files'), 'Tailscale', 'tailscale.exe')
        return p if os.path.isfile(p) else ''
    for d in ('/usr/bin/tailscale', '/usr/local/bin/tailscale'):
        if os.path.isfile(d): return d
    return ''


def _ts(args, timeout=30):
    exe = tailscale_exe()
    if not exe: return 1, 'Tailscale is not installed.'
    try:
        r = subprocess.run([exe] + args, capture_output=True, text=True, timeout=timeout, creationflags=procs.NO_WINDOW, errors='replace')
        return r.returncode, (r.stdout or '') + (r.stderr or '')
    except subprocess.TimeoutExpired as e:
        return 1, ((e.stdout or b'').decode(errors='replace') if isinstance(e.stdout, bytes) else (e.stdout or '')) + '\n(timed out)'
    except OSError as e:
        return 1, str(e)


_ts_cache = {'t': 0, 'v': None}


def tailscale_info(fresh=False):
    if not fresh and _ts_cache['v'] and time.time() - _ts_cache['t'] < 60: return _ts_cache['v']
    info = {'installed': bool(tailscale_exe()), 'state': '', 'dns': '', 'funnel': False, 'paths': []}
    if info['installed']:
        code, out = _ts(['status', '--json'])
        try:
            s = json.loads(out[out.index('{'):])
            info['state'] = s.get('BackendState', '')
            info['dns'] = ((s.get('Self') or {}).get('DNSName') or '').rstrip('.')
        except ValueError:
            info['state'] = 'Unknown'
        if info['state'] == 'Running':
            code, out = _ts(['funnel', 'status', '--json'])
            try:
                j = json.loads(out[out.index('{'):])
                info['funnel'] = any(v is True for v in (j.get('AllowFunnel') or {}).values())
                for host, web in (j.get('Web') or {}).items():
                    for path, h in ((web or {}).get('Handlers') or {}).items():
                        info['paths'].append({'path': path, 'to': h.get('Proxy') or h.get('Path') or ''})
            except ValueError:
                info['funnel'] = os.path.isfile(os.path.join(os.path.dirname(util.CC_DIR), 'PalPlanner', 'sharing-on.txt'))
    _ts_cache.update(t=time.time(), v=info)
    return info


def funnel_path(on, path='/admin', port=util.PORT):
    """Adds (or removes) one path on the family link, e.g. /admin for the Command Center on your phone."""
    if on:
        code, out = _ts(['funnel', '--bg', '--yes', '--set-path', path, f'http://127.0.0.1:{port}'], timeout=120)
    else:
        code, out = _ts(['funnel', '--set-path', path, 'off'], timeout=60)
    _ts_cache['t'] = 0
    url = re.search(r'https://login\.tailscale\.com/\S+', out)
    return {'ok': code == 0, 'text': out.strip()[-800:], 'approve': url.group(0) if url else ''}


def drop_old_admin_page():
    """Phone admin was dropped (the control panel is the only screen). Takes /admin off the family link if an older
    version put it there, and removes the old page file."""
    try:
        ts = tailscale_info(fresh=True)
        if any((x.get('path') or '').rstrip('/') == '/admin' and str(util.PORT) in str(x.get('to') or x.get('proxy') or '') for x in ts.get('paths') or []):
            r = funnel_path(False, '/admin')
            if r['ok']: util.event('service', 'Took the old phone admin page off the family link.', 'info')
    except Exception as e:
        util.log_error('Removing the old phone admin page', e)
    old = os.path.join(util.WEB, 'index.html')
    if os.path.isfile(old):
        try: os.remove(old); os.rmdir(util.WEB)
        except OSError: pass


def keep_paths(want):
    """want: [(path, port)] that belong on the family link (/admin for phone access, /discord for slash commands).
    Turning the family link off and on again clears them, so this puts back any that went missing, but only while the
    family link itself is on."""
    fixed = []
    if not want: return fixed
    ts = tailscale_info(fresh=True)
    if not ts.get('funnel'): return fixed
    have = {(x.get('path') or '').rstrip('/') or '/' for x in ts.get('paths') or []}
    if '/' not in have: return fixed
    for p, port in want:
        if p.rstrip('/') not in have:
            r = funnel_path(True, p, port)
            if r['ok']:
                fixed.append(p)
                util.event('planner', f'Put {p} back on the family link (it was cleared when the link was turned off and on).', 'info')
    return fixed


# ---------------- automatic refresh (a Windows scheduled task, so it runs while everything else is closed) ----------------
def _ps(script, timeout=60):
    r = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script], capture_output=True, text=True,
                       timeout=timeout, creationflags=procs.NO_WINDOW, errors='replace')
    return r.returncode, (r.stdout or '').strip() + (r.stderr or '').strip()


def auto_minutes():
    if not util.IS_WIN: return 0
    code, out = _ps(f"$t = Get-ScheduledTask -TaskName '{task_name()}' -ErrorAction Stop; if ($t.State -eq 'Disabled') {{ 'off' }} else {{ [string]$t.Triggers[0].Repetition.Interval }}")
    if code != 0 or not out or out == 'off': return 0
    m = re.search(r'PT(?:(\d+)H)?(?:(\d+)M)?', out)
    if not m: return 30
    return int(m.group(1) or 0) * 60 + int(m.group(2) or 0) or 30


def set_auto(sd, minutes):
    if not util.IS_WIN: raise RuntimeError('Automatic refresh needs Windows.')
    py, eng = python_exe(), engine(sd)
    script = f"try {{ Unregister-ScheduledTask -TaskName '{task_name()}' -Confirm:$false -ErrorAction Stop }} catch {{ }}\n"
    if minutes > 0:
        script += (f"$a = New-ScheduledTaskAction -Execute '{py}' -Argument '\"{eng}\" refresh --if-changed' -WorkingDirectory '{os.path.dirname(eng)}'\n"
                   "$t = New-ScheduledTaskTrigger -Daily -At '12:00 AM'\n"
                   f"$r = New-ScheduledTaskTrigger -Once -At '12:00 AM' -RepetitionInterval (New-TimeSpan -Minutes {int(minutes)}) -RepetitionDuration (New-TimeSpan -Hours 24)\n"
                   "$t.Repetition = $r.Repetition\n"
                   "$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)\n"
                   f"Register-ScheduledTask -TaskName '{task_name()}' -Action $a -Trigger $t -Settings $s -Description 'Rebuilds the Pal Planner from the Palworld save. Managed by the Command Center and the control panel.' -Force | Out-Null")
    code, out = _ps(script)
    if code != 0: raise RuntimeError('Windows did not accept the schedule: ' + out[-300:])


def invite_text(sd, p, link):
    m = auto_minutes()
    every = 'every hour' if m >= 60 else (f'every {m} minutes' if m > 0 else 'every so often')
    name = config.read_ini(sd).get('ServerName', '').strip('"') or 'our server'
    return (f"Hi {p.get('real') or p.get('game')}! Here's your {name} Pal Planner: all your pals with their true stats, the best crew for every "
            f"job, boss teams, breeding plans, recipes and the world map.\n\n{link}\n\nYour code: {p.get('code')}\n\n"
            "Your code only opens your own pals. Leave \"Remember me on this device\" ticked so you only type it once. "
            f"It updates by itself {every} while the server is running.\n\n"
            "When it asks, say yes to adding it to your home screen so it opens like an app.")


def summary(sd):
    st = read_status(sd) or {}
    save_players = {str(p.get('uid')): p for p in (st.get('players') or [])}
    by_name = {str(p.get('name', '')).lower(): p for p in (st.get('players') or [])}
    rows = []
    for p in read_players(sd):
        hit = save_players.get(p.get('uid')) or by_name.get(str(p.get('game', '')).lower())
        rows.append(dict(p, pals=(hit or {}).get('pals'), level=(hit or {}).get('level'), inSave=bool(hit)))
    ts = tailscale_info()
    link = f"https://{ts['dns']}/" if ts.get('dns') else ''
    return {'installed': installed(sd), 'status': {k: st.get(k) for k in ('ok', 'message', 'when', 'saved')},
            'savePlayers': st.get('players') or [], 'players': rows, 'web': web_running(), 'tailscale': ts,
            'link': link if ts.get('funnel') else '', 'auto': auto_minutes()}


# ---------------- keeping the planner's web server running (and on its newest version) ----------------
def web_script(sd):
    return os.path.join(pdir(sd), 'engine', 'webserver.py')


def web_procs(sd):
    want = os.path.normcase(os.path.abspath(web_script(sd)))
    out = []
    for p in psutil.process_iter(['pid', 'cmdline', 'create_time']):
        try:
            for a in (p.info['cmdline'] or [])[1:3]:
                if os.path.normcase(os.path.abspath(a)) == want:
                    out.append(p); break
        except (psutil.Error, ValueError, OSError):
            continue
    return out


def start_web(sd):
    flags = procs.NO_WINDOW | (0x00000008 | 0x00000200 if util.IS_WIN else 0)     # detached, own process group
    kw = {'creationflags': flags} if util.IS_WIN else {'start_new_session': True}
    subprocess.Popen([python_exe(), web_script(sd), str(WEB_PORT)], cwd=os.path.dirname(web_script(sd)), close_fds=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kw)


def _file_version(path):
    try:
        m = re.search(r"^VERSION = '([^']*)'", open(path, encoding='utf-8').read(), re.M)
        return m.group(1) if m else ''
    except OSError:
        return ''


def _running_version():
    import urllib.request
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{WEB_PORT}/__version', timeout=3) as r:
            return json.loads(r.read().decode()).get('version', '')
    except Exception:
        return ''                    # older copies don't know their version


def keep_web(sd):
    """Starts the planner's web server if it isn't running, and restarts it when its file has a newer version (so an
    update takes effect without anyone touching it)."""
    if not installed(sd) or not os.path.isfile(os.path.join(pdir(sd), 'players.json')) or not os.path.isfile(web_script(sd)): return
    if web_running():
        if _running_version() == _file_version(web_script(sd)): return
        ps = web_procs(sd)
        if not ps: return                # something else owns the port; leave it alone
        for p in ps:
            try: p.kill()
            except psutil.Error: pass
        psutil.wait_procs(ps, timeout=10)
        for _ in range(20):
            if not web_running(): break
            time.sleep(0.5)
        start_web(sd)
        util.event('planner', "Restarted the Pal Planner's website so it uses its update.", 'info')
    else:
        start_web(sd)
        util.event('planner', "Started the Pal Planner's website (it wasn't running).", 'info')
