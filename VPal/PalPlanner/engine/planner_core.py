"""Planner rules for the Pal Planner: best crews for every job, boss teams, breeding plans
and where to catch pals. Used by palplanner.py."""
import json, math, collections, os

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data')
def _load(*parts):
    with open(os.path.join(DATA, *parts), encoding='utf-8') as f:
        return json.load(f)

MAP = _load('mapdata.json')
PASS = _load('passive_skills.json'); PASSN = _load('l10n', 'passive_skills.json')
BREED = _load('breeding.json'); PALN = _load('l10n', 'pals.json')
atlas = _load('atlas_pals.json')
try: COMMUNITY = _load('community.json')
except (OSError, ValueError): COMMUNITY = {}
def community(section, key):
    """What guides and wikis recommend for this fight or job: picks (pal names), notes and source links."""
    c = (COMMUNITY.get(section) or {}).get(key)
    if not c: return None
    srcs = COMMUNITY.get('sources') or {}
    return {'picks': c.get('picks') or [], 'notes': c.get('notes') or [], 'buff': c.get('buff') or '',
            'src': [dict(srcs[k], k=k) for k in c.get('src') or [] if k in srcs]}
byname = {a['name']: a for a in atlas.values()}
EL = {'Normal': 'Neutral', 'Earth': 'Ground', 'Leaf': 'Grass', 'Electricity': 'Electric', 'Ice': 'Ice', 'Fire': 'Fire', 'Water': 'Water', 'Dragon': 'Dragon', 'Dark': 'Dark'}
ELI = {v: k for k, v in EL.items()}
BEATS = {'Fire': {'Grass', 'Ice'}, 'Water': {'Fire'}, 'Electric': {'Water'}, 'Ground': {'Electric'}, 'Grass': {'Ground'}, 'Ice': {'Dragon'}, 'Dragon': {'Dark'}, 'Dark': {'Neutral'}, 'Neutral': set()}
WS = {'Collection': 'Gathering', 'Cool': 'Cooling', 'Deforest': 'Lumbering', 'EmitFlame': 'Kindling', 'GenerateElectricity': 'Generating Electricity', 'Handcraft': 'Handiwork', 'Mining': 'Mining', 'MonsterFarm': 'Farming', 'OilExtraction': 'Crude Oil Extraction', 'ProductMedicine': 'Medicine Production', 'Seeding': 'Planting', 'Transport': 'Transporting', 'Watering': 'Watering'}
TX, TY, SC = 123930.0, 157935.0, 459.0

def pas_effects(pid):
    e = collections.Counter()
    for x in (PASS.get(pid) or {}).get('effects', []):
        e[x['type']] += x['value']
    return e

def pal_name(sid):
    return (PALN.get(sid) or {}).get('localized_name') or (atlas.get(sid) or {}).get('name') or sid

def elements_of(sid):
    a = atlas.get(sid)
    return [EL.get(e, e) for e in (a or {}).get('elements', [])]

def emult(att_els, def_els, boosts=None):
    """Best damage multiplier this attacker gets against a defender, over its own elements."""
    best = 0
    for ae in att_els or ['Neutral']:
        m = 1.0
        for de in def_els:
            if de in BEATS.get(ae, set()): m *= 2.0
            elif ae in BEATS.get(de, set()): m *= 0.5
        if boosts: m *= 1 + boosts.get(ae, 0) / 100
        best = max(best, m)
    return best

def weak_to(pal_els, boss_els):
    return [b for b in boss_els for p in pal_els if p in BEATS.get(b, set())]

# ---------- where to catch a species (wild areas + alpha) ----------
TREE = MAP.get('tree') or {'pts': {}, 'pals': {}}
REGIONS = {'main': MAP, 'tree': TREE}
def nearest_ft(gx, gy, region='main'):
    pts = REGIONS[region]['pts'].get('ft') or MAP['pts']['ft']
    best = min(pts, key=lambda p: (p[0] - gx) ** 2 + (p[1] - gy) ** 2)
    return best[2]

def catchable(name):
    return any(name in R['pals'] or any(p[2] == 'Alpha ' + name for p in R['pts'].get('alpha', [])) for R in REGIONS.values())

# ---------- what this player can reach right now ----------
# Set per player by palplanner.py from their own save: the World Tree opens after catching Panthalus,
# Sunreach (the sky islands) after the Feybreak Tower. Spots far above the player's level count as later.
ACCESS = {'tree': True, 'sky': True, 'level': 80}
SKY_BOX = (-600.0, -145.0, -1610.0, -1310.0)        # in-game X min/max, Y min/max of Sunreach
def set_access(tree, sky, level):
    ACCESS.update(tree=bool(tree), sky=bool(sky), level=int(level or 1))

def area_of(gx, gy, region='main'):
    if region == 'tree': return 'tree'
    if SKY_BOX[0] <= gx <= SKY_BOX[1] and SKY_BOX[2] <= gy <= SKY_BOX[3]: return 'sky'
    return 'main'

def spot_open(gx, gy, region, lv):
    a = area_of(gx, gy, region)
    if a == 'tree' and not ACCESS['tree']: return False, 'Only lives in the World Tree, which opens after you catch Panthalus.'
    if a == 'sky' and not ACCESS['sky']: return False, 'Only lives in Sunreach, which opens after you beat the Feybreak Tower.'
    if lv and lv > ACCESS['level'] + 5: return False, f"Lv {lv}, too strong for your Lv {ACCESS['level']} team for now."
    return True, ''

def reachable(name):
    return any('gx' in w for w in where_to_catch(name))

def areas_for(name, region='main'):
    cells = REGIONS[region]['pals'].get(name) or []
    groups = []
    for c in sorted(cells, key=lambda c: -c[5]):
        for g in groups:
            if math.hypot(g['gx'] - c[0], g['gy'] - c[1]) < 70:
                g['n'] += c[5]; g['lmin'] = min(g['lmin'], c[2]); g['lmax'] = max(g['lmax'], c[3]); break
        else:
            groups.append({'gx': c[0], 'gy': c[1], 'n': c[5], 'lmin': c[2], 'lmax': c[3]})
    groups.sort(key=lambda g: -g['n'])
    return groups

def where_to_catch(name):
    """Up to two wild areas (main islands first, then the World Tree) and every alpha.
    Each entry carries pal/map/gx/gy so the page can jump to it on the map."""
    out, later = [], []
    for region, tag in (('main', ''), ('tree', 'World Tree · ')):
        for g in areas_for(name, region):
            if len([o for o in out if o['kind'] == 'Wild']) >= 2: break
            ok, why = spot_open(g['gx'], g['gy'], region, g['lmin'])
            if not ok: later.append(why); continue
            out.append({'kind': 'Wild', 'pal': name, 'map': region, 'gx': round(g['gx']), 'gy': round(g['gy']),
                        'text': f"{tag}({round(g['gx'])}, {round(g['gy'])}) · Lv {g['lmin']}–{g['lmax']} · fast travel: {nearest_ft(g['gx'], g['gy'], region)}"})
    for region, tag in (('main', ''), ('tree', 'World Tree · ')):
        for p in REGIONS[region]['pts'].get('alpha', []):
            if p[2] == 'Alpha ' + name:
                lv = int(p[3].split('Lv ')[1].split(' ')[0]) if 'Lv ' in p[3] else 0
                ok, why = spot_open(p[0], p[1], region, lv)
                if not ok: later.append(why); continue
                out.append({'kind': 'Alpha', 'pal': name, 'map': region, 'gx': round(p[0]), 'gy': round(p[1]),
                            'text': f"{tag}({round(p[0])}, {round(p[1])}) · {p[3].split(' · ')[0]} · fast travel: {nearest_ft(p[0], p[1], region)}"})
    if not out and later:
        out.append({'kind': 'Later', 'text': later[0]})
    elif not any(o['kind'] == 'Alpha' for o in out) and not later:
        out.append({'kind': 'Alpha', 'text': 'No alpha version anywhere on the map'})
    return out

# ---------- breeding helpers ----------
UNIQUE = {}
for u in BREED['unique_combos']:
    UNIQUE[frozenset((u['parent_a'], u['parent_b']))] = u['child']
FORMULA = BREED['child_to_parents_formula']  # child -> list of parent pairs

GOOD_WORK = {'CraftSpeed_up3', 'CraftSpeed_up2', 'Rare', 'CraftSpeed_up1', 'PAL_Sanity_Down_3', 'PAL_Sanity_Down_2', 'PAL_FullStomach_Down_3', 'PAL_FullStomach_Down_2', 'Nocturnal', 'WorkSuitabilityAddRank_MonsterFarm_2'}
GOOD_FIGHT = {'Legend', 'PAL_ALLAttack_up3', 'PAL_ALLAttack_up2', 'Rare', 'Deffence_up3', 'Deffence_up2', 'Noukin', 'Witch', 'Nushi', 'Vampire'} | {k for k in PASS if k.startswith('ElementBoost_') and k.endswith('_2_PAL')}

def an(w): return 'an' if w[:1].lower() in 'aeiou' else 'a'

def pname(pid): return (PASSN.get(pid) or {}).get('localized_name', pid)

# ---------- scoring ----------
# 1.0 work output by work level (community-measured for Kindling/Handiwork; gaps filled in a straight line).
# Output climbs steeply, so a Lv 10 worker beats a Lv 8 one with a work-speed passive.
WORK_CURVE = {1: 100, 2: 200, 3: 400, 4: 700, 5: 1000, 6: 1300, 7: 1600, 8: 1900, 9: 3650, 10: 5400}

def work_score(p, skill):
    lvl = p['work'].get(skill, 0)
    if not lvl: return 0
    lvl = WORK_CURVE.get(min(10, lvl), 100) / 100
    cs = sum(pas_effects(x['id']).get('CraftSpeed', 0) for x in p['passives'])
    noct = (atlas.get(p['species']) or {}).get('nocturnal') or any(x['id'] in ('Nocturnal', 'Vampire') for x in p['passives'])
    return lvl * (1 + cs / 100) * (1.1 if noct else 1) * (1 + 0.1 * p['rank'])     # +10% work speed per condenser star (game constant)

def attack_score(p, boss_els):
    a = atlas.get(p['species']) or {}
    base = a.get('attack') or 80
    eff = collections.Counter()
    for x in p['passives']: eff.update(pas_effects(x['id']))
    boosts = {EL.get(k.split('_')[1], k.split('_')[1]): v for k, v in eff.items() if k.startswith('ElementBoost_')}
    m = emult(p['elements'], boss_els, boosts) if boss_els else 1
    soul = (p.get('souls') or {}).get('Attack', 0)
    return base * max(p['lv'], 1) * (1 + 0.3 * p['atk'] / 100) * (1 + eff.get('ShotAttack', 0) / 100) * (1 + 0.05 * p['rank']) * (1 + 0.03 * soul) * m

def letter(r):
    for t, l in ((0.9, 'A+'), (0.78, 'A'), (0.66, 'B'), (0.52, 'C'), (0.38, 'D')):
        if r >= t: return l
    return 'E'

# ---------- jobs ----------
JOBS = [
    # id, group, label, slots [(skill, count, role)], note
    ('mining', 'Mining', 'Mining: ore, coal, sulfur, quartz, stone', [('Mining', 4, 'Miner'), ('Transporting', 1, 'Hauler')], 'Works for any mining base: ore, coal, sulfur, Pure Quartz or stone.'),
    ('logging', 'Logging', 'Logging: wood and lumber', [('Lumbering', 4, 'Logger'), ('Transporting', 1, 'Hauler')], ''),
    ('smelting', 'Production', 'Smelting ingots', [('Kindling', 4, 'Furnace'), ('Transporting', 1, 'Hauler')], 'Kindling pals keep furnaces running.'),
    ('crafting', 'Production', 'Crafting and assembly', [('Handiwork', 5, 'Crafter')], ''),
    ('electricity', 'Production', 'Electricity', [('Generating Electricity', 4, 'Generator'), ('Transporting', 1, 'Hauler')], ''),
    ('medicine', 'Production', 'Medicine', [('Medicine Production', 4, 'Medic'), ('Transporting', 1, 'Hauler')], ''),
    ('cooking', 'Production', 'Cooking', [('Kindling', 3, 'Cook'), ('Cooling', 1, 'Cooler'), ('Transporting', 1, 'Hauler')], 'Kindling cooks, Cooling keeps food fresh.'),
    ('oil', 'Mining', 'Crude oil', [('Crude Oil Extraction', 4, 'Pumper'), ('Transporting', 1, 'Hauler')], ''),
    ('crops', 'Farming', 'Crops: wheat, berries, veggies', [('Planting', 2, 'Planter'), ('Watering', 2, 'Waterer'), ('Gathering', 1, 'Harvester')], ''),
    ('ranch', 'Farming', 'Ranch', [('Farming', 5, 'Rancher')], 'Ranch pals drop items on their own; which item depends on the species.'),
    ('egg', 'Farming', 'Cooking eggs (Chikipi on the Ranch)', [('#ChickenPal', 3, 'Egg layer'), ('Cooling', 1, 'Cooler'), ('Transporting', 1, 'Hauler')], 'Chikipi lays the eggs you cook with on the Ranch. For Pal Eggs, see Wild Pal egg hunting under Out in the world.'),
    ('cake', 'Farming', 'Cake supply for breeding', [('#ChickenPal', 1, 'Eggs'), ('#CowPal', 1, 'Milk'), ('#SoldierBee', 1, 'Honey'), ('Planting', 1, 'Planter'), ('Watering', 1, 'Waterer'), ('Gathering', 1, 'Harvester'), ('Kindling', 1, 'Cook')], 'Cake needs flour, red berries, milk, eggs and honey.'),
    ('gold', 'Farming', 'Gold coins', [('#Bastet', 2, 'Coin finder'), ('#LazyCatfish_Gold', 2, 'Coin finder'), ('#CuteFox', 1, 'Digger')], 'These pals turn up gold coins on the Ranch.'),
]
JOB_SPECIES = {'#ChickenPal': 'Chikipi', '#CowPal': 'Mozzarina', '#SoldierBee': 'Beegarde', '#Bastet': 'Mau', '#LazyCatfish_Gold': 'Dumud Gild', '#CuteFox': 'Vixy'}

def build_crews(pals):
    crews = []
    for jid, group, label, slots, note in JOBS:
        used = set(); members = []; missing = []
        jcomm = community('jobs', jid)
        jfav = set((jcomm or {}).get('picks') or [])
        for skill, n, role in slots:
            if skill.startswith('#'):
                sid = skill[1:]
                cands = sorted([p for p in pals if p['species'] == sid and p['i'] not in used], key=lambda p: -(work_score(p, 'Farming') + p['lv'] / 100))
                score_skill = 'Farming'
            else:
                cands = sorted([p for p in pals if p['i'] not in used and p['work'].get(skill)], key=lambda p: -(work_score(p, skill) * (1.03 if p['name'] in jfav else 1)))
                score_skill = skill
            take = cands[:n]
            for p in take:
                used.add(p['i'])
                lvl = p['work'].get(score_skill, 0)
                cs = sum(pas_effects(x['id']).get('CraftSpeed', 0) for x in p['passives'])
                members.append({'i': p['i'], 'role': role, 'skill': score_skill, 'lvl': lvl, 'cs': cs})
            if len(take) < n:
                missing.append((skill, n - len(take), role))
        if not members:
            crews.append({'id': jid, 'group': group, 'label': label, 'empty': True,
                          'why': 'You don’t own any pals that can do this job yet.',
                          'better': better_for_job(slots, pals), 'members': [], 'rating': '–'})
            continue
        # why
        skills = collections.defaultdict(list)
        for m in members: skills[m['skill']].append(m['lvl'])
        parts = [f"{len(v)} at {k} {min(v)}–{max(v)}" if min(v) != max(v) else f"{len(v)} at {k} {v[0]}" for k, v in skills.items()]
        cs_total = sum(m['cs'] for m in members)
        why = '; '.join(parts) + '.'
        if cs_total > 0: why += f" Their work-speed passives add +{int(cs_total)}% across the crew."
        elif cs_total < 0: why += f" Their passives slow the crew down by {int(-cs_total)}% in total."
        if note: why += ' ' + note
        # rating vs an ideal (top suitability in game, Artisan)
        ideal = 0; have = 0
        for skill, n, role in slots:
            if skill.startswith('#'): ideal += n * 4 * 1.7; continue
            top = max([a.get('workSuitability', {}).get(ELI.get(skill, skill), 0) for a in atlas.values()] + [0])
            topk = max((v for a in atlas.values() for k, v in a.get('workSuitability', {}).items() if WS.get(k) == skill), default=0)
            ideal += n * min(10, topk + 2) * 1.3            # best species, condensed (max Lv 10), good passive
        for m in members:
            have += m['lvl'] * (1 + m['cs'] / 100)
        rating = letter(have / ideal) if ideal else 'B'
        crews.append({'id': jid, 'group': group, 'label': label, 'members': members, 'why': why,
                      'better': better_for_job(slots, pals, members, missing), 'rating': rating,
                      **({'community': dict(jcomm, owned=sorted({p['name'] for p in pals if p['name'] in jfav}))} if jcomm else {})})
    return crews

def best_species_for(skill, exclude):
    k = next((k for k, v in WS.items() if v == skill), None)
    cands = [(a.get('workSuitability', {}).get(k, 0), a) for a in atlas.values() if a.get('workSuitability', {}).get(k)]
    cands.sort(key=lambda t: (-t[0], t[1].get('rarity', 0)))
    for lvl, a in cands:
        if a['id'] not in exclude and reachable(a['name']):
            if a['id'] not in exclude:
                return lvl, a
    return None

def better_for_job(slots, pals, members=None, missing=None):
    tips = []
    owned = {p['species'] for p in pals}
    for skill, n, role in (missing or []):
        nm = JOB_SPECIES.get(skill, None)
        if nm:
            tips.append({'text': f"You need {n} more {nm} for this. Catch one:", 'where': where_to_catch(nm)})
        else:
            bs = best_species_for(skill, set())
            if bs: tips.append({'text': f"You need {n} more pal{'s' if n > 1 else ''} with {skill}. {bs[1]['name']} has {skill} {bs[0]}:", 'where': where_to_catch(bs[1]['name'])})
    if members:
        # upgrade the main skill with a stronger species you don't own
        main_skill = next((s for s, n, r in slots if not s.startswith('#')), None)
        if main_skill:
            bs = best_species_for(main_skill, owned)
            mine = max([m['lvl'] for m in members if m['skill'] == main_skill] or [0])
            if bs and bs[0] > mine:
                tips.append({'text': f"{bs[1]['name']} has {main_skill} {bs[0]}, higher than your best ({mine}). Catch one:", 'where': where_to_catch(bs[1]['name'])})
        # passive upgrade on the weakest member
        workers = [m for m in members if m['skill'] != 'Farming']
        if not workers: return tips[:3]
        weakest = min(workers, key=lambda m: m['cs'])
        wp = next(p for p in pals if p['i'] == weakest['i'])
        have_ids = {x['id'] for x in wp['passives']}
        if not ({'CraftSpeed_up2', 'CraftSpeed_up3'} & have_ids):
            mate = next((q for q in pals if q['species'] == wp['species'] and q['i'] != wp['i'] and q['gender'] and wp['gender'] and q['gender'] != wp['gender'] and ({'CraftSpeed_up2', 'CraftSpeed_up3'} & {x['id'] for x in q['passives']})), None)
            if mate:
                tips.append({'text': f"Your {wp['name']} (Lv {wp['lv']}) has no big work-speed passive. Breed it with your other {mate['name']} ({mate['loc']}), which has {', '.join(pname(x['id']) for x in mate['passives'] if x['id'] in GOOD_WORK)}. See the Breeding tab.", 'where': []})
            else:
                tips.append({'text': f"Your {wp['name']} (Lv {wp['lv']}) has no big work-speed passive. {an(wp['name']).capitalize()} {wp['name']} with Artisan (+50%) or Remarkable Craftsmanship (+75%) would speed the whole crew up.", 'where': []})
    return tips[:3]

# ---------- bosses ----------
def boss_list():
    out = []
    TE = {'Electricity': 'Electric', 'Leaf': 'Grass', 'Earth': 'Ground', 'Normal': 'Neutral'}
    for t in _load('towers_static.json'):
        els = [TE.get(e, e) for e in (t['element1'], t['element2']) if e]
        boss_pal = t['bossName'].split('&')[-1].strip()
        if not els: els = elements_of((byname.get(boss_pal) or {}).get('id', ''))
        gx, gy = round((t['y'] - TY) / SC), round((t['x'] + TX) / SC)
        last = t['defeatFlagKey'] == 'LastBoss'
        region = 'tree' if last else 'main'
        if last: els = []          # Zenara & Astralym are typeless: no element to exploit
        out.append({'id': 'tower-' + t['defeatFlagKey'], 'group': 'Story bosses' if last else 'Towers',
                    'label': (f"Final boss: {t['bossName']} (Lv 80)" if last else f"{t['name']}: {t['bossName']}"), 'pal': boss_pal,
                    'els': els if last else (els or ['Neutral']), 'lv': t['levelNormal'] or 80, 'hard': None if last else (t['levelHard'] or 100),
                    'map': region, 'gx': gx, 'gy': gy,
                    'where': ('World Tree · Within the Seal · ' if last else '') + f"({gx}, {gy}) · fast travel: {nearest_ft(gx, gy, region)}",
                    'note': ('The last fight of the story. Needs Panthalus caught, the three World Tree guardians beaten and all eight tower Key Spheres.' if last else '')})
    # story fights that are not towers (positions from the game's quest data)
    STORY = [('story-panthalus', 'Panthalus (opens the World Tree)', 'Panthalus', 70, 'main', -108082.18, 77959.26,
              'Deserted Islet shrine', 'After the Azure Covenant Tower, talk to Auri, get the Faded Schematic from the researcher on the Deserted Islet, collect the four Echobones, craft the Echoing Flute and play it at the shrine. Catch it, do not kill it: keep it in your party to open the World Tree barrier.'),
             ('story-silvance', 'Silvance (World Tree guardian)', 'Silvance', 78, 'tree', 405135.0, -730345.0,
              'Shinespore Root', 'One of the World Tree guardians you must beat for The Sealed Calamity.'),
             ('story-dandilord', 'Dandilord (World Tree guardian)', 'Dandilord', 78, 'tree', 630703.1, -612728.6,
              'Rotmist Root', 'One of the World Tree guardians you must beat for The Sealed Calamity.')]
    for sid_, label, nm, lv, region, wx, wy, place, note in STORY:
        gx, gy = round((wy - TY) / SC), round((wx + TX) / SC)
        out.append({'id': sid_, 'group': 'Story bosses', 'label': label, 'pal': nm,
                    'els': [EL.get(e, e) for e in (byname.get(nm) or {}).get('elements', ['Normal'])], 'lv': lv, 'hard': None,
                    'map': region, 'gx': gx, 'gy': gy,
                    'where': ('World Tree · ' if region == 'tree' else '') + f"{place} ({gx}, {gy}) · fast travel: {nearest_ft(gx, gy, region)}", 'note': note})
    # 1.0.5 raid levels (PinDrop raids page, game files 1.0.5; palworld.wiki.gg Raid Bosses). Ultra / Master versions are Lv 80.
    raids = [('Bellanoir', 35, None, ''), ('Bellanoir Libero', 45, 80, ''), ('Moon Lord', 50, 80, 'Terraria crossover raid, summoned with the Celestial Sigil (its fragments come from the Terraria dungeon). Beating it gives the Master sigil (Lv 80). It is not a pal, so there is no element to aim for: bring your strongest attackers.'),
             ('Blazamut Ryu', 55, 80, ''), ('Xenolord', 65, 80, ''), ('Hartalis', 70, 80, '')]
    for nm, lv, ultra, note in raids:
        a = byname.get(nm)
        els = [EL.get(e, e) for e in (a or {}).get('elements', ['Normal'])] if a else []
        out.append({'id': 'raid-' + nm.replace(' ', ''), 'group': 'Raid bosses (Summoning Altar)', 'label': nm, 'pal': nm,
                    'els': els, 'lv': lv, 'hard': ultra, 'note': note or ('Beating it drops its Ultra slab (Lv 80).' if ultra else '')})
    order = {'Towers': 0, 'Story bosses': 1}
    out.sort(key=lambda b: (order.get(b['group'], 2), b['lv'] if b['group'] in order else 0))
    for region, group in (('main', 'Alpha pals'), ('tree', 'World Tree alpha pals')):
        for p in sorted(REGIONS[region]['pts'].get('alpha', []), key=lambda p: int(p[3].split('Lv ')[1].split(' ')[0])):
            nm = p[2].replace('Alpha ', '')
            a = byname.get(nm) or {}
            out.append({'id': 'alpha-' + (p[4] or nm), 'group': group, 'label': f"{nm} (Lv {p[3].split('Lv ')[1].split(' ')[0]})", 'pal': nm,
                        'els': [EL.get(e, e) for e in a.get('elements', ['Normal'])], 'lv': int(p[3].split('Lv ')[1].split(' ')[0]), 'hard': None,
                        'map': region, 'gx': round(p[0]), 'gy': round(p[1]),
                        'where': ('World Tree · ' if region == 'tree' else '') + f"({round(p[0])}, {round(p[1])}) · fast travel: {nearest_ft(p[0], p[1], region)}"})
    return out
BOSSES = boss_list()

def build_attack(pals):
    res = []
    fighters = [p for p in pals if p['lv'] >= 1]
    for b in BOSSES:
        els = b['els']
        avoid = [p for p in fighters if weak_to(p['elements'], els)]
        avoid_ids = {p['i'] for p in avoid}
        comm = community('bosses', '_arena' if b['group'].startswith('Arena') else b['pal'])
        fav = set((comm or {}).get('picks') or [])
        # pals that guide writers recommend for this fight get a small nudge when two of yours are close
        ranked = sorted([p for p in fighters if p['i'] not in avoid_ids], key=lambda p: -attack_score(p, els) * (1.08 if p['name'] in fav else 1))
        team = []; seen = set()
        for p in ranked:
            if len(team) == 5: break
            team.append(p)
        notes = {}
        for p in team:
            m = emult(p['elements'], els)
            if m >= 2: notes[p['i']] = f"{'/'.join(p['elements'])} hits {'/'.join(els)} for extra damage"
            else:
                top = max(p['passives'], key=lambda x: pas_effects(x['id']).get('ShotAttack', 0), default=None)
                bits = [f"Attack {p['st'][1]:,}" if p.get('st') else f"Attack {p['atk']}"]
                if top and pas_effects(top['id']).get('ShotAttack', 0) > 0: bits.append(top['name'])
                notes[p['i']] = 'Even matchup · ' + ', '.join(bits)
        # ideal team for rating: top species by base attack * multiplier at boss level, perfect IVs, Legend
        ideal = sorted(((a.get('attack') or 0) * emult([EL.get(e, e) for e in a.get('elements', [])], els) for a in atlas.values() if a.get('attack')), reverse=True)[:5]
        lvl = max(b['lv'], max((p['lv'] for p in pals), default=1))
        ideal_s = sum(x * lvl * 1.3 * 1.5 for x in ideal) or 1
        have = sum(attack_score(p, els) for p in team)
        rating = letter(have / ideal_s)
        # better species
        owned_strong = {p['species'] for p in team}
        owned_lv = {}
        for p in pals: owned_lv[p['species']] = max(owned_lv.get(p['species'], 0), p['lv'])
        cands = []
        for a in atlas.values():
            if not a.get('attack') or a['id'] in owned_strong: continue
            ae = [EL.get(e, e) for e in a.get('elements', [])]
            if weak_to(ae, els): continue
            s = a['attack'] * emult(ae, els)
            cands.append((s, a))
        cands.sort(key=lambda t: -t[0])
        better = []
        for s, a in cands:
            if len(better) == 3: break
            if a['id'] in owned_lv:
                if owned_lv[a['id']] >= min((p['lv'] for p in team), default=1): continue   # already as strong as the team; not an upgrade
                ae = [EL.get(e, e) for e in a.get('elements', [])]
                better.append({'name': a['name'], 'els': ae or ['Neutral'],
                               'why': f"{'/'.join(ae)} · base Attack {a['attack']}" + (" · hits for extra damage" if emult(ae, els) >= 2 else '') +
                                      f" · you already have one at Lv {owned_lv[a['id']]}: level it up and it joins this team",
                               'where': [], 'breed': ''})
                continue
            w = where_to_catch(a['name'])
            has_spot = any('gx' in x for x in w)
            breed = breed_route(a['id'], pals)
            if not has_spot and not breed: continue
            better.append({'name': a['name'], 'els': [EL.get(e, e) for e in a.get('elements', [])], 'why': f"{'/'.join(EL.get(e, e) for e in a.get('elements', []))} · base Attack {a['attack']}" + (" · hits for extra damage" if emult([EL.get(e, e) for e in a.get('elements', [])], els) >= 2 else ''),
                           'where': [x for x in w if 'gx' in x], 'breed': breed})
        tips = []
        for p in team:
            same = [q for q in pals if q['species'] == p['species'] and q['i'] != p['i']]
            if p['rank'] < 4 and same:
                tips.append(f"Condense your spare {p['name']} into your best one (you have {len(same)} spare) to raise its rank.")
                break
        for p in team:
            ids = {x['id'] for x in p['passives']}
            if not ids & {'Legend', 'PAL_ALLAttack_up3', 'PAL_ALLAttack_up2'}:
                mate = next((q for q in pals if q['species'] == p['species'] and q['i'] != p['i'] and q['gender'] and p['gender'] and q['gender'] != p['gender'] and ({'Legend', 'PAL_ALLAttack_up3', 'PAL_ALLAttack_up2'} & {x['id'] for x in q['passives']})), None)
                if mate:
                    tips.append(f"Breed your {p['name']} with your other {mate['name']} ({mate['loc']}) to pass on {', '.join(x['name'] for x in mate['passives'] if x['id'] in GOOD_FIGHT)}.")
                    break
        res.append({'id': b['id'], 'group': b['group'], 'label': b['label'], 'pal': b['pal'], 'els': els,
                    'weak': sorted({e for e in BEATS if any(be in BEATS[e] for be in els)}),
                    'lv': b['lv'], 'hard': b.get('hard'), 'where': b.get('where', ''), 'note': b.get('note', ''),
                    **({'map': b['map'], 'gx': b['gx'], 'gy': b['gy']} if 'gx' in b else {}),
                    'team': [{'i': p['i'], 'note': notes[p['i']]} for p in team],
                    'avoid': [p['i'] for p in sorted(avoid, key=lambda p: -p['lv'])[:6]], 'avoidCount': len(avoid),
                    'rating': rating, 'better': better, 'tips': tips[:2],
                    **({'community': dict(comm, owned=sorted({p['name'] for p in pals if p['name'] in fav}))} if comm else {})})
    import arena
    comm = community('bosses', '_arena')
    for a in arena.build(pals):
        if comm:
            a['community'] = dict(comm, owned=sorted({p['name'] for p in pals if p['name'] in comm['picks']}))
        res.append(a)
    rank = lambda g: 0 if g == 'Towers' else 1 if g == 'Story bosses' else 2 if g.startswith('Arena') else 3 if g.startswith('Raid') else 4
    res.sort(key=lambda r: rank(r['group']))          # stable: keeps the order inside each group
    return res

def breed_route(child, pals):
    have = collections.defaultdict(set)
    for p in pals: have[p['species']].add(p['gender'])
    for pair in FORMULA.get(child, []):
        a, b = pair['parent_a'], pair['parent_b']
        if a == child or b == child: continue
        if a in have and b in have:
            ga, gb = have[a], have[b]
            if a == b:
                if {'M', 'F'} <= ga: return f"Breed two of your {pal_name(a)} (male + female)"
                continue
            need_a, need_b = pair.get('parent_a_gender'), pair.get('parent_b_gender')
            if need_a or need_b:                     # gender-specific special pairing (1.0: Katress + Wixen)
                if (not need_a or need_a in ga) and (not need_b or need_b in gb):
                    sex = {'M': 'male', 'F': 'female'}
                    return f"Breed a {sex.get(need_a, '')} {pal_name(a)} with a {sex.get(need_b, '')} {pal_name(b)}".replace('  ', ' ')
                continue
            if ('M' in ga and 'F' in gb) or ('F' in ga and 'M' in gb) or '' in ga or '' in gb:
                return f"Breed your {pal_name(a)} with your {pal_name(b)}"
    return ''

# ---------- breeding plan ----------
def build_breeding(pals, crews, attack):
    import breeding
    return breeding.build(pals, crews, attack)
