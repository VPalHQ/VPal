"""Puts a VPal update in place. The watchdog starts this after it downloaded an update and checked it; it is not for
running by hand.

    python -I vpal_updater.py <job.json>

1. waits for the watchdog to close, so none of its files are in use
2. puts each changed file in place, keeping a copy of every file it replaces (CommandCenter\\data\\updates\\previous)
3. if any file can't be written, puts every file back as it was, so VPal is never left half-updated
4. writes the result for the watchdog and the control panel, and starts the watchdog again

Only VPal's own program files are ever written: the control panel, CommandCenter\\service, PalPlanner\\engine,
PalPlanner\\web and the README and NOTICE files. Your settings, worlds, backups, the watchdog's data, the Pal Planner's
player list, codes and locked planners, and the page name you chose are never in an update and never touched.
The Palworld server keeps running the whole time.

Standard library only, so it never needs a file that it is replacing.
Unofficial fan tool. Not affiliated with Pocketpair.
"""
import os, sys, re, json, time, zipfile, shutil, subprocess

FILES = {'PalworldSettingsEditor.ps1', 'VPal.exe', 'NOTICE.txt', 'CommandCenter/README.txt', 'PalPlanner/README.txt'}
FOLDERS = ('CommandCenter/service/', 'PalPlanner/engine/', 'PalPlanner/web/')
# made on this PC and yours to keep, even though they sit in a folder that updates write to
KEEP = {'palplanner/web/planners.enc.json', 'palplanner/web/site.json', 'palplanner/web/manifest.json'}
MAX_FILES, MAX_FILE, MAX_TOTAL = 5000, 150 * 2**20, 400 * 2**20
_PART = re.compile(r'[A-Za-z0-9_][A-Za-z0-9_.\-]*')
_DEVICES = {'CON', 'PRN', 'AUX', 'NUL'} | {f'COM{i}' for i in range(10)} | {f'LPT{i}' for i in range(10)}


class Refused(Exception):
    """The update can't be installed. Nothing on this PC was changed (or everything was put back)."""


def check_name(name):
    """The path VPal writes for one zip entry: the entry's path for a VPal program file, '' for a folder entry or
    for a file that is kept (yours, or one Python makes itself). Refuses anything else, so an update can never
    write outside VPal's own program files."""
    if name.endswith('/'): return ''
    parts = name.split('/')
    for p in parts:
        if not _PART.fullmatch(p) or p.endswith('.') or p.split('.')[0].upper() in _DEVICES:
            raise Refused(f'it holds a file with a name VPal does not allow ({name!r})')
    if '__pycache__' in parts or name.endswith('.pyc'): return ''
    if name.lower() in KEEP: return ''
    if name in FILES or name.startswith(FOLDERS): return name
    raise Refused(f'it holds a file that is not part of VPal ({name})')


def plan(zip_path):
    """[(zip entry, size)] of the files an update writes, after checking every entry. Raises Refused."""
    try:
        z = zipfile.ZipFile(zip_path)
    except (zipfile.BadZipFile, OSError):
        raise Refused('the download is not a working zip file')
    with z:
        infos = z.infolist()
        if len(infos) > MAX_FILES: raise Refused('it holds too many files')
        out, seen, total = [], set(), 0
        for i in infos:
            rel = check_name(i.filename)
            if not rel: continue
            if rel.lower() in seen: raise Refused(f'it holds {rel} twice')
            seen.add(rel.lower())
            if i.flag_bits & 0x1: raise Refused('it is password-protected')
            if i.file_size > MAX_FILE: raise Refused(f'{rel} is too big')
            total += i.file_size
            out.append((rel, i.file_size))
        if total > MAX_TOTAL: raise Refused('it is too big')
        if 'commandcenter/service/ccservice.py' not in seen or 'commandcenter/service/cc/util.py' not in seen:
            raise Refused("it doesn't look like a VPal update")
        bad = z.testzip()
        if bad: raise Refused(f'{bad} is damaged in the download')
        return out


def zip_version(zip_path):
    """The VPal version inside an update zip (from the watchdog's util.py), or ''."""
    try:
        with zipfile.ZipFile(zip_path) as z:
            text = z.read('CommandCenter/service/cc/util.py').decode('utf-8', 'replace')
    except (KeyError, zipfile.BadZipFile, OSError):
        return ''
    m = re.search(r"^VERSION = '([^']*)'", text, re.M)
    return m.group(1) if m else ''


# ---------------- putting the files in ----------------
def _alive(pid):
    if os.name == 'nt':
        import ctypes
        k = ctypes.windll.kernel32
        k.OpenProcess.restype = ctypes.c_void_p
        h = k.OpenProcess(0x00100000 | 0x1000, False, int(pid))     # SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION
        if not h: return False
        try:
            return k.WaitForSingleObject(ctypes.c_void_p(h), 0) == 0x102           # WAIT_TIMEOUT: still running
        finally:
            k.CloseHandle(ctypes.c_void_p(h))
    try:
        os.kill(int(pid), 0)
    except OSError:
        return False
    try:                                                    # a finished child that nobody reaped yet counts as gone
        with open(f'/proc/{int(pid)}/stat') as f:
            return f.read().rsplit(')', 1)[1].split()[0] != 'Z'
    except OSError:
        return True


def _same(path, data):
    try:
        if os.path.getsize(path) != len(data): return False
        with open(path, 'rb') as f:
            return f.read() == data
    except OSError:
        return False


def _put(target, data, log, wait=45):
    """Writes next to the file, then swaps it in. A program file that is in use (a Pal Planner update running at that
    moment) is retried for a while before giving up."""
    tmp = target + '.vpal-new'
    with open(tmp, 'wb') as f:
        f.write(data)
    end = time.time() + wait
    while True:
        try:
            os.replace(tmp, target)
            return
        except PermissionError:
            if time.time() > end:
                try: os.remove(tmp)
                except OSError: pass
                raise Refused(f'{os.path.basename(target)} is in use by another program')
            log(f'  in use, trying again: {target}')
            time.sleep(1)


def _undo(done, log):
    """Puts back every file written so far. Returns the files that could not be put back."""
    stuck = []
    for target, backup in reversed(done):
        try:
            if backup:
                with open(backup, 'rb') as f:
                    _put(target, f.read(), log, wait=30)
            else:
                os.remove(target)
            log(f'  put back: {target}')
        except Exception as e:
            stuck.append(target)
            log(f'  COULD NOT put back {target}: {e}')
    return stuck


def apply(root, zip_path, previous, log):
    """Writes the changed files. All of them land or none does. Returns counts."""
    files = plan(zip_path)
    shutil.rmtree(previous, ignore_errors=True)
    os.makedirs(previous, exist_ok=True)
    done, changed, added, same = [], 0, 0, 0
    try:
        with zipfile.ZipFile(zip_path) as z:
            for rel, size in files:
                data = z.read(rel)
                target = os.path.join(root, *rel.split('/'))
                if os.path.isdir(target): raise Refused(f'{rel} is a folder on this PC')
                if _same(target, data):
                    same += 1
                    continue
                backup = None
                if os.path.exists(target):
                    backup = os.path.join(previous, *rel.split('/'))
                    os.makedirs(os.path.dirname(backup), exist_ok=True)
                    shutil.copyfile(target, backup)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                _put(target, data, log)
                done.append((target, backup))
                if backup: changed += 1
                else: added += 1
                log(('  updated: ' if backup else '  added:   ') + rel)
    except BaseException as e:
        log(f'Stopped at an error ({e}), putting back {len(done)} file(s)...')
        stuck = _undo(done, log)
        if stuck: raise Refused(f'{e}. {len(stuck)} file(s) could not be put back, so run VPal-Setup.exe to repair VPal (it keeps your server, worlds and settings)') from None
        raise
    return {'changed': changed, 'added': added, 'unchanged': same}


def _clear_pycache(root, log):
    for top in ('CommandCenter/service', 'PalPlanner/engine'):
        for d, subs, _ in os.walk(os.path.join(root, *top.split('/'))):
            if os.path.basename(d) == '__pycache__':
                shutil.rmtree(d, ignore_errors=True)
                subs[:] = []


def _set_apps_version(root, version):
    """Shows the new version in Windows' Apps list (only for a VPal installed by VPal-Setup.exe into this folder)."""
    if os.name != 'nt': return
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Uninstall\VPal', 0,
                            winreg.KEY_READ | winreg.KEY_SET_VALUE) as k:
            loc = winreg.QueryValueEx(k, 'InstallLocation')[0]
            if os.path.normcase(os.path.abspath(loc)) == os.path.normcase(os.path.abspath(root)):
                winreg.SetValueEx(k, 'DisplayVersion', 0, winreg.REG_SZ, version)
    except OSError:
        pass


def _start(cmd, cwd):
    kw = {'creationflags': 0x08000000 | 0x00000008 | 0x00000200} if os.name == 'nt' else {'start_new_session': True}
    subprocess.Popen(cmd, cwd=cwd, close_fds=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, **kw)


def main(job_path):
    job = json.load(open(job_path, encoding='utf-8'))
    upd = job['updates']
    os.makedirs(upd, exist_ok=True)
    lock = os.path.join(upd, 'updating.lock')
    logf = open(os.path.join(upd, 'updater-log.txt'), 'a', encoding='utf-8')

    def log(text):
        logf.write(time.strftime('%Y-%m-%d %H:%M:%S ') + text + '\n')
        logf.flush()

    with open(lock, 'w') as f:                               # a watchdog started now (sign-in, the 5-minute task) waits
        f.write(str(os.getpid()))
    log(f"VPal update {job['from']} -> {job['to']} in {job['root']}")
    result = {'ok': False, 'from': job['from'], 'to': job['to'], 't': round(time.time())}
    try:
        end = time.time() + 90
        while _alive(job['pid']):
            if time.time() > end: raise Refused('the watchdog did not close')
            time.sleep(0.5)
        time.sleep(0.5)
        result.update(apply(job['root'], job['zip'], os.path.join(upd, 'previous'), log))
        result['ok'] = True
        _clear_pycache(job['root'], log)
        _set_apps_version(job['root'], job['to'])
        log(f"Done: {result['changed']} updated, {result['added']} added, {result['unchanged']} already up to date.")
    except Refused as e:
        result['error'] = f"VPal {job['to']} wasn't installed: {e}. VPal is still on {job['from']}."
        log('Not installed: ' + str(e))
    except Exception as e:
        result['error'] = f"VPal {job['to']} wasn't installed ({e.__class__.__name__}: {e}). VPal is still on {job['from']}."
        log(f'Not installed: {e.__class__.__name__}: {e}')
    with open(os.path.join(upd, 'result.json.tmp'), 'w', encoding='utf-8') as f:
        json.dump(result, f, indent=1)
    os.replace(os.path.join(upd, 'result.json.tmp'), os.path.join(upd, 'result.json'))
    try: os.remove(job['zip'])
    except OSError: pass
    try: os.remove(lock)
    except OSError: pass
    try:
        _start(job['restart'], os.path.dirname(job['restart'][-1]))
        log('Started the watchdog again.')
    except Exception as e:
        log(f'Could not start the watchdog ({e}). The scheduled task starts it within 5 minutes.')
    logf.close()
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
