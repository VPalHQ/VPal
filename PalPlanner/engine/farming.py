"""Field farming parties: who to bring when you go out for eggs, ore, wood, drops, catches, fish or treasure.

Built on the 1.0.5 partner skill tables (engine/data/partner.json): each pal's skill value at ranks 1-5,
how it triggers (in party, ridden, called out) and which Pal Gear unlocks it. Community notes come from
engine/data/community.json (guides and wikis, with links).
"""
import planner_core as pc

PT = pc._load('partner.json')['pals']
COMM = pc._load('community.json')
NAME = lambda sid: pc.pal_name(sid)
RANKS = '★'

HOW = {'InOtomo': 'Keep in party', 'Always': 'Keep in party', 'Riding': 'Ride it', 'ActiveOtomo': 'Have it out with you', 'call': 'Call it out (partner skill button)'}

def fx(sid, t):
    return (PT.get(sid) or {}).get('fx', {}).get(t)

def items_of(sid, t):
    return ((PT.get(sid) or {}).get('it') or {}).get(t) or []

def species_with(t, item=None, invoke=None):
    out = []
    for sid, d in PT.items():
        if t not in d.get('fx', {}): continue
        if invoke and d['inv'].get(t) not in invoke: continue
        if item and not (set(items_of(sid, t)) & set(item)): continue
        out.append(sid)
    return out

# ---------------- roles ----------------
def role_fx(label, t, text, item=None, invoke=None, how=None, extra=None):
    """A role filled by the pal with the strongest value of partner-skill effect t."""
    return {'label': label, 'kind': 'fx', 't': t, 'item': item, 'invoke': invoke, 'text': text, 'how': how, 'extra': extra}

def role_list(label, sids, text, how):
    """A role only certain pals can fill (skills the tables describe in words only)."""
    return {'label': label, 'kind': 'list', 'sids': sids, 'text': text, 'how': how}

def role_mount(label, text):
    return {'label': label, 'kind': 'mount', 'text': text, 'how': 'Ride it'}

def role_fighter(label, text):
    return {'label': label, 'kind': 'fighter', 'text': text, 'how': 'Keep in party'}

ELEMS = [('Fire', 'Fire'), ('Water', 'Water'), ('Leaf', 'Grass'), ('Electricity', 'Electric'), ('Ice', 'Ice'), ('Earth', 'Ground'), ('Dragon', 'Dragon'), ('Dark', 'Dark'), ('Normal', 'Neutral')]

SCENARIOS = [
    {'id': 'field-eggs', 'label': 'Wild Pal egg hunting', 'map': ['egg'],
     'intro': 'Pick up every Pal Egg you find while these ride along. "Keep in party" skills work from any party slot, so they don’t have to be out.',
     'roles': [role_fx('Alpha eggs', 'EggAlphaConversion', '{v}% chance each egg you pick up turns into an Alpha egg'),
               role_fx('Extra eggs', 'EggObtainExtraEgg', '{v}% chance of a second egg every time you pick one up'),
               role_mount('Fast flyer', 'Flies at speed {v} between egg spots'),
               role_fx('Carry weight', 'MaxInventoryWeight', '+{v} carrying capacity (eggs are heavy)')]},
    {'id': 'field-ore', 'label': 'Ore and stone runs', 'map': ['ore', 'coal', 'sulfur', 'quartz', 'paloxite'],
     'intro': 'Mine out in the world. The mount’s bonus only counts while you hit rocks from its back.',
     'roles': [role_fx('Mining mount', 'Mining', '+{v}% mining damage while you ride it', invoke=['Riding'], extra=('CollectItemDrop', ' and {x}% more ore')),
               role_fx('Drill buddy', 'Mining', 'spins beside you and mines ore much faster', invoke=['ActiveOtomo'], how='call'),
               role_fx('Mining helper', 'Mining', '+{v}% mining for you', invoke=['Always', 'InOtomo'], extra=('ItemWeightReduction', ', stone {x}% lighter')),
               role_fx('Ore weight', 'ItemWeightReduction', 'ore {v}% lighter', item=['CopperOre', 'MaterialOre']),
               role_fx('Carry weight', 'MaxInventoryWeight', '+{v} carrying capacity')]},
    {'id': 'field-wood', 'label': 'Wood runs', 'map': [],
     'intro': 'Chop trees out in the world. The mount’s bonus only counts while you chop from its back.',
     'roles': [role_fx('Logging mount', 'Logging', '+{v}% logging while you ride it', invoke=['Riding']),
               role_fx('Logging helper', 'Logging', '+{v}% logging for you', invoke=['Always', 'InOtomo'], extra=('ItemWeightReduction', ', wood {x}% lighter')),
               role_fx('Carry weight', 'MaxInventoryWeight', '+{v} carrying capacity')]},
    {'id': 'field-chromite', 'label': 'Chromite (Metal Detector)', 'map': ['dungeon'],
     'intro': 'Chromite only shows up in dungeons and boss arenas, and only while a Metal Detector is in your bag.',
     'roles': [role_fx('Chromite finder', 'CollectItemDrop', '{v}% more Chromite while it’s out with you, and it sniffs out nearby Chromite', item=['Chromium'], how='call'),
               role_fx('Mining mount', 'Mining', '+{v}% mining damage while you ride it', invoke=['Riding']),
               role_fx('Mining helper', 'Mining', '+{v}% mining for you', invoke=['Always', 'InOtomo']),
               role_fx('Carry weight', 'MaxInventoryWeight', '+{v} carrying capacity')]},
    {'id': 'field-drops', 'label': 'Item drops from wild pals', 'map': [], 'menu': True,
     'intro': 'Each of these makes one kind of wild pal drop more when you beat it. Your party holds 5, so bring the ones that match what you’re hunting.',
     'roles': [role_fx(f'{nice} pals drop more', 'ElementAddItemDrop_' + k, '{v}% more items from ' + nice + ' pals') for k, nice in ELEMS] +
              [role_fx('Pal Souls', 'GainItemDrop', '{v}% more Pal Souls from pals you beat', item=['PalUpgradeStone']),
               role_fx('Gold coins', 'GainItemDrop', '{v}% more Gold Coins from pals you beat', item=['Money']),
               role_fx('Butchering', 'MeatCutAddItemDrop', '{v}% more items when you butcher a pal')]},
    {'id': 'field-gold', 'label': 'Gold and Dog Coins', 'map': [],
     'intro': 'Gold Coins come from beating pals; Dog Coins come from beating Mimogs (Neutral pals).',
     'roles': [role_fx('Gold coins', 'GainItemDrop', '{v}% more Gold Coins from pals you beat', item=['Money']),
               role_fx('Neutral drops', 'ElementAddItemDrop_Normal', '{v}% more items from Neutral pals, Mimogs included'),
               role_fx('Faster kills', 'DefeatEnemy_ActiveSkillCoolTime_Decrease', 'cuts move cooldowns by {v}% every time you beat a pal'),
               role_mount('Fast flyer', 'Flies at speed {v} between targets'),
               role_fx('Carry weight', 'MaxInventoryWeight', '+{v} carrying capacity')]},
    {'id': 'field-capture', 'label': 'Catching pals and alphas', 'map': ['alpha'],
     'intro': 'Fewer wasted spheres and better odds. Several of these only help with one kind of throw, so use them the way the line says.',
     'roles': [role_fx('Spheres back', 'SphereRecovery', '{v}% chance a thrown sphere isn’t used up'),
               role_fx('Back bonus', 'CaptureLevel_SneakBonus', 'catch rate up {v} level(s) when you throw from behind'),
               role_fx('Frozen targets', 'CaptureLevelUpIfTarget_Freeze', 'catch rate up {v} level(s) on frozen pals'),
               role_fx('Ivy targets', 'CaptureLevelUpIfTarget_IvyCling', 'catch rate up {v} level(s) on pals caught in ivy'),
               role_fx('Keep good passives', 'SyncroPassiveWhenCapture', '{v}% chance a pal you catch copies its passives', how='call')]},
    {'id': 'field-fishing', 'label': 'Fishing', 'map': [],
     'intro': 'Start the minigame with a fuller gauge, lose less when you slip, and pull up more.',
     'roles': [role_fx('Slower slips', 'Fishing_FailedAmountDown', 'gauge drains {v}% slower when the fish gets away from your bar'),
               role_fx('Fuller start', 'Fishing_StartProgressAdd', 'gauge starts {v}% fuller and fills faster'),
               role_fx('More loot', 'Fishing_ItemAddDrop', '{v}% more items from fishing'),
               role_fx('Talented catches', 'Fishing_GoodTalentPalProbability', 'pals you fish up are more likely to have high true values'),
               role_fx('Salvage', 'FishingSalvage_ItemDrop', '{v}% more from sunken junk you fish up')]},
    {'id': 'field-treasure', 'label': 'Treasure, chests and exploring', 'map': ['effigy', 'journal', 'ruin', 'tmap'],
     'intro': 'Find dungeons, chests and effigies faster, and open chests without keys.',
     'roles': [role_list('Chest finder', ['CatBat'], 'pings nearby dungeons, treasure chests and scrap', 'call'),
               role_list('Keyless chests', ['MimicDog'], 'opens treasure chests without a key while it’s out with you', 'ActiveOtomo'),
               role_list('Effigy finder', ['NightFox'], 'pings nearby Lifmunk and other effigies', 'call'),
               role_list('Auto pickup', ['FlowerRabbit', 'YakushimaMonster003'], 'picks up nearby items for you', 'InOtomo'),
               role_mount('Fast flyer', 'Flies at speed {v}')]},
    {'id': 'field-leveling', 'label': 'Leveling pals fast', 'map': ['tower'],
     'intro': 'Party pals share the EXP from fights. Put the pals you want to level in your party next to these two.',
     'roles': [role_fx('EXP boost', 'PalExp_Increase', 'party pals earn {v}% more EXP'),
               role_fighter('Carry fighter', 'your hardest hitter (Attack {v}) does the killing')]},
]

def val(sid, t, rank):
    arr = fx(sid, t) or [0]
    return arr[min(rank, len(arr) - 1)]

def fmtv(v):
    return f"{v:g}" if isinstance(v, (int, float)) else str(v)

def candidates(role):
    if role['kind'] == 'fx':
        return species_with(role['t'], role.get('item'), role.get('invoke'))
    if role['kind'] == 'list':
        return [s for s in role['sids'] if s in PT]
    if role['kind'] == 'mount':
        return [s for s, d in PT.items() if d.get('fly')]
    return []

def describe(role, sid, rank, pal=None):
    if role['kind'] == 'fx':
        v = val(sid, role['t'], rank)
        txt = role['text'].replace('{v}', fmtv(v))
        if role.get('extra') and fx(sid, role['extra'][0]):
            txt += role['extra'][1].replace('{x}', fmtv(val(sid, role['extra'][0], rank)))
        return txt, v
    if role['kind'] == 'mount':
        v = (PT.get(sid) or {}).get('rs', 0)
        return role['text'].replace('{v}', f"{v:,}"), v
    if role['kind'] == 'fighter':
        v = (pal or {}).get('st', [0, 0])[1] if pal and pal.get('st') else 0
        return role['text'].replace('{v}', f"{v:,}"), v
    return role['text'], 1

def how_of(role, sid):
    if role.get('how'): return HOW.get(role['how'], role['how'])
    if role['kind'] == 'fx':
        return HOW.get((PT.get(sid) or {}).get('inv', {}).get(role['t']), 'Keep in party')
    return HOW.get(role.get('how'), role.get('how') or 'Keep in party')

def has_gear(sid, gear):
    d = PT.get(sid) or {}
    return not d.get('gear') or gear is None or d['gear'] in gear

def gear_note(sid, gear):
    d = PT.get(sid) or {}
    if not d.get('gear') or gear is None or d['gear'] in gear: return ''
    lv = f" (Technology {d['gearLv']})" if d.get('gearLv') else ''
    return f"Needs its {d['gearName']}{lv} before the skill works. Craft it once and it works for every {NAME(sid)}."

def build(pals, gear=None, favored=None):
    """gear: set of Pal Gear items this player owns (None = unknown). favored: species names players recommend."""
    by_sp = {}
    for p in pals:
        by_sp.setdefault(p['species'], []).append(p)
    out = []
    for sc in SCENARIOS:
        comm = pc.community('farming', sc['id']) or {}
        fav = set(comm.get('picks') or [])
        if comm: comm['owned'] = sorted({p['name'] for p in pals if p['name'] in fav})
        used, members, missing, upgrades, ratio = set(), [], [], [], []
        for role in sc['roles']:
            cands = candidates(role)
            if role['kind'] == 'fighter':
                mine = [p for p in pals if p.get('st') and p['i'] not in used]
                best = max(mine, key=lambda p: p['st'][1], default=None)
                if best:
                    used.add(best['i']); txt, v = describe(role, best['species'], best['rank'], best)
                    members.append({'i': best['i'], 'role': role['label'], 'how': 'Keep in party', 'effect': txt})
                    ratio.append(1)
                continue
            # the strongest copy you own (condensed copies have stronger skills)
            mine = []
            for sid in cands:
                for p in by_sp.get(sid, []):
                    if p['i'] in used: continue
                    txt, v = describe(role, sid, p['rank'], p)
                    mine.append((has_gear(sid, gear), v, NAME(sid) in fav, p['lv'], p, txt))
            # a pal whose Pal Gear you've crafted beats a stronger one you can't use yet
            mine.sort(key=lambda t: (t[0], t[1], t[2], t[3]), reverse=True)
            # the strongest species in the game that this player can reach
            ideal = None
            for sid in sorted(cands, key=lambda s: (describe(role, s, 4)[1], NAME(s) in fav), reverse=True):
                if pc.reachable(NAME(sid)) or sid in by_sp:
                    ideal = sid; break
            top = describe(role, ideal, 4)[1] if ideal else 0
            if mine:
                _, v, _, _, p, txt = mine[0]
                used.add(p['i'])
                g = gear_note(p['species'], gear)
                members.append({'i': p['i'], 'role': role['label'], 'how': how_of(role, p['species']), 'effect': txt,
                                **({'gear': g} if g else {}), 'fav': NAME(p['species']) in fav})
                ratio.append(min(1, (v or 0) / top) if top and role['kind'] != 'list' else 1)
                spare = [q for q in by_sp.get(p['species'], []) if q['i'] != p['i']]
                if role['kind'] == 'fx' and p['rank'] < 4 and spare and val(p['species'], role['t'], 4) > v:
                    upgrades.append(f"Condense your spare {p['name']} ({len(spare)}) into this one. Its {role['label'].lower()} skill grows with every star, up to {fmtv(val(p['species'], role['t'], 4))} at 4 stars.")
                mymax = describe(role, p['species'], 4, p)[1]
                if ideal and ideal != p['species'] and top > mymax * 1.15 and role['kind'] not in ('list', 'fighter'):
                    if ideal in by_sp:                 # you own the better one but can't use it yet
                        g2 = gear_note(ideal, gear)
                        if g2: upgrades.append(f"Your {NAME(ideal)} would be better here ({describe(role, ideal, max(q['rank'] for q in by_sp[ideal]))[0].lower()}). {g2}")
                    else:
                        w = pc.where_to_catch(NAME(ideal))
                        text = (f"{NAME(ideal)} is faster: speed {top:,} against {v:,}." if role['kind'] == 'mount'
                                else f"{NAME(ideal)} does this better: {describe(role, ideal, 0)[0]} at 0 stars, up to {fmtv(top)} at 4 stars.")
                        upgrades.append({'name': NAME(ideal), 'text': text, 'where': [x for x in w if 'gx' in x], 'breed': pc.breed_route(ideal, pals)})
            else:
                ratio.append(0)
                if ideal:
                    w = pc.where_to_catch(NAME(ideal))
                    alt = [NAME(s) for s in cands if s != ideal][:3]
                    missing.append({'role': role['label'], 'name': NAME(ideal), 'effect': describe(role, ideal, 0)[0],
                                    'how': how_of(role, ideal), 'gear': gear_note(ideal, set()) if (PT.get(ideal) or {}).get('gear') else '',
                                    'also': alt, 'where': [x for x in w if 'gx' in x] or [x for x in w if x.get('kind') == 'Later'],
                                    'breed': pc.breed_route(ideal, pals)})
        if sc.get('menu'): rating = f"{len(members)}/{len(sc['roles'])}"
        else: rating = pc.letter(sum(ratio) / len(ratio)) if ratio and any(ratio) else '–'
        out.append({'id': sc['id'], 'group': 'Out in the world', 'label': sc['label'], 'field': True, 'menu': bool(sc.get('menu')),
                    'intro': sc['intro'], 'members': members, 'missing': missing, 'upgrades': upgrades[:6], 'map': sc['map'],
                    'community': comm, 'rating': rating, 'why': sc['intro'], 'better': []})
    return out
