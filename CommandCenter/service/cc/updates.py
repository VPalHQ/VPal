"""Is a newer Palworld server build out? Compares the installed build (steamapps manifest) with Steam's public build,
asked through SteamCMD. Read-only: the actual update happens when the start script runs SteamCMD."""
import os, re, glob, subprocess
from . import util, config, procs

APP = '2394010'                    # Palworld Dedicated Server on Steam


def installed_build(sd):
    for p in [os.path.join(sd, 'steamapps', f'appmanifest_{APP}.acf')] + glob.glob(os.path.join(sd, '*', 'steamapps', f'appmanifest_{APP}.acf')):
        try:
            m = re.search(r'"buildid"\s+"(\d+)"', open(p, encoding='utf-8', errors='replace').read())
            if m: return int(m.group(1))
        except OSError:
            continue
    return None


def latest_build(cfg, sd, timeout=240):
    exe = config.steamcmd_path(cfg, sd)
    if not exe: raise RuntimeError('SteamCMD was not found, so the watchdog cannot check for game updates.')
    r = subprocess.run([exe, '+login', 'anonymous', '+app_info_update', '1', '+app_info_print', APP, '+quit'],
                       capture_output=True, text=True, timeout=timeout, cwd=os.path.dirname(exe), creationflags=procs.NO_WINDOW,
                       errors='replace')
    text = r.stdout or ''
    m = re.search(r'"branches"\s*\{\s*"public"\s*\{[^{}]*?"buildid"\s+"(\d+)"', text, re.S)
    if not m: raise RuntimeError('SteamCMD did not report a build number (Steam may be busy). Will try again later.')
    return int(m.group(1))
