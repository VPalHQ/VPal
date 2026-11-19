"""Arena (Palworld 1.0): every ranked opponent, with the best 3 of your pals against each.

Format: you pick 3 pals from your party (the first is your main; only its partner skill works).
Opponent teams and rank levels are the game's fixed ladder (43 opponents, Bronze to Legend),
as listed by PinDrop and palworld.tools, which agree with each other.
"""
import planner_core as pc

# rank, opponent level, IVs, soul rank, extra note
RANKS = [
    ('Bronze', 20, 50, 0, ''), ('Silver', 30, 50, 3, ''), ('Gold', 40, 50, 6, ''), ('Platinum', 50, 50, 10, ''),
    ('Diamond', 60, 75, 15, ''), ('Master', 65, 100, 20, ''),
    ('Legend', 80, 100, 20, 'Legend opponents have 1.5x HP, deal 1.5x damage and take only 40% of normal damage.'),
]
TEAMS = {
    'Bronze': [('Newbie Pal Tamer', 'Univolt, Relaxaurus, Broncherry, Arsox, Digtoise')],
    'Silver': [('Up-and-Coming Pal Tamer', 'Verdash, Kitsun, Reindrix, Helzephyr, Mossanda')],
    'Gold': [('Cruel Pal Tamer', 'Reptyro, Dinossom Lux, Bushi, Blazehowl Noct, Menasting')],
    'Platinum': [('Veteran Pal Tamer', 'Mammorest Cryst, Jormuntide Ignis, Quivern, Orserk, Suzaku Aqua')],
    'Diamond': [
        ('Sturdy Mercenary', 'Knocklem, Cryolinx Terra, Menasting Terra, Mammorest, Gildane'),
        ('Syndicate Crusher', 'Menasting, Sootseer, Splatterina, Omascul, Prixter'),
        ('Brothers of the Eternal Pyre Martyr', 'Blazehowl, Reptyro, Blazamut, Ragnahawk, Pyrin'),
        ('Moonflower Genin', 'Bushi Noct, Shroomer Noct, Verdash, Dogen, Croajiro'),
        ('Messenger of Love', 'Lovander, Lovander, Palumba, Palumba, Lyleen'),
        ('PAL Genetic Research Unit Executioner', 'Shadowbeak, Xenogard, Xenovader, Lunaris, Suzaku Aqua'),
        ('Feybreak Warrior', 'Jormuntide, Penking Lux, Ghangler, Gloopie, Munchill'),
        ('Vigorous Pal Tamer', 'Astegon, Silvegis, Orserk, Jormuntide Ignis, Quivern'),
        ('Pal Ecological Researcher', 'Azurmane, Helzephyr Lux, Fenglope Lux, Mossanda Lux, Beakon'),
        ('Sweet-Smelling Hunter', 'Elizabee, Prunelia, Lullu, Vaelet, Petallia'),
    ],
    'Master': [
        ('Black Marketeer', 'Shadowbeak, Shadowbeak, Blazamut, Blazamut, Bastigor'),
        ('Friendly Pal Tamer', 'Celesdir, Silvegis, Xenogard, Whalaska, Selyne'),
        ('Dr. Brawn', 'Shadowbeak, Shadowbeak, Shadowbeak, Xenogard, Xenogard'),
        ('Medal Merchant', 'Knocklem, Menasting Terra, Dumud Gild, Turtacle Terra, Warsect Terra'),
        ('Master Pal Tamer', 'Shadowbeak, Bastigor, Azurmane, Anubis, Azurobe'),
        ('Fiery Pal Tamer', 'Blazamut, Blazehowl, Faleris, Jormuntide Ignis, Reptyro'),
        ('Moonflower Jonin', 'Bushi Noct, Sootseer, Blazehowl Noct, Ghangler Ignis, Croajiro Noct'),
        ('Feybreak Berserker', 'Whalaska Ignis, Mammorest Cryst, Reptyro Cryst, Azurobe Cryst, Cryolinx'),
        ('Legend-Loving Researcher', 'Astegon, Xenogard, Relaxaurus, Orserk, Quivern Botan'),
        ('Veteran Hunter', 'Grizzbolt, Lyleen, Orserk, Faleris, Shadowbeak'),
    ],
    'Legend': [(f'Legend opponent {i}', t) for i, t in enumerate([
        'Aegidron, Shadowbeak, Knocklem, Knocklem Ignis, Mimog',
        'Shaolong, Shaolong, Shadowbeak, Bastigor, Anubis',
        'Dualith, Dualith Noct, Knocklem, Knocklem Ignis, Mammorest Cryst',
        'Dualith, Pierdon, Tetroise, Bulldosu, Sekhmet',
        'Faleris, Shadowbeak, Selyne, Bastigor, Shaolong',
        'Faleris Aqua, Moldron Cryst, Eidrolon Ignis, Azurmane, Knocklem Ignis',
        'Orserk, Azurmane, Dynamoff, Prixter Lux, Snock',
        'Lamball, Cattiva, Chikipi, Depresso, Chillet',
        'Moldron Cryst, Pierdon Cryst, Elgrove Cryst, Frostplume, Muffly',
        'Shaolong, Skutlass, Solmora, Solmora Lux, Amione',
        'Dupin, Carnibora, Venusa, Mycora, Petallia Ignis',
        'Eidrolon Ignis, Aegidron, Shaolong, Silvegis, Xenogard',
        'Lapure, Dupin, Lapiron, Nitemary Botan, Ribbuny',
        'Moldron, Eidrolon Ignis, Skutlass Ignis, Flaracle, Renjishi',
        'Shadowbeak, Shadowbeak, Shadowbeak, Xenogard, Xenovader',
        'Jormuntide Ignis, Skutlass Ignis, Katress Ignis, Wixen, Dogen',
        'Ophydia, Elgrove, Leafan, Braloha, Palumba',
        'Anubis, Sekhmet, Gildra, Tetroise, Tetroise Primo',
        'Celesdir Noct, Loomen, Solenne, Gildra, Roujay'], start=1)],
}
ARENA_XY = (-117215.02, 446689.97)          # Arena Entrance fast travel point (game data)
RULES = ('Pick 3 pals from your party. The first one is your main, and only its partner skill works. '
         'Healing items, boost guns and sphere launchers do not work inside. Win by knocking out the other tamer or all their pals.')

byname = {a['name'].lower(): a for a in pc.atlas.values()}
def els_of(name):
    a = byname.get(name.lower()) or {}
    return [pc.EL.get(e, e) for e in a.get('elements', [])] or ['Neutral']


def build(pals):
    gx, gy = round((ARENA_XY[1] - pc.TY) / pc.SC), round((ARENA_XY[0] + pc.TX) / pc.SC)
    ft = pc.nearest_ft(gx, gy)
    fighters = [p for p in pals if p['species'] in pc.atlas]
    # per pal: damage without the matchup, its element boosts, and its elements
    base = {}
    for p in fighters:
        base[p['i']] = pc.attack_score(p, [])
    boosts = {}
    for p in fighters:
        eff = {}
        for x in p['passives']:
            for k, v in pc.pas_effects(x['id']).items():
                if k.startswith('ElementBoost_'):
                    e = pc.EL.get(k.split('_')[1], k.split('_')[1]); eff[e] = eff.get(e, 0) + v
        boosts[p['i']] = eff
    owned_lv = {}
    for p in pals: owned_lv[p['species']] = max(owned_lv.get(p['species'], 0), p['lv'])
    max_lv = max((p['lv'] for p in pals), default=1)

    def pick(cands, opp, dmg_of, hurt_of, n=3):
        chosen, covered = [], [0.0] * len(opp)
        for _ in range(n):
            best, best_val = None, -1
            for c in cands:
                if c in chosen: continue
                d = dmg_of(c)
                gain = sum(max(a, b) for a, b in zip(covered, d)) - sum(covered)
                val = (gain + 0.15 * sum(d)) * (1 - 0.35 * hurt_of(c))
                if val > best_val: best, best_val = c, val
            if best is None: break
            chosen.append(best)
            covered = [max(a, b) for a, b in zip(covered, dmg_of(best))]
        return chosen, sum(covered)

    out = []
    for rank, lv, iv, soul, extra in RANKS:
        for k, (trainer, team_s) in enumerate(TEAMS[rank], start=1):
            names = [n.strip() for n in team_s.split(',')]
            opp = [els_of(n) for n in names]
            all_els = []
            for e in opp:
                for x in e:
                    if x not in all_els: all_els.append(x)
            n_opp = len(opp)
            hurt_p = lambda p: sum(1 for oe in opp if pc.weak_to(p['elements'], oe)) / n_opp
            dmg_p = lambda p: [base[p['i']] * pc.emult(p['elements'], oe, boosts[p['i']]) for oe in opp]
            team, have = pick(fighters, opp, dmg_p, hurt_p)
            # the best possible 3 in the game, at least at the opponents' level
            lvl = max(lv, max_lv)
            sp = [a for a in pc.atlas.values() if a.get('attack') and a['id'] != 'WorldTreeDragon']
            sp_els = {a['id']: [pc.EL.get(e, e) for e in a.get('elements', [])] or ['Neutral'] for a in sp}
            dmg_s = lambda a: [a['attack'] * lvl * 1.3 * 1.5 * pc.emult(sp_els[a['id']], oe) for oe in opp]
            hurt_s = lambda a: sum(1 for oe in opp if pc.weak_to(sp_els[a['id']], oe)) / n_opp
            top_sp = sorted(sp, key=lambda a: -sum(dmg_s(a)) * (1 - 0.35 * hurt_s(a)))[:40]
            _, ideal = pick(top_sp, opp, dmg_s, hurt_s)
            rating = pc.letter(have / (ideal or 1))
            notes = {}
            for p in team:
                beats = [names[j] for j, oe in enumerate(opp) if pc.emult(p['elements'], oe) >= 2]
                risk = [names[j] for j, oe in enumerate(opp) if pc.weak_to(p['elements'], oe)]
                txt = (f"Hits {', '.join(dict.fromkeys(beats))} for extra damage" if beats else "Big damage with even matchups against this team")
                if risk: txt += f" · careful: {', '.join(dict.fromkeys(risk))} can hit it hard"
                notes[p['i']] = txt
            avoid = [p for p in fighters if hurt_p(p) >= 0.6]
            # better picks: strong all-round species you don't have on this team
            team_sp = {p['species'] for p in team}
            better = []
            for a in sorted(sp, key=lambda a: -sum(dmg_s(a)) * (1 - 0.35 * hurt_s(a))):
                if len(better) == 3: break
                if a['id'] in team_sp: continue
                ae = sp_els[a['id']]
                beats = [names[j] for j, oe in enumerate(opp) if pc.emult(ae, oe) >= 2]
                why = f"{'/'.join(ae)} · base Attack {a['attack']}" + (f" · hits {', '.join(dict.fromkeys(beats))} for extra damage" if beats else '')
                if a['id'] in owned_lv:
                    if owned_lv[a['id']] >= min((p['lv'] for p in team), default=1): continue
                    better.append({'name': a['name'], 'els': ae, 'why': why + f" · you already have one at Lv {owned_lv[a['id']]}: level it up and it joins this team", 'where': [], 'breed': ''})
                    continue
                w = pc.where_to_catch(a['name'])
                spots = [x for x in w if 'gx' in x]
                br = pc.breed_route(a['id'], pals)
                if not spots and not br: continue
                better.append({'name': a['name'], 'els': ae, 'why': why, 'where': spots, 'breed': br})
            weak = sorted({e for e in pc.BEATS if sum(1 for oe in opp if pc.emult([e], oe) >= 2) >= 2},
                          key=lambda e: -sum(1 for oe in opp if pc.emult([e], oe) >= 2))
            tips = []
            if team:
                tips.append(f"Put {team[0]['nick'] or team[0]['name']} first: only your main pal's partner skill works in the Arena.")
            if rank == 'Legend':
                tips.append('This opponent has 1.5x HP, deals 1.5x damage and takes only 15% of normal damage, so bring your strongest pals.'
                            if k == 8 else extra)
            out.append({'id': f'arena-{rank.lower()}-{k}', 'group': f'Arena: {rank} (Lv {lv})',
                        'label': f"{trainer}: {', '.join(names)}", 'pal': trainer, 'els': all_els, 'weak': weak,
                        'lv': lv, 'hard': None, 'map': 'main', 'gx': gx, 'gy': gy,
                        'where': f"Arena ({gx}, {gy}) · fast travel: {ft}",
                        'note': RULES + f" Their pals are Lv {lv} with true values around {iv} and soul rank {soul}.",
                        'opponents': [{'name': n, 'els': e} for n, e in zip(names, opp)],
                        'team': [{'i': p['i'], 'note': notes[p['i']]} for p in team],
                        'avoid': [p['i'] for p in sorted(avoid, key=lambda p: -p['lv'])[:6]], 'avoidCount': len(avoid),
                        'rating': rating, 'better': better, 'tips': tips[:2]})
    return out
