"""Pal Planner engine, run by the VPal Server Command Center (Pal Planner tab) and its watchdog.

  pythonw palplanner.py refresh [--if-changed]   read the world save and rebuild every player's planner
  pythonw palplanner.py lock                     re-lock the planners with the current codes (no save read)

Folders (all inside the server folder's PalPlanner folder):
  players.json   who gets a planner, their code, phone and email (private, stays on this PC)
  site-settings.json  the page's name and who people ask for a code (set in the control panel)
  cache\\        last build for each player (private, stays on this PC)
  web\\          what the family sees; only locked data goes here
  status.json    result of the last run, read by the control panel
"""
import sys, os, re, json, time, gzip, base64, zlib, uuid, glob, collections, datetime, traceback

ENGINE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(ENGINE)                 # ...\PalPlanner
SERVER = os.path.dirname(ROOT)                 # the server folder
sys.path.insert(0, os.environ.get('PALPLANNER_LIB') or os.path.join(ENGINE, 'lib'))
sys.path.insert(0, ENGINE)

PLAYERS_FILE = os.path.join(ROOT, 'players.json')
STATUS_FILE = os.path.join(ROOT, 'status.json')
LOG_FILE = os.path.join(ROOT, 'refresh-log.txt')
CACHE = os.path.join(ROOT, 'cache')
WEB = os.path.join(ROOT, 'web')
SAVE_ROOT = os.environ.get('PALPLANNER_SAVES') or os.path.join(SERVER, 'Pal', 'Saved', 'SaveGames', '0')
ITER = 200000


# ---------------- small helpers ----------------
def log(msg):
    line = time.strftime('%Y-%m-%d %I:%M:%S %p') + '  ' + msg
    try:
        with open(LOG_FILE, 'a', encoding='utf-8') as f: f.write(line + '\n')
        if os.path.getsize(LOG_FILE) > 400_000:      # keep the log small
            with open(LOG_FILE, encoding='utf-8') as f: keep = f.readlines()[-500:]
            with open(LOG_FILE, 'w', encoding='utf-8') as f: f.writelines(keep)
    except OSError:
        pass
    print(line, flush=True)

def read_json(path, default):
    try:
        with open(path, encoding='utf-8-sig') as f: return json.load(f)
    except (OSError, ValueError):
        return default

def write_json(path, data, compact=False):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        if compact: json.dump(data, f, separators=(',', ':'), default=str)
        else: json.dump(data, f, indent=2, default=str)
    for _ in range(10):                            # the web server may be reading the old copy
        try:
            os.replace(tmp, path); return
        except PermissionError:
            time.sleep(0.5)
    os.replace(tmp, path)

def nice_time(ts):
    d = datetime.datetime.fromtimestamp(ts)
    return d.strftime('%Y-%m-%d ') + d.strftime('%I:%M %p').lstrip('0')

class RunLock:
    """Only one refresh at a time (the timer and a button click can overlap)."""
    def __init__(self): self.path = os.path.join(ROOT, 'refresh.lock'); self.fd = None
    def __enter__(self):
        for _ in range(240):
            try:
                self.fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY); return self
            except FileExistsError:
                try:
                    if time.time() - os.path.getmtime(self.path) > 900: os.remove(self.path); continue
                except OSError:
                    pass
                time.sleep(1)
        raise RuntimeError('Another refresh is still running.')
    def __exit__(self, *a):
        try: os.close(self.fd); os.remove(self.path)
        except OSError: pass


# ---------------- reading the save ----------------
def find_world():
    """The world folder whose Level.sav changed most recently."""
    cands = [d for d in glob.glob(os.path.join(SAVE_ROOT, '*')) if os.path.isfile(os.path.join(d, 'Level.sav'))]
    if not cands:
        raise RuntimeError('No world save found in ' + SAVE_ROOT + '. Start the server once so it makes one.')
    return max(cands, key=lambda d: os.path.getmtime(os.path.join(d, 'Level.sav')))

def decompress(data):
    ul, cl = int.from_bytes(data[0:4], 'little'), int.from_bytes(data[4:8], 'little')
    magic, kind, off = data[8:11], data[11], 12
    if magic == b'CNK':
        ul, cl = int.from_bytes(data[12:16], 'little'), int.from_bytes(data[16:20], 'little')
        magic, kind, off = data[20:23], data[23], 24
    if magic == b'PlM':
        import ooz
        raw = ooz.decompress(data[off:off + cl], ul)
        if len(raw) != ul: raise ValueError('save was cut short')
        return raw
    if magic == b'PlZ':
        raw = zlib.decompress(data[off:])
        return zlib.decompress(raw) if kind == 0x32 else raw
    raise ValueError('not a Palworld save file')

def read_sav(path, tries=4):
    """Reads a save the server may be writing right now: retry until two reads agree and it opens."""
    last = None
    for i in range(tries):
        try:
            with open(path, 'rb') as f: data = f.read()
            return decompress(data)
        except Exception as e:                    # half-written file: wait for the autosave to finish
            last = e; time.sleep(3)
    raise RuntimeError(f'Could not read {os.path.basename(path)}: {last}')

def load_world(world):
    from palsav.gvas import GvasFile
    from palsav.paltypes import PALWORLD_TYPE_HINTS, PALWORLD_CUSTOM_PROPERTIES
    core = ('CharacterSaveParameterMap', 'GroupSaveDataMap', 'CharacterContainerSaveData', 'BaseCampSaveData.Value.RawData')
    extra = ('ItemContainerSaveData', '.worldSaveData.MapObjectSaveData', 'GuildItemStorage')     # bags and base chests
    t = time.time()
    raw = read_sav(os.path.join(world, 'Level.sav'))
    try:
        level = GvasFile.read(raw, PALWORLD_TYPE_HINTS, {k: v for k, v in PALWORLD_CUSTOM_PROPERTIES.items() if any(s in k for s in core + extra)}, allow_nan=True)
        items_ok = True
    except Exception as e:                        # a game update changed the chest data: still build everything else
        log(f'Could not read bags and chests this time ({e}); glasses and schematics keep their last state.')
        level = GvasFile.read(raw, PALWORLD_TYPE_HINTS, {k: v for k, v in PALWORLD_CUSTOM_PROPERTIES.items() if any(s in k for s in core)}, allow_nan=True)
        items_ok = False
    w = level.properties['worldSaveData']['value']
    w['_items_ok'] = items_ok
    players = {}
    for f in sorted(glob.glob(os.path.join(world, 'Players', '*.sav'))):
        if '_dps' in os.path.basename(f).lower(): continue
        try:
            g = GvasFile.read(read_sav(f), PALWORLD_TYPE_HINTS, {}, allow_nan=True)
            players[os.path.basename(f)] = g.properties['SaveData']['value']
        except Exception as e:
            log(f'Skipped player file {os.path.basename(f)}: {e}')
    log(f'Read the save in {time.time() - t:.0f} s ({len(players)} player files)')
    return w, players


# ---------------- pals per player ----------------
def build_roster(d, P):
    import planner_core as pc
    PALS = pc._load('pals.json'); PALN = pc.PALN; PASS = pc.PASS; PASSN = pc.PASSN
    WAZA = pc._load('l10n', 'active_skills.json'); WSN = pc._load('l10n', 'work_suitability.json')
    atlas = pc.atlas

    def v(sp, k, default=None):
        x = sp.get(k)
        if x is None: return default
        x = x['value']
        if isinstance(x, dict) and 'value' in x: x = x['value']
        return x

    cm = d['CharacterSaveParameterMap']['value']
    players = {}
    for e in cm:
        sp = e['value']['RawData']['value']['object']['SaveParameter']['value']
        if v(sp, 'IsPlayer'):
            uid = str(e['key']['PlayerUId']['value'])
            players[uid] = {'name': v(sp, 'NickName') or 'Player', 'level': v(sp, 'Level', 1)}
    cont = {}
    for sd in P.values():
        uid = str(sd['PlayerUId']['value'])
        try:
            cont[str(sd['OtomoCharacterContainerId']['value']['ID']['value'])] = (uid, 'party')
            cont[str(sd['PalStorageContainerId']['value']['ID']['value'])] = (uid, 'palbox')
        except (KeyError, TypeError):
            pass
    bases = []
    for b in (d.get('BaseCampSaveData') or {}).get('value') or []:
        try:
            raw = b['value']['RawData']['value']; t = raw['transform']['translation']
            wd = b['value']['WorkerDirector']['value']['RawData']['value']['values']
            wd = bytes(wd) if not isinstance(wd, (bytes, bytearray)) else wd
            bases.append({'id': str(raw['id']), 'x': t['x'], 'y': t['y'], 'wd': wd})
        except (KeyError, TypeError):
            continue

    def ue_bytes(s):
        h = uuid.UUID(s).hex
        return b''.join(bytes.fromhex(h[i:i + 8])[::-1] for i in range(0, 32, 8))
    for c in [str(c['key']['ID']['value']) for c in d['CharacterContainerSaveData']['value']]:
        if c in cont: continue
        for bi, b in enumerate(bases):
            if ue_bytes(c) in b['wd'] or uuid.UUID(c).bytes in b['wd'] or uuid.UUID(c).bytes_le in b['wd']:
                cont[c] = (None, f'base{bi}')
    # guild members share the pals working at the guild's bases
    base_members = {}
    for g in (d.get('GroupSaveDataMap') or {}).get('value') or []:
        try:
            raw = g['value']['RawData']['value']
            members = [str(p['player_uid']) for p in (raw.get('players') or [])]
            for bid in raw.get('base_ids') or []:
                base_members[str(bid)] = members
        except (KeyError, TypeError, AttributeError):
            continue
    TX, TY, SC = 123930.0, 157935.0, 459.0
    for bi, b in enumerate(bases):
        b['gx'] = round((b['y'] - TY) / SC); b['gy'] = round((b['x'] + TX) / SC); b['n'] = bi + 1
    BASES['workers'].clear(); BASES['guilds'] = []
    for g in (d.get('GroupSaveDataMap') or {}).get('value') or []:
        try:
            raw = g['value']['RawData']['value']
            if raw.get('players'):
                BASES['guilds'].append({'admin': str(raw.get('admin_player_uid')), 'bases': [str(x) for x in raw.get('base_ids') or []]})
        except (KeyError, TypeError, AttributeError):
            continue
    EL = pc.EL
    # the save and the game tables don't always agree on capital letters (LazyCatFish vs LazyCatfish)
    lower = {}
    for table in (PALN, PALS, atlas):
        for k in table: lower.setdefault(k.lower(), k)
    def canon(sid):
        k = sid.lower()
        if k.endswith('_otomo'): k = k[:-6]           # summoned copies use the normal pal's data
        return lower.get(k, sid)
    def by_key(table, key):
        return table.get(key) or table.get(next((t for t in table if t.lower() == key.lower()), ''), None)
    roster = collections.defaultdict(list)
    for e in cm:
        sp = e['value']['RawData']['value']['object']['SaveParameter']['value']
        if v(sp, 'IsPlayer'): continue
        cid = v(sp, 'CharacterID') or ''
        alpha = cid.upper().startswith('BOSS_'); sid = canon(cid[5:] if alpha else cid)
        try:
            slot = sp['SlotId']['value']; contid = str(slot['ContainerId']['value']['ID']['value']); idx = slot['SlotIndex']['value']
        except (KeyError, TypeError):
            continue
        owner_uid, kind = cont.get(contid, (None, 'unknown'))
        if owner_uid is None:
            owner_uid = str(v(sp, 'OwnerPlayerUId')) if v(sp, 'OwnerPlayerUId') else None
        owners, shared, caught_by = [owner_uid], False, ''
        # pals nobody owns belong to a base: they stay off everyone's own lists and show only on the guild master's Base tab
        if owner_uid not in players:
            if not kind.startswith('base'): continue
            owners = []
        meta = by_key(PALS, sid) or {}
        at = by_key(atlas, sid) or {}
        name = (by_key(PALN, sid) or {}).get('localized_name') or at.get('name') or sid.replace('_', ' ')
        els = [EL.get(x, x) for x in (meta.get('element_types') or [])] or [EL.get(x, x) for x in (at.get('elements') or [])]
        ws = {WSN.get(k, {}).get('localized_name', k): val for k, val in (at.get('workSuitability') or meta.get('work_suitability') or {}).items() if val}
        passives = [{'id': p, 'name': (PASSN.get(p) or {}).get('localized_name', p), 'desc': (PASSN.get(p) or {}).get('description', ''),
                     'rank': (PASS.get(p) or {}).get('rank', 0)} for p in (sp.get('PassiveSkillList', {}).get('value', {}).get('values') or [])]
        ws = real_work(ws, sp, passives, max(0, (v(sp, 'Rank', 1) or 1) - 1), WSN)
        moves = [(WAZA.get(w) or {}).get('localized_name', w.split('::')[-1]) for w in (sp.get('EquipWaza', {}).get('value', {}).get('values') or [])]
        souls = {nm: v(sp, k, 0) for k, nm in (('Rank_HP', 'HP'), ('Rank_Attack', 'Attack'), ('Rank_Defence', 'Defense'), ('Rank_CraftSpeed', 'Work speed')) if v(sp, k, 0)}
        g = v(sp, 'Gender'); g = 'M' if g and 'Male' in g and 'Female' not in g else ('F' if g and 'Female' in g else '')
        st = game_stats(meta, at, sp, v, passives)
        if kind == 'party': loc = 'Party'
        elif kind == 'palbox': loc = f'Palbox page {idx // 30 + 1}, slot {idx % 30 + 1}'
        elif kind.startswith('base'):
            b = bases[int(kind[4:])]; loc = f"Base {b['n']} at ({b['gx']}, {b['gy']})"
            if shared: loc += ' · shared with your guild' + (f' (caught by {caught_by})' if caught_by else '')
        else: loc = 'Unknown'
        entry = {'species': sid, 'name': name, 'nick': v(sp, 'NickName') or '', 'alpha': alpha, 'lucky': bool(v(sp, 'IsRarePal')),
            'lv': v(sp, 'Level', 1), 'gender': g, 'rank': max(0, (v(sp, 'Rank', 1) or 1) - 1), 'hp': v(sp, 'Talent_HP', 0), 'atk': v(sp, 'Talent_Shot', 0), 'def': v(sp, 'Talent_Defense', 0),
            'passives': passives, 'moves': moves, 'souls': souls, 'elements': els, 'work': ws, 'kind': kind, 'loc': loc, 'slot': idx,
            'base': {'hp': at.get('hp'), 'attack': at.get('attack'), 'defense': at.get('defense')}, 'breedRank': at.get('breedingRank'), 'nocturnal': at.get('nocturnal'), 'shared': shared,
            'st': st}
        for o in owners:
            roster[o].append(dict(entry))
        if not owners:
            BASES['workers'][kind].append(dict(entry))
    BASES['bases'] = [{'key': f'base{bi}', 'id': b['id'], 'gx': b['gx'], 'gy': b['gy']} for bi, b in enumerate(bases)]
    return players, roster


def real_work(ws, sp, passives, stars, WSN):
    """Work levels as the pal really has them in 1.0 (max 10): the species' levels, plus Applied Technique Books
    (stored in the save), plus work-level passives, plus condenser stars. Stars 1-3 each add +1 starting from the
    pal's highest skill and working down; the 4th star adds +1 to every skill."""
    import planner_core as pc
    nm = lambda k: (WSN.get(k) or {}).get('localized_name', k)
    out = dict(ws)
    try:
        for e in sp.get('GotWorkSuitabilityAddRankList', {}).get('value', {}).get('values') or []:
            k = nm(e['WorkSuitability']['value']['value'].split('::')[-1])
            out[k] = out.get(k, 0) + int(e['Rank']['value'] or 0)
    except (KeyError, TypeError, AttributeError):
        pass
    for x in passives:
        for t, val in pc.pas_effects(x['id']).items():
            if t.startswith('WorkSuitabilityAddRank_'):
                k = nm(t[len('WorkSuitabilityAddRank_'):]); out[k] = out.get(k, 0) + int(val)
    order = sorted(out, key=lambda k: -ws.get(k, out[k]))
    for i in range(min(stars, 3)):
        if order: out[order[i % len(order)]] += 1
    if stars >= 4:
        for k in out: out[k] += 1
    return {k: min(10, lv) for k, lv in out.items() if lv > 0}


# the guild's bases and the pals working there, filled in by build_roster for the guild master's Base tab
BASES = {'bases': [], 'workers': collections.defaultdict(list), 'guilds': [], 'buildings': {}}

def base_buildings(d):
    """How many of each building every base has (only buildings that use workers, power or make something)."""
    out = collections.defaultdict(collections.Counter)
    mo = (d.get('MapObjectSaveData') or {}).get('value') or {}
    for m in (mo.get('values') if isinstance(mo, dict) else mo) or []:
        try:
            bid = str(m['Model']['value']['RawData']['value'].get('base_camp_id_belong_to'))
            if bid != ZERO: out[bid][m['MapObjectId']['value']] += 1
        except (KeyError, TypeError, AttributeError):
            continue
    return out


def worker_limit():
    """Pals allowed per base, from the server's settings file (None if it can't be read)."""
    import re
    for name in ('WindowsServer', 'LinuxServer'):
        f = os.path.join(SERVER, 'Pal', 'Saved', 'Config', name, 'PalWorldSettings.ini')
        try:
            m = re.search(r'BaseCampWorkerMaxNum=(\d+)', open(f, encoding='utf-8', errors='replace').read())
            if m: return int(m.group(1))
        except OSError:
            continue
    return None


BOND = [0, 6000, 13000, 21000, 30000, 40000, 55000, 80000, 110000, 150000, 200000]   # trust points per rank (1.0.5)

def game_stats(meta, at, sp, v, passives):
    """HP, Attack and Defense as the pal's status screen shows them (1.0 formula, checked against the HP stored in the save).
    Returns [hp, attack, defense, species base hp, base attack, base defense], or None if the species is unknown."""
    import math
    sc = meta.get('scaling') or {}
    bh, ba, bd = sc.get('hp') or at.get('hp'), sc.get('attack') or at.get('attack'), sc.get('defense') or at.get('defense')
    if not (bh and ba and bd): return None
    lv = v(sp, 'Level', 1) or 1
    pts = v(sp, 'FriendshipPoint', 0) or 0
    f = max(i for i, p in enumerate(BOND) if pts >= p)
    stars = max(0, (v(sp, 'Rank', 1) or 1) - 1)
    def stage(base, grow, iv, soul, mul, add, plus=0):
        b = base + (grow or 0) * f
        x = math.floor((b * (1 + iv * 0.003) + plus) * mul * lv + add)
        x = math.floor(x * (1 + stars * 0.05))
        return math.floor(x * (1 + soul * 0.03))
    hp = stage(bh, meta.get('friendship_hp'), v(sp, 'Talent_HP', 0) or 0, v(sp, 'Rank_HP', 0) or 0, 0.5, 500, 10)
    atk = stage(ba, meta.get('friendship_shotattack'), v(sp, 'Talent_Shot', 0) or 0, v(sp, 'Rank_Attack', 0) or 0, 0.075, 100)
    df = stage(bd, meta.get('friendship_defense'), v(sp, 'Talent_Defense', 0) or 0, v(sp, 'Rank_Defence', 0) or 0, 0.075, 50)
    import planner_core as pc
    pct = collections.Counter()
    for p in passives:
        for e in (pc.PASS.get(p['id']) or {}).get('effects', []):
            if e.get('target') in ('ToSelf', None) and e.get('type') in ('MaxHP', 'ShotAttack', 'Defense'):
                pct[e['type']] += e.get('value') or 0
    m = lambda k: max(0.10, 1 + pct[k] / 100)
    return [math.floor(hp * m('MaxHP')), math.floor(atk * m('ShotAttack')), math.floor(df * m('Defense')), bh, ba, bd]


# ---------------- what each player carries (glasses, schematics) ----------------
ZERO = '00000000-0000-0000-0000-000000000000'
GLASSES = ('Accessory_TalentChecker', 'Accessory_NonkChecker')

def build_items(d, P):
    """Per player: items in their bag (all inventory tabs), what they wear, and what sits in their guild's base chests."""
    cont = {}
    for e in (d.get('ItemContainerSaveData') or {}).get('value') or []:
        try:
            items = collections.Counter()
            for s in e['value']['Slots']['value']['values']:
                r = s['RawData']['value']
                if r.get('count'): items[r['item']['static_id']] += r['count']
            cont[str(e['key']['ID']['value'])] = items
        except (KeyError, TypeError, AttributeError):
            continue
    guild_of, chests = {}, collections.defaultdict(set)
    for g in (d.get('GroupSaveDataMap') or {}).get('value') or []:
        try:
            raw = g['value']['RawData']['value']
            for p in raw.get('players') or []: guild_of[str(p['player_uid'])] = str(g['key'])
        except (KeyError, TypeError, AttributeError):
            continue
    mo = (d.get('MapObjectSaveData') or {}).get('value') or {}
    for m in (mo.get('values') if isinstance(mo, dict) else mo) or []:
        try:
            gid = str(m['Model']['value']['RawData']['value'].get('group_id_belong_to'))
            if gid == ZERO: continue
            for mod in m['ConcreteModel']['value']['ModuleMap']['value'] or []:
                if str(mod['key']).endswith('ItemContainer'):
                    chests[gid].add(str(mod['value']['RawData']['value'].get('target_container_id')))
        except (KeyError, TypeError, AttributeError):
            continue
    for g in (d.get('GuildExtraSaveDataMap') or {}).get('value') or []:
        try: chests[str(g['key'])].add(str(g['value']['GuildItemStorage']['value']['RawData']['value']['container_id']))
        except (KeyError, TypeError, AttributeError): continue
    out = {}
    for sd in P.values():
        uid = str(sd['PlayerUId']['value'])
        bag, worn, chest = collections.Counter(), collections.Counter(), collections.Counter()
        for k, val in ((sd.get('InventoryInfo') or {}).get('value') or {}).items():
            try: cid = str(val['value']['ID']['value'])
            except (KeyError, TypeError): continue
            bag.update(cont.get(cid) or {})
            if k == 'PlayerEquipArmorContainerId': worn.update(cont.get(cid) or {})
        for cid in chests.get(guild_of.get(uid), ()):
            chest.update(cont.get(cid) or {})
        out[uid] = {'bag': bag, 'worn': worn, 'chest': chest}
    return out

def glasses_info(inv):
    for where, label in (('worn', 'you’re wearing them'), ('bag', 'they’re in your bag'), ('chest', 'they’re in a base chest')):
        hit = sorted(i for i in inv[where] if i.startswith(GLASSES))
        if hit:
            nm = "Pal Tamer's Glasses" if 'Nonk' in hit[0] else 'Ability Glasses'
            return {'has': True, 'name': nm, 'where': label}
    return {'has': False}


def tech_info(sd):
    """The Technologies a player has unlocked, and the points they have left to spend."""
    if not sd: return None
    try:
        names = sd['UnlockedRecipeTechnologyNames']['value']['values']
    except (KeyError, TypeError):
        return None
    pts = lambda k: ((sd.get(k) or {}).get('value') or 0)
    return {'t': sorted({str(n) for n in names}), 'p': pts('TechnologyPoint'), 'a': pts('bossTechnologyPoint')}


# ---------------- planner for each player ----------------
FLAG = {'ft': 'FastTravelPointUnlockFlag', 'watch': 'FastTravelPointUnlockFlag', 'tower': 'TowerBossDefeatFlag', 'alpha': 'NormalBossDefeatFlag',
        'ruin': 'ItemPickupObtainForInstanceFlag', 'effigy': 'RelicObtainForInstanceFlag', 'journal': 'NoteObtainForInstanceFlag'}

def build_planners(players, roster, P, saved, inv=None):
    import planner_core as pc
    psave = {str(sd['PlayerUId']['value']): sd for sd in P.values()}
    out = {}
    for uid, info in players.items():
        pals = [dict(p, i=i) for i, p in enumerate(roster.get(uid, []))]
        rd = ((psave.get(uid) or {}).get('RecordData') or {}).get('value') or {}
        prog = {}
        for c, f in FLAG.items():
            flags = {x['key'] for x in ((rd.get(f) or {}).get('value') or []) if x.get('value')}
            keys = {p[4] for R in pc.REGIONS.values() for p in R['pts'].get(c, []) if p[4]}
            if c in ('ft', 'watch'): flags = {x.upper() for x in flags}
            prog[c] = sorted(flags & keys)
        # what this player can reach: World Tree after catching Panthalus, Sunreach after the Feybreak Tower
        tree_ft = {p[4] for p in pc.TREE['pts'].get('ft', [])}
        sky_ft = {p[4] for p in pc.MAP['pts']['ft'] if pc.area_of(p[0], p[1]) == 'sky'}
        owns = {p['species'] for p in pals if not p.get('shared')}
        tree_ok = 'KingWhale' in owns or bool(tree_ft & set(prog['ft']))
        sky_ok = 'BOSS_BATTLE_NAME_VikingBoss' in prog['tower'] or bool(sky_ft & set(prog['ft']))
        pc.set_access(tree_ok, sky_ok, info['level'])
        crews = pc.build_crews(pals)
        try:
            import farming
            mine = (inv or {}).get(uid)
            gear = {i for i in mine['bag'] if i.startswith('SkillUnlock_')} if mine else None
            crews += farming.build(pals, gear)
        except Exception as e:                        # field parties are extras: never stop a refresh
            log(f'Could not build field parties: {e}')
        attack = pc.build_attack(pals)
        breeding = pc.build_breeding(pals, crews, attack)
        base_tab = None
        guild = next((g for g in BASES['guilds'] if g['admin'] == uid), None)
        if guild:                                     # only the guild master gets the Base tab
            try:
                import guildbase
                mine_b = [b for b in BASES['bases'] if b['id'] in guild['bases']]
                for n, b in enumerate(mine_b): b['name'] = f'Base {n + 1}'
                for b in mine_b: b['build'] = dict(BASES['buildings'].get(b['id']) or {})
                base_tab = guildbase.build(pals, BASES['workers'], mine_b, worker_limit())
            except Exception as e:
                log(f'Could not build the Base tab: {e}')
                base_tab = {'error': f'{type(e).__name__}: {e}'}
        slim = [{k: p[k] for k in ('i', 'name', 'nick', 'species', 'lv', 'gender', 'alpha', 'lucky', 'rank', 'hp', 'atk', 'def', 'elements', 'work', 'loc', 'kind', 'souls', 'moves', 'shared', 'st')} |
                {'passives': [{'n': x['name'], 'd': x['desc'], 'r': x['rank']} for x in p['passives']]} for p in pals]
        out[uid] = {'player': info['name'], 'real': '', 'level': info['level'], 'saved': saved,
                    'pals': slim, 'crews': crews, 'attack': attack, 'breeding': breeding, 'progress': prog,
                    'access': {'tree': tree_ok, 'sky': sky_ok}}
        if base_tab: out[uid]['base'] = base_tab
        mine = (inv or {}).get(uid)
        if mine:
            out[uid]['glasses'] = glasses_info(mine)
            out[uid]['schem'] = {i: [mine['bag'].get(i, 0), mine['chest'].get(i, 0)]
                                 for i in set(mine['bag']) | set(mine['chest']) if i.startswith('Blueprint')}
            # everything else they carry or keep in the guild's base chests (the Recipes tab shows what they have)
            out[uid]['inv'] = {i: [mine['bag'].get(i, 0), mine['chest'].get(i, 0)]
                               for i in set(mine['bag']) | set(mine['chest']) if not i.startswith('Blueprint')}
        tech = tech_info(psave.get(uid))
        if tech: out[uid]['tech'] = tech
    return out


# ---------------- locking with each person's code ----------------
def lock_all():
    """Writes web\\planners.enc.json: one locked copy per person, opened only by their code."""
    from Crypto.Cipher import AES
    import hashlib
    cfg = read_json(PLAYERS_FILE, {'players': []})
    index = read_json(os.path.join(CACHE, 'index.json'), {'players': []})
    by_uid = {p['uid']: p for p in index['players']}
    by_name = {p['name'].lower(): p for p in index['players']}
    entries, locked, missing = [], [], []
    for person in cfg.get('players', []):
        code = (person.get('code') or '').strip().lower()
        if not code: continue
        hit = by_uid.get(person.get('uid') or '') or by_name.get((person.get('game') or '').lower())
        path = os.path.join(CACHE, hit['uid'] + '.json') if hit else ''
        if not hit or not os.path.isfile(path):
            missing.append(person.get('real') or person.get('game')); continue
        data = read_json(path, None)
        if data is None: missing.append(person.get('real') or person.get('game')); continue
        data['real'] = person.get('real') or ''
        pt = gzip.compress(json.dumps(data, separators=(',', ':'), default=str).encode('utf-8'), 9)
        salt, iv = os.urandom(16), os.urandom(12)
        key = hashlib.pbkdf2_hmac('sha256', code.encode('utf-8'), salt, ITER, 32)
        ct, tag = AES.new(key, AES.MODE_GCM, nonce=iv).encrypt_and_digest(pt)
        entries.append({'salt': base64.b64encode(salt).decode(), 'iv': base64.b64encode(iv).decode(), 'ct': base64.b64encode(ct + tag).decode()})
        locked.append(person.get('real') or person.get('game'))
    import random
    random.SystemRandom().shuffle(entries)        # order gives nothing away
    os.makedirs(WEB, exist_ok=True)
    write_json(os.path.join(WEB, 'planners.enc.json'), {'v': 1, 'iter': ITER, 'entries': entries}, compact=True)
    return locked, missing


# ---------------- commands ----------------
def save_stamp(world):
    st = os.stat(os.path.join(world, 'Level.sav'))
    return f'{int(st.st_mtime)}:{st.st_size}'

SITE_SETTINGS = os.path.join(ROOT, 'site-settings.json')


def ini_value(key):
    """One value from the server's PalWorldSettings.ini, or None."""
    for sub in ('WindowsServer', 'LinuxServer'):
        try:
            with open(os.path.join(SERVER, 'Pal', 'Saved', 'Config', sub, 'PalWorldSettings.ini'), encoding='utf-8-sig', errors='replace') as f:
                txt = f.read()
        except OSError:
            continue
        m = re.search(r'[(,]\s*' + re.escape(key) + r'\s*=\s*(?:"([^"]*)"|([^,)]*))', txt)
        if m: return (m.group(1) if m.group(1) is not None else m.group(2)).strip()
    return None


def write_site():
    """web/site.json: the page's name, who to ask for a code and the egg hatching time, for every phone (public, no
    secrets). Also keeps the home screen name in manifest.json in step with the page's name."""
    s = read_json(SITE_SETTINGS, {}) or {}
    name = (str(s.get('name') or '').strip() or ini_value('ServerName') or '').strip()[:40]
    try: egg = round(float(ini_value('PalEggDefaultHatchingTime')), 2)
    except (TypeError, ValueError): egg = None
    site = {'name': name, 'owner': str(s.get('owner') or '').strip()[:40], 'eggHours': egg}
    if read_json(os.path.join(WEB, 'site.json'), None) != site:
        write_json(os.path.join(WEB, 'site.json'), site)
    mp = os.path.join(WEB, 'manifest.json')
    man = read_json(mp, None)
    if isinstance(man, dict) and name:
        want = {'name': f'{name} Pal Planner', 'short_name': f'{name} Pals'[:24],
                'description': f'Your pals, crews, boss teams and map for the {name} Palworld server.'}
        if any(man.get(k) != v for k, v in want.items()):
            man.update(want)
            write_json(mp, man)


def site_safely():
    try: write_site()
    except Exception as e: log(f'Could not write site.json: {e}')


def cmd_refresh(if_changed):
    os.makedirs(CACHE, exist_ok=True)
    site_safely()
    status = read_json(STATUS_FILE, {})
    with RunLock():
        world = find_world()
        stamp = save_stamp(world)
        if if_changed and status.get('ok') and status.get('stamp') == stamp:
            return status                                   # nothing new since last time
        w, P = load_world(world)
        players, roster = build_roster(w, P)
        saved = nice_time(os.path.getmtime(os.path.join(world, 'Level.sav')))
        try:
            inv = build_items(w, P) if w.get('_items_ok') else None
            if w.get('_items_ok'): BASES['buildings'] = base_buildings(w)
        except Exception as e:                       # glasses and schematics are extras: never let them stop a refresh
            log(f'Could not read bags and chests: {e}'); inv = None
        planners = build_planners(players, roster, P, saved, inv)
        index = []
        for uid, data in planners.items():
            if 'schem' not in data:                  # bags and chests couldn't be read: keep what the last refresh found
                old = read_json(os.path.join(CACHE, uid + '.json'), {})
                for k in ('glasses', 'schem', 'inv'):
                    if k in old: data[k] = old[k]
            write_json(os.path.join(CACHE, uid + '.json'), data, compact=True)
            index.append({'uid': uid, 'name': data['player'], 'level': data['level'], 'pals': len(data['pals'])})
        index.sort(key=lambda p: p['name'].lower())
        write_json(os.path.join(CACHE, 'index.json'), {'players': index, 'saved': saved})
        locked, missing = lock_all()
        status = {'ok': True, 'when': nice_time(time.time()), 'saved': saved, 'stamp': stamp, 'players': index,
                  'locked': locked, 'missing': missing, 'message': f'Updated {len(locked)} planner(s) from the {saved} save.'}
        write_json(STATUS_FILE, status)
        log(status['message'] + (f" No pals found yet for: {', '.join(missing)}." if missing else ''))
        return status

def cmd_lock():
    site_safely()
    with RunLock():
        locked, missing = lock_all()
    status = read_json(STATUS_FILE, {})
    status.update({'locked': locked, 'missing': missing, 'lockedAt': nice_time(time.time())})
    write_json(STATUS_FILE, status)
    log(f"Locked planners for {', '.join(locked) or 'nobody'}" + (f"; waiting on a refresh for {', '.join(missing)}" if missing else ''))
    return status

def main():
    if sys.stdout is None: sys.stdout = open(os.devnull, 'w')     # pythonw has no console
    if sys.stderr is None: sys.stderr = open(os.devnull, 'w')
    args = sys.argv[1:]
    cmd = args[0] if args else 'refresh'
    try:
        if cmd == 'refresh': cmd_refresh('--if-changed' in args)
        elif cmd == 'lock': cmd_lock()
        else: print(__doc__); return 2
        return 0
    except Exception as e:
        msg = str(e) or e.__class__.__name__
        log('FAILED: ' + msg + '\n' + traceback.format_exc())
        status = read_json(STATUS_FILE, {})
        status.update({'ok': False, 'when': nice_time(time.time()), 'message': 'Refresh failed: ' + msg})
        try: write_json(STATUS_FILE, status)
        except OSError: pass
        return 1

if __name__ == '__main__':
    sys.exit(main())
