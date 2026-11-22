"""Builds PalPlanner/web/askdata.json, the public game data behind the Pal Planner's Ask tab.

    python3 make_askdata.py <PalPlanner folder>

Everything comes from the engine's own tables (engine/data, Palworld 1.0.5), and breeding uses the engine's own
child_of(), so the Ask tab and the Breeding tab always agree. Run it again whenever the game data is updated.
"""
import os, sys, re, json

PP = os.path.abspath(sys.argv[1])
sys.path.insert(0, os.path.join(PP, 'engine'))
import planner_core as pc
import breeding as br

GAME = '1.0.5'
B36 = '0123456789abcdefghijklmnopqrstuvwxyz'

species = sorted(set(pc.FORMULA) | {p[k] for ps in pc.FORMULA.values() for p in ps for k in ('parent_a', 'parent_b')})
idx = {s: i for i, s in enumerate(species)}
assert len(species) < 36 * 36 - 1

raw = pc._load('pals.json')
pals = []
for s in species:
    ws = (raw.get(s) or {}).get('work_suitability') or {}
    pals.append({'id': s, 'n': pc.pal_name(s), 'e': pc.elements_of(s) or ['Neutral'],
                 'w': {pc.WS[k]: v for k, v in ws.items() if v and k in pc.WS}})

# child of every pair, upper triangle in order (0,0) (0,1) .. (0,n-1) (1,1) ..; 'zz' = depends on the parents' genders
pairs = []
for i, a in enumerate(species):
    for b in species[i:]:
        c = br.child_of(a, b)
        if c is None and frozenset((a, b)) in br.PAIR_G: pairs.append('zz')
        elif c is None: pairs.append('zy')                        # no child (shouldn't happen)
        else: pairs.append(B36[idx[c] // 36] + B36[idx[c] % 36])
gendered = []
for k, lst in br.PAIR_G.items():
    for pr, ch in lst:
        gendered.append([pr['parent_a'], pr.get('parent_a_gender') or '', pr['parent_b'], pr.get('parent_b_gender') or '', ch])
assert 'zy' not in pairs, 'a pair has no child'

passives = {}
for pid, info in pc.PASS.items():
    loc = pc.PASSN.get(pid) or {}
    name, desc = loc.get('localized_name'), loc.get('description')
    gear_only = any(info.get(k) for k in ('add_shot_weapon', 'add_melee_weapon', 'add_armor', 'add_accessory')) \
        and not info.get('add_pal') and not info.get('add_rare_pal')
    if not name or not desc or gear_only: continue                      # leave out passives only gear can have
    passives.setdefault(name, {'d': ' '.join(re.sub(r'<[^>]*>', '', str(desc)).split()), 'r': info.get('rank', 0)})

out = {'game': GAME, 'build': (pc.MAP or {}).get('build', ''), 'pals': pals, 'pairs': ''.join(pairs),
       'gendered': gendered, 'passives': dict(sorted(passives.items())),
       'beats': {k: sorted(v) for k, v in pc.BEATS.items()}}
dst = os.path.join(PP, 'web', 'askdata.json')
with open(dst, 'w', encoding='utf-8') as f:
    json.dump(out, f, ensure_ascii=False, separators=(',', ':'))
print(f'{dst}: {len(species)} pals, {len(pairs)} pairs, {len(gendered)} gender rules, {len(passives)} passives, '
      f'{os.path.getsize(dst):,} bytes')
