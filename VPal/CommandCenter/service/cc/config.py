"""Settings for the Command Center (data/config.json) and everything it can work out about the server by itself."""
import os, re, glob, copy
from . import util

DEFAULTS = {
    'server_dir': '',                 # blank = the folder that holds CommandCenter (the server folder)
    'start_script': '',               # blank = StartServer.bat (Windows) / StartServer.sh (Linux) in the server folder
    'steamcmd': '',                   # blank = found from the start script or the usual places
    'process_names': ['PalServer-Win64-Shipping-Cmd.exe', 'PalServer-Win64-Shipping.exe', 'PalServer.exe', 'PalServer-Linux-Shipping', 'PalServer-Linux-Test'],
    # while any program whose command line contains one of these is running, the watchdog leaves the server alone
    'maintenance_markers': ['RestartServer.ps1', 'steamcmd'],
    'external_restart_task': 'Palworld 12-Hour Restart',   # a Windows scheduled restart task to plan around, if there is one
    'watchdog': {'enabled': True, 'crash_restart': True, 'restart_any_stop': False, 'freeze_restart': True,
                 'freeze_minutes': 3, 'startup_grace_minutes': 6, 'port_min_wait_seconds': 15},
    'memory': {'enabled': True, 'limit_gb': 0, 'min_free_gb': 1.0, 'warn_minutes': 5, 'cooldown_minutes': 120,
               'skip_if_restart_within_minutes': 45, 'sustain_minutes': 2},
    'updates': {'enabled': True, 'check_minutes': 60, 'auto_restart': True, 'warn_minutes': 10},
    'backups': {'enabled': True, 'every_hours': 6, 'keep': 20, 'before_restart': True},
    'schedule': {'enabled': False, 'times': ['01:00', '13:00'], 'warn_minutes': 5},
    'whitelist': {'enabled': False, 'ids': [], 'message': 'This server is invite-only. Ask the owner to add you.'},
    'welcome': {'mode': 'auto', 'delay_seconds': 20},
    'remote': {'enabled': False, 'path': '/admin'},
    'messages': {'restart': 'Server restarting in {left}. Back in about 3 minutes!',
                 'memory': 'Server tune-up: restarting in {left} to keep things running smoothly. Back in about 3 minutes!',
                 'update': 'A Palworld update is out. Server restarting in {left} to update. Back in about 5 minutes!'},
}
PATH = util.data('config.json')


def _merge(base, extra):
    out = copy.deepcopy(base)
    for k, v in (extra or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict): out[k] = _merge(out[k], v)
        else: out[k] = v
    return out


def load():
    return _merge(DEFAULTS, util.read_json(PATH, {}))


def save(cfg):
    util.write_json(PATH, cfg)


def update(changes):
    """Applies a partial change from the control panel (only known keys)."""
    cur = util.read_json(PATH, {}) or {}
    def clean(d, ref):
        o = {}
        for k, v in d.items():
            if k not in ref: continue
            if isinstance(ref[k], dict) and isinstance(v, dict): o[k] = clean(v, ref[k])
            elif isinstance(ref[k], bool): o[k] = bool(v)
            elif isinstance(ref[k], (int, float)) and not isinstance(ref[k], bool):
                try: o[k] = float(v) if isinstance(ref[k], float) or '.' in str(v) else int(v)
                except (TypeError, ValueError): continue
            elif isinstance(ref[k], list): o[k] = [str(x).strip() for x in v if str(x).strip()] if isinstance(v, list) else ref[k]
            else: o[k] = str(v)
        return o
    save(_merge(cur, clean(changes, DEFAULTS)))
    return load()


# ---------------- what we can work out about the server ----------------
def server_dir(cfg=None):
    cfg = cfg or load()
    return cfg['server_dir'] or os.path.dirname(util.CC_DIR)


def config_dir(sd):
    for sub in ('WindowsServer', 'LinuxServer'):
        p = os.path.join(sd, 'Pal', 'Saved', 'Config', sub)
        if os.path.isdir(p): return p
    return os.path.join(sd, 'Pal', 'Saved', 'Config', 'WindowsServer' if util.IS_WIN else 'LinuxServer')


def ini_path(sd):
    return os.path.join(config_dir(sd), 'PalWorldSettings.ini')


def read_ini(sd):
    """The OptionSettings=(...) values as a dict of strings (quotes removed)."""
    try:
        with open(ini_path(sd), encoding='utf-8-sig', errors='replace') as f:
            text = f.read()
    except OSError:
        return {}
    m = re.search(r'OptionSettings=\((.*)\)', text, re.S)
    if not m: return {}
    body, out, i, key, buf, q, depth = m.group(1), {}, 0, None, '', False, 0
    for ch in body + ',':
        if ch == '"': q = not q; buf += ch; continue
        if not q and ch == '(': depth += 1
        if not q and ch == ')': depth -= 1
        if not q and depth == 0 and ch == '=' and key is None: key, buf = buf.strip(), ''; continue
        if not q and depth == 0 and ch == ',':
            if key: out[key] = buf.strip().strip('"')
            key, buf = None, ''; continue
        buf += ch
    return out


def world_dir(sd):
    """The folder of the world this server runs (SaveGames\\0\\<id>)."""
    base = os.path.join(sd, 'Pal', 'Saved', 'SaveGames', '0')
    want = ''
    for f in (os.path.join(config_dir(sd), 'GameUserSettings.ini'),):
        try:
            m = re.search(r'DedicatedServerName=([0-9A-Fa-f]+)', open(f, encoding='utf-8', errors='replace').read())
            if m: want = m.group(1)
        except OSError:
            pass
    if want and os.path.isfile(os.path.join(base, want, 'Level.sav')): return os.path.join(base, want)
    cands = sorted(glob.glob(os.path.join(base, '*', 'Level.sav')), key=os.path.getmtime, reverse=True)
    return os.path.dirname(cands[0]) if cands else ''


def start_script(cfg, sd):
    if cfg['start_script']: return cfg['start_script']
    for n in (('StartServer.bat', 'Start Server.bat', 'start.bat', 'PalServer.exe') if util.IS_WIN else ('StartServer.sh', 'start.sh', 'PalServer.sh')):
        p = os.path.join(sd, n)
        if os.path.isfile(p): return p            # a start script updates the game first; the server program alone also works
    return ''


def steamcmd_path(cfg, sd):
    if cfg['steamcmd'] and os.path.isfile(cfg['steamcmd']): return cfg['steamcmd']
    s = start_script(cfg, sd)
    if s:
        try:
            m = re.search(r'"?([A-Za-z]:[^"\r\n]*?steamcmd(?:\.exe|\.sh)?)"?(?:\s|$)', open(s, encoding='utf-8', errors='replace').read(), re.I)
            if m and os.path.isfile(m.group(1)): return m.group(1)
        except OSError:
            pass
    cands = [os.path.join(sd, 'steamcmd', 'steamcmd.exe'), r'C:\steamcmd\steamcmd.exe', r'C:\SteamCMD\steamcmd.exe',
             os.path.join(os.path.dirname(sd), 'steamcmd', 'steamcmd.exe'),
             os.path.expanduser('~/steamcmd/steamcmd.sh'), '/usr/games/steamcmd', '/usr/bin/steamcmd']
    for c in cands:
        if os.path.isfile(c): return c
    return ''


def api_info(sd):
    """REST address and login from the settings file. None when the REST API is off."""
    v = read_ini(sd)
    if str(v.get('RESTAPIEnabled', 'False')).lower() != 'true': return None
    port = v.get('RESTAPIPort') or '8212'
    return {'url': f'http://127.0.0.1:{port}/v1/api', 'password': v.get('AdminPassword', ''), 'port': int(port)}


def ports(sd):
    v = read_ini(sd)
    out = {int(v.get('PublicPort') or 8211), 27015}
    if str(v.get('RESTAPIEnabled', 'False')).lower() == 'true': out.add(int(v.get('RESTAPIPort') or 8212))
    if str(v.get('RCONEnabled', 'False')).lower() == 'true': out.add(int(v.get('RCONPort') or 25575))
    return sorted(out)


def memory_limit_gb(cfg, total_gb):
    """Restart point for the server's memory: what you set, or about 70% of the PC's memory (and leave 4 GB free)."""
    lim = float(cfg['memory'].get('limit_gb') or 0)
    if lim > 0: return lim
    return round(max(4.0, min(total_gb * 0.70, total_gb - 4.0)), 1)
