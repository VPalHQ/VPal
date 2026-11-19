"""Finding, starting and stopping the server process, its memory, its ports, and whether it crashed."""
import os, re, glob, time, subprocess, datetime
import psutil
from . import util, config

NO_WINDOW = 0x08000000 if util.IS_WIN else 0          # CREATE_NO_WINDOW
NEW_CONSOLE = 0x00000010 if util.IS_WIN else 0        # CREATE_NEW_CONSOLE (the server gets its usual window)


def server_procs(cfg):
    names = {n.lower() for n in cfg['process_names']}
    out = []
    for p in psutil.process_iter(['name', 'pid', 'create_time']):
        try:
            if (p.info['name'] or '').lower() in names: out.append(p)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return out


def main_proc(cfg):
    """The real server (the biggest one if a launcher and the server both match)."""
    best, size = None, -1
    for p in server_procs(cfg):
        try:
            m = mem_bytes(p)
            if m > size: best, size = p, m
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return best


def mem_bytes(p):
    """Memory the server holds. On Windows 'private' tracks a leak better than the working set."""
    mi = p.memory_info()
    return max(getattr(mi, 'private', 0) or 0, mi.rss)


def system_memory():
    vm = psutil.virtual_memory()
    return vm.total / 2**30, vm.available / 2**30


def maintenance_running(cfg):
    """True while the scheduled restart script or SteamCMD (an update) is working, so the watchdog stays out of the way."""
    marks = [m.lower() for m in cfg['maintenance_markers'] if m]
    me = os.getpid()
    for p in psutil.process_iter(['pid', 'name', 'cmdline', 'ppid']):
        try:
            if p.info['pid'] == me or p.info['ppid'] == me: continue        # our own update check is not maintenance
            line = ' '.join(p.info['cmdline'] or []).lower() or (p.info['name'] or '').lower()
            if any(m in line for m in marks): return True
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return False


def port_holders(port_list):
    """[(port, pid, program)] for the ports we care about."""
    out = []
    try:
        for c in psutil.net_connections(kind='inet'):
            if c.laddr and c.laddr.port in port_list and c.status in (psutil.CONN_LISTEN, psutil.CONN_NONE):
                name = ''
                try: name = psutil.Process(c.pid).name() if c.pid else ''
                except psutil.Error: pass
                out.append((c.laddr.port, c.pid, name))
    except (psutil.AccessDenied, OSError):
        pass
    return out


def wait_ports_free(cfg, port_list, timeout=120, min_wait=15, on_wait=None):
    """Waits until the old server has let go of its ports, so a new one can't fail to open them.
    Returns (ok, other) where other lists ports held by some other program (waiting won't fix those)."""
    names = {n.lower() for n in cfg['process_names']}
    t0 = time.time()
    while True:
        held = port_holders(port_list)
        ours = [h for h in held if not h[2] or h[2].lower() in names]
        other = sorted({f'{h[0]} ({h[2]})' for h in held if h[2] and h[2].lower() not in names})
        waited = time.time() - t0
        if not ours and waited >= min_wait: return True, other
        if waited >= timeout: return False, other
        if on_wait: on_wait([h[0] for h in ours])
        time.sleep(2)


def crash_evidence(sd, since):
    """Signs that the server crashed (rather than being closed on purpose) after the time 'since'."""
    why = []
    for d in glob.glob(os.path.join(sd, 'Pal', 'Saved', 'Crashes', '*')):
        try:
            if os.path.getmtime(d) >= since - 30: why.append('crash report ' + os.path.basename(d))
        except OSError:
            pass
    if util.IS_WIN:
        mins = max(2, int((time.time() - since) / 60) + 2)
        q = f"*[System[(EventID=1000 or EventID=1002) and TimeCreated[timediff(@SystemTime) <= {mins * 60000}]]]"
        try:
            r = subprocess.run(['wevtutil', 'qe', 'Application', '/q:' + q, '/f:text', '/rd:true', '/c:20'],
                               capture_output=True, text=True, timeout=20, creationflags=NO_WINDOW)
            if 'palserver' in (r.stdout or '').lower(): why.append('Windows error report')
        except (OSError, subprocess.SubprocessError):
            pass
    return why


def kill_server(cfg, timeout=30):
    procs = server_procs(cfg)
    for p in procs:
        try:
            for c in p.children(recursive=True):
                try: c.kill()
                except psutil.Error: pass
            p.kill()
        except psutil.Error:
            pass
    gone, alive = psutil.wait_procs(procs, timeout=timeout)
    return not alive


def start_server(cfg, sd):
    """Starts the server the same way you do (the start script updates the game first)."""
    script = config.start_script(cfg, sd)
    if not script: raise RuntimeError('No start script found. Check the Watchdog tab in the control panel.')
    if util.IS_WIN:
        subprocess.Popen(['cmd.exe', '/c', script], cwd=os.path.dirname(script), creationflags=NEW_CONSOLE, close_fds=True)
    else:
        subprocess.Popen(['/bin/sh', script], cwd=os.path.dirname(script), start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return script


def next_external_restart(cfg):
    """When a Windows scheduled restart task runs next, as a timestamp, or None."""
    name = cfg.get('external_restart_task')
    if not name or not util.IS_WIN: return None
    ps = f"(Get-ScheduledTask -TaskName '{name}' -ErrorAction Stop | Get-ScheduledTaskInfo).NextRunTime.ToString('o')"
    try:
        r = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', ps], capture_output=True, text=True,
                           timeout=30, creationflags=NO_WINDOW)
        s = (r.stdout or '').strip()
        if not s: return None
        s = re.sub(r'(\.\d{6})\d*', r'\1', s)
        return datetime.datetime.fromisoformat(s).timestamp()
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
