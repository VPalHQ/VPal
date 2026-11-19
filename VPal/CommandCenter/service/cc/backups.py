"""World backups: the Command Center's own snapshots (zips) plus the game's rolling backups, a preview of what a
backup holds compared with the world now, and restore (always making a safety copy of the current world first)."""
import os, io, re, sys, glob, time, shutil, zipfile, tempfile, threading
from . import util, config

DIR = util.data('backups')
os.makedirs(DIR, exist_ok=True)
_lock = threading.Lock()
WORLD_FILES = ('Level.sav', 'LevelMeta.sav', 'WorldOption.sav')


def _world_members(wd):
    """Files that make up the world (not the game's own backup folder)."""
    out = []
    for name in WORLD_FILES:
        p = os.path.join(wd, name)
        if os.path.isfile(p): out.append((p, name))
    for p in glob.glob(os.path.join(wd, 'Players', '*.sav')):
        out.append((p, 'Players/' + os.path.basename(p)))
    return out


def _read_stable(path, tries=5):
    """Reads a file the server may be writing: retry until size and time stay the same across the read."""
    for i in range(tries):
        try:
            st = os.stat(path)
            with open(path, 'rb') as f: data = f.read()
            st2 = os.stat(path)
            if st.st_size == st2.st_size == len(data) and st.st_mtime == st2.st_mtime: return data
        except OSError:
            pass
        time.sleep(1.5)
    raise RuntimeError(f'{os.path.basename(path)} kept changing while it was copied')


def snapshot(sd, reason='auto', note=''):
    """Zips the world into data\\backups. Returns the backup entry."""
    wd = config.world_dir(sd)
    if not wd: raise RuntimeError('Could not find the world save folder.')
    with _lock:
        name = time.strftime('%Y-%m-%d_%H-%M-%S') + '_' + re.sub(r'[^a-z-]', '', reason.lower()) + '.zip'
        tmp = os.path.join(DIR, name + '.part')
        with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            z.writestr('world.txt', f'world={os.path.basename(wd)}\nreason={reason}\nnote={note}\ntime={util.stamp()}\n')
            for src, arc in _world_members(wd):
                z.writestr(arc, _read_stable(src))
        os.replace(tmp, os.path.join(DIR, name))
    prune()
    return entry_for(os.path.join(DIR, name))


def prune(keep=None):
    cfg = config.load()
    keep = keep or int(cfg['backups'].get('keep') or 20)
    zips = sorted(glob.glob(os.path.join(DIR, '*.zip')), reverse=True)
    auto = [z for z in zips if not z.endswith(('_manual.zip', '_before-restore.zip'))]
    safety = [z for z in zips if z.endswith('_before-restore.zip')]
    for z in auto[keep:] + safety[5:]:
        try: os.remove(z)
        except OSError: pass


REASON = {'auto': 'Every few hours', 'manual': 'Made by you', 'before-restart': 'Before a restart', 'before-restore': 'Safety copy before a restore',
          'before-update': 'Before an update', 'game': 'The game’s own backup'}


def entry_for(path):
    base = os.path.basename(path)
    m = re.match(r'(\d{4}-\d\d-\d\d)_(\d\d)-(\d\d)-(\d\d)_(.*)\.zip$', base)
    t = time.mktime(time.strptime(f'{m.group(1)} {m.group(2)}:{m.group(3)}:{m.group(4)}', '%Y-%m-%d %H:%M:%S')) if m else os.path.getmtime(path)
    reason = m.group(5) if m else 'manual'
    return {'id': 'cc:' + base, 'kind': 'cc', 'reason': reason, 'label': REASON.get(reason, reason), 't': round(t), 'when': util.nice(t),
            'size': os.path.getsize(path)}


def game_backups(sd):
    """The game's rolling backups (bIsUseBackupSaveData): SaveGames\\0\\<world>\\backup\\world\\<time>."""
    wd = config.world_dir(sd)
    out = []
    for d in glob.glob(os.path.join(wd, 'backup', 'world', '*')):
        if not os.path.isfile(os.path.join(d, 'Level.sav')): continue
        try:
            t = os.path.getmtime(os.path.join(d, 'Level.sav'))
            size = sum(os.path.getsize(f) for f in glob.glob(os.path.join(d, '**', '*'), recursive=True) if os.path.isfile(f))
        except OSError:
            continue
        out.append({'id': 'game:' + os.path.basename(d), 'kind': 'game', 'reason': 'game', 'label': REASON['game'], 't': round(t),
                    'when': util.nice(t), 'size': size})
    return out


def newest(sd):
    """Time of the newest backup of any kind (cheap: no sizes)."""
    ts = [os.path.getmtime(z) for z in glob.glob(os.path.join(DIR, '*.zip'))]
    wd = config.world_dir(sd)
    if wd:
        ts += [os.path.getmtime(d) for d in glob.glob(os.path.join(wd, 'backup', 'world', '*'))]
    return max(ts) if ts else None


def list_all(sd):
    mine = [entry_for(z) for z in glob.glob(os.path.join(DIR, '*.zip'))]
    out = sorted(mine + game_backups(sd), key=lambda e: -e['t'])
    return out


def _source(sd, bid):
    """Where a backup's files are: ('zip', path) or ('dir', path)."""
    kind, _, name = bid.partition(':')
    if '/' in name or '\\' in name or '..' in name: raise ValueError('bad backup id')
    if kind == 'cc':
        p = os.path.join(DIR, name)
        if os.path.isfile(p): return 'zip', p
    if kind == 'game':
        p = os.path.join(config.world_dir(sd), 'backup', 'world', name)
        if os.path.isdir(p): return 'dir', p
    raise FileNotFoundError('That backup no longer exists.')


def _extract(sd, bid, dest):
    kind, src = _source(sd, bid)
    if kind == 'zip':
        with zipfile.ZipFile(src) as z:
            for n in z.namelist():
                if n == 'world.txt' or n.endswith('/'): continue
                if not (n in WORLD_FILES or re.fullmatch(r'Players/[0-9A-Fa-f]+\.sav', n)): continue
                out = os.path.join(dest, *n.split('/'))
                os.makedirs(os.path.dirname(out), exist_ok=True)
                with open(out, 'wb') as f: f.write(z.read(n))
    else:
        for name in WORLD_FILES:
            p = os.path.join(src, name)
            if os.path.isfile(p): shutil.copy2(p, os.path.join(dest, name))
        for p in glob.glob(os.path.join(src, 'Players', '*.sav')):
            os.makedirs(os.path.join(dest, 'Players'), exist_ok=True)
            shutil.copy2(p, os.path.join(dest, 'Players', os.path.basename(p)))
    if not os.path.isfile(os.path.join(dest, 'Level.sav')): raise RuntimeError('That backup has no Level.sav.')


# ---------------- preview (who is in the backup, compared with now) ----------------
def _summary(world):
    """Players (name, level) and pal counts in a world folder, using the Pal Planner's save reader when it's installed."""
    eng = os.path.join(os.path.dirname(util.CC_DIR), 'PalPlanner', 'engine')
    files = {'players': len(glob.glob(os.path.join(world, 'Players', '*.sav'))),
             'size': os.path.getsize(os.path.join(world, 'Level.sav')) if os.path.isfile(os.path.join(world, 'Level.sav')) else 0}
    if not os.path.isdir(eng): return dict(files, detail=None)
    try:
        for p in (eng, os.environ.get('PALPLANNER_LIB') or os.path.join(eng, 'lib')):
            if p not in sys.path: sys.path.insert(0, p)
        import palplanner as pp
        from palsav.gvas import GvasFile
        from palsav.paltypes import PALWORLD_TYPE_HINTS, PALWORLD_CUSTOM_PROPERTIES
        raw = pp.read_sav(os.path.join(world, 'Level.sav'))
        keep = {k: v for k, v in PALWORLD_CUSTOM_PROPERTIES.items() if 'CharacterSaveParameterMap' in k or 'GroupSaveDataMap' in k}
        w = GvasFile.read(raw, PALWORLD_TYPE_HINTS, keep, allow_nan=True).properties['worldSaveData']['value']
        people, pals = {}, {}
        for e in w['CharacterSaveParameterMap']['value']:
            sp = e['value']['RawData']['value']['object']['SaveParameter']['value']
            g = lambda k, d=None: (sp.get(k) or {}).get('value', d)
            if g('IsPlayer'):
                lv = g('Level', 1); lv = lv.get('value', 1) if isinstance(lv, dict) else lv
                nm = g('NickName', 'Player')
                people[str(e['key']['PlayerUId']['value'])] = {'name': nm, 'level': lv}
            else:
                owner = g('OwnerPlayerUId')
                if owner: pals[str(owner)] = pals.get(str(owner), 0) + 1
        for uid, p in people.items(): p['pals'] = pals.get(uid, 0)
        guilds = len([g for g in (w.get('GroupSaveDataMap') or {}).get('value') or []
                      if (g['value'].get('GroupType') or {}).get('value', {}).get('value') == 'EPalGroupType::Guild'])
        return dict(files, detail={'players': sorted(people.values(), key=lambda p: p['name'].lower()), 'guilds': guilds})
    except Exception as e:
        return dict(files, detail=None, note=f'Could not read player details ({e.__class__.__name__}).')


def preview(sd, bid):
    with tempfile.TemporaryDirectory(prefix='cc-preview-') as tmp:
        _extract(sd, bid, tmp)
        then = _summary(tmp)
    now = _summary(config.world_dir(sd))
    e = next((x for x in list_all(sd) if x['id'] == bid), {'id': bid})
    return {'backup': e, 'then': then, 'now': now}


def restore_files(sd, bid):
    """Copies a backup over the world. The caller has stopped the server and made a safety copy first."""
    wd = config.world_dir(sd)
    with tempfile.TemporaryDirectory(prefix='cc-restore-') as tmp:
        _extract(sd, bid, tmp)
        # players who joined after the backup would keep their newer files and not match the world: move them aside
        aside = os.path.join(wd, 'Players-not-in-restored-backup')
        have = {os.path.basename(p) for p in glob.glob(os.path.join(tmp, 'Players', '*.sav'))}
        for p in glob.glob(os.path.join(wd, 'Players', '*.sav')):
            if os.path.basename(p) not in have:
                os.makedirs(aside, exist_ok=True)
                shutil.move(p, os.path.join(aside, os.path.basename(p)))
        for root, _, files in os.walk(tmp):
            for f in files:
                rel = os.path.relpath(os.path.join(root, f), tmp)
                dst = os.path.join(wd, rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(os.path.join(root, f), dst)
    return wd
