"""The guild master's Base tab: every pal the guild master can put to work (their own pals plus the pals
already working at the guild's bases), rated for each base job, broken down by base, with swap ideas
and the base-wide buff pals.

Ratings are mostly the pal's real work level against the best reachable level for that job (best species + 2
from condensing, max 10), nudged up a little by work-speed passives, night work and stars. Lists are ordered by
planner_core.work_score, which follows 1.0's steep work-level curve (a Lv 10 worker does far more than a Lv 8).
Work levels already include condenser stars, Applied Technique Books and work-level passives (palplanner.real_work).
"""
import planner_core as pc

WSN = pc._load('l10n', 'work_suitability.json')
JOB_ORDER = ['Mining', 'Lumbering', 'Kindling', 'Handiwork', 'Generating Electricity', 'Medicine Production', 'Cooling',
             'Planting', 'Watering', 'Gathering', 'Transporting', 'Farming', 'Crude Oil Extraction']
KEY = {v['localized_name']: k for k, v in WSN.items()}            # 'Mining' -> 'Mining', 'Handiwork' -> 'Handcraft'
PT = pc._load('partner.json')['pals']
BUILD = pc._load('buildings.json')        # 1.0.5 buildings: name, jobs they need, worker slots, power use, what they make

MAXLV = {}
for sid, a in pc.atlas.items():
    if not pc.catchable(a.get('name') or sid): continue
    for k, lv in (a.get('workSuitability') or {}).items():
        nm = (WSN.get(k) or {}).get('localized_name', k)
        MAXLV[nm] = max(MAXLV.get(nm, 0), lv)

BUFF_TEXT = {
    'FullStomatch_Decrease': 'base pals get hungry {a}% slower',
    'Sanity_Decrease': 'base pals’ sanity drains {a}% slower',
    'BreedSpeed_InBaseCamp': 'the Breeding Farm makes eggs {v}% faster',
    'PalEggHatchingSpeed': 'eggs hatch {v}% faster',
    'FarmCropGrowupSpeed': 'crops grow {v}% faster',
    'FarmCropHarvestNumRate': '{v}% more crops per harvest',
    'CraftSpeed': 'Anubis at the base work {v}% faster',
}


def craft_pct(p):
    return sum(pc.pas_effects(x['id']).get('CraftSpeed', 0) for x in p['passives'])

def night(p):
    return bool((pc.atlas.get(p['species']) or {}).get('nocturnal')) or any(x['id'] in ('Nocturnal', 'Vampire') for x in p['passives'])

def cap(job):
    """The best level you can realistically reach: the best species' level plus condensing, max 10."""
    return min(10, MAXLV.get(job, 8) + 2)

def rate(p, job):
    """0-1+: mostly the work level against the cap, nudged by work-speed passives, night work and stars."""
    lv = p['work'].get(job, 0)
    if not lv: return 0
    nudge = min(1.15, 1 + 0.3 * craft_pct(p) / 100 + (0.05 if night(p) else 0) + 0.02 * p['rank'])
    return round(lv / cap(job) * nudge, 3)

def order_key(p, job):
    return pc.work_score(p, job)

def slim(p, where, pi):
    """What the page needs to show a pal and its job ratings."""
    jobs = {j: [p['work'][j], rate(p, j)] for j in JOB_ORDER if p['work'].get(j)}
    best = sorted(jobs.items(), key=lambda kv: -kv[1][1])
    flags = [x['name'] for x in p['passives'] if pc.pas_effects(x['id']).get('CraftSpeed')]
    return {'pi': pi, 'name': p['name'], 'nick': p['nick'], 'species': p['species'], 'lv': p['lv'], 'rank': p['rank'],
            'alpha': p['alpha'], 'lucky': p['lucky'], 'gender': p['gender'], 'elements': p['elements'], 'loc': p['loc'],
            'where': where, 'jobs': jobs, 'best': [best[0][0], best[0][1][1]] if best else None,
            'best2': [best[1][0], best[1][1][1]] if len(best) > 1 else None,
            'cs': craft_pct(p), 'night': night(p), 'pas': flags}

def buff_list(pool, bases):
    out = []
    for sid, d in PT.items():
        for t, inv in d.get('inv', {}).items():
            if inv != 'InBaseCamp': continue
            name = pc.pal_name(sid)
            mine = [i for i, p in enumerate(pool) if p['species'] == sid]
            best = max(mine, key=lambda i: pool[i]['rank'], default=None)
            v = d['fx'][t][min(pool[best]['rank'], 4)] if best is not None else d['fx'][t][0]
            if t.startswith('WorkSuitabilityAddRank_'):
                job = (WSN.get(t.split('_', 1)[1]) or {}).get('localized_name', t.split('_', 1)[1])
                text, job_of = f'+{v:g} {job} for every other pal at the base', job
            else:
                text, job_of = BUFF_TEXT.get(t, t).replace('{v}', f'{v:g}').replace('{a}', f'{abs(v):g}'), ''
            at = sorted({pool[i]['where'] for i in mine if pool[i]['where'].startswith('base')})
            entry = {'name': name, 'species': sid, 'text': text, 'job': job_of, 'have': mine[:6], 'at': at}
            if not mine:
                entry['find'] = [x for x in pc.where_to_catch(name) if 'gx' in x][:2] or [x for x in pc.where_to_catch(name) if x.get('kind') == 'Later'][:1]
            out.append(entry)
    out.sort(key=lambda e: (not e['job'], JOB_ORDER.index(e['job']) if e['job'] in JOB_ORDER else 99, e['name']))
    return out

# pals that make each other (or the whole base) better; values come from the 1.0.5 partner-skill tables
SYNERGY = [
    {'title': 'Sekhmet with Anubis', 'sp': ['Sekhmet', 'Anubis'], 'fx': ('Sekhmet', 'CraftSpeed'),
     'text': 'Every Anubis at the same base works {v}% faster. Anubis is already a top Handiwork and Mining worker, so this pair is a big boost to any crafting base.'},
    {'title': 'Jelliette and Jellroy together', 'sp': ['JellyfishFairy', 'JellyfishGhost'], 'fx': ('JellyfishFairy', 'CraftSpeed'),
     'text': 'When both live at the same base, each one waters {v}% faster.'},
    {'title': 'Ribbuny Botan on the weapon benches', 'sp': ['PinkRabbit_Grass'], 'fx': ('PinkRabbit_Grass', 'CraftSpeed'),
     'text': '+{v}% efficiency while it works a Weapon Workbench or Weapon Assembly Line. Pin it there with the Monitoring Stand.'},
    {'title': 'Crop farm stack', 'sp': ['LeafPrincess', 'BlueberryFairy', 'FlowerDoll', 'ClioneTwins', 'CloverFairy'],
     'text': 'Lullu makes crops grow faster, Prunelia adds more to every harvest, and Petallia, Amione and Clovee give +1 Planting, Watering and Gathering to every other pal at the base. Put them all at your farming base.'},
    {'title': 'Breeding and hatching pair', 'sp': ['Plesiosaur', 'ThunderFluffyBird'],
     'text': 'Braloha makes the Breeding Farm produce eggs faster and Dynamoff makes eggs hatch faster. Keep both at the base with your Breeding Farm and incubators.'},
    {'title': 'Keep workers fed and happy', 'sp': ['SweetsSheep_Ground', 'SweetsSheep', 'MushroomDragon_Dark'],
     'text': 'Woolipop (Terra is stronger) makes base pals get hungry slower, and Shroomer Noct slows their sanity loss, so they work longer between meals and hot-spring breaks.'},
]

def synergy_list(pool):
    out = []
    for syn in SYNERGY:
        txt = syn['text']
        if syn.get('fx'):
            sid, t = syn['fx']
            mine = [p for p in pool if p['species'] == sid]
            r = max((p['rank'] for p in mine), default=0)
            v = ((PT.get(sid) or {}).get('fx', {}).get(t) or [0])[min(r, 4)]
            txt = txt.replace('{v}', f'{v:g}')
        have = []
        for sid in syn['sp']:
            idx = [i for i, p in enumerate(pool) if p['species'] == sid]
            have.append({'name': pc.pal_name(sid), 'have': len(idx) > 0, 'at': sorted({pool[i]['where'] for i in idx if pool[i]['where'].startswith('base')})})
        out.append({'title': syn['title'], 'text': txt, 'pals': have})
    return out

def build(own, workers, bases, worker_max=None):
    """own: the guild master's roster. workers: {'base0': [entries], ...}. bases: [{'key','name','gx','gy'}, ...] for this guild."""
    pool = [slim(p, 'party' if p['kind'] == 'party' else 'palbox', p['i']) for p in own if not str(p['kind']).startswith('base')]
    base_out = []
    for b in bases:
        idx = []
        for p in workers.get(b['key'], []):
            idx.append(len(pool)); pool.append(slim(p, b['key'], -1))
        # pals the guild master owns that are working at this base
        for p in own:
            if p['kind'] == b['key']:
                idx.append(len(pool)); pool.append(slim(p, b['key'], p['i']))
        try: ft = pc.nearest_ft(b['gx'], b['gy'], 'main')
        except Exception: ft = ''
        build = {k: n for k, n in (b.get('build') or {}).items() if k in BUILD}
        base_out.append({'key': b['key'], 'name': b['name'], 'gx': b['gx'], 'gy': b['gy'], 'ft': ft, 'workers': idx, 'build': build})
    # swap ideas: a stronger pal for the same job that is sitting in your Palbox or party
    spare = [i for i, p in enumerate(pool) if p['where'] in ('palbox', 'party') and p['best']]
    taken = set()
    for b in base_out:
        swaps = []
        for wi in sorted(b['workers'], key=lambda i: (pool[i]['best'] or ['', 0])[1]):
            w = pool[wi]
            if not w['best']: continue
            job, r = w['best']
            cands = sorted((i for i in spare if i not in taken and pool[i]['jobs'].get(job) and pool[i]['jobs'][job][1] >= r + 0.15),
                           key=lambda i: -pool[i]['jobs'][job][1])
            if cands:
                taken.add(cands[0]); swaps.append([wi, cands[0], job])
            if len(swaps) >= 8: break
        b['swaps'] = swaps
    comm = pc.COMMUNITY.get('base_tips') or {}
    srcs = pc.COMMUNITY.get('sources') or {}
    tips = [{'title': t['title'], 'text': t['text'], 'src': [dict(srcs[k], k=k) for k in t.get('src', []) if k in srcs]} for t in comm.get('tips', [])]
    return {'pals': pool, 'bases': base_out, 'jobs': [j for j in JOB_ORDER if any(j in p['jobs'] for p in pool)],
            'cap': {j: cap(j) for j in JOB_ORDER}, 'buffs': buff_list(pool, base_out), 'synergy': synergy_list(pool),
            'tips': tips, 'workerMax': worker_max,
            'bcat': {k: BUILD[k] for k in sorted({k for b in base_out for k in b['build']})},
            'focusTips': pc.COMMUNITY.get('focus_tips') or {}, 'sources': pc.COMMUNITY.get('sources') or {}}
