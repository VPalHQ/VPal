"""Breeding planner for the Pal Planner (Palworld 1.0 rules).

What it works out for one player, from only the pals they own:
  plan   - the best breeding projects to do next, each as numbered steps with real odds
  goals  - end-game targets: the strongest fighters and the best worker for every job,
           with the four passives to aim for and how close the player already is
  pairs  - mixed pairs the player can breed right now to get a pal they don't have
  avoid  - what not to spend Cake on, and why

Rules used (Palworld 1.0):
  * The baby's species comes from the parents (same pair always gives the same species).
    The game's own pair table is used, including special pairs and pals that only come from two of themselves.
  * A baby inherits 1, 2, 3 or 4 passives (40 / 30 / 20 / 10 %) picked at random from the
    parents' combined passives, so fewer extra passives in the pair means much better odds.
  * Each stat's true value comes from the father (~30 %), the mother (~30 %) or is random (~40 %).
  These odds are community-measured; Pocketpair has not published them.
"""
import collections, math
import planner_core as pc

INH = ((1, .4), (2, .3), (3, .2), (4, .1))


# ---------- odds ----------
def p_all(pool, k):
    """Chance a baby gets all k wanted passives when the parents carry `pool` different passives."""
    if k <= 0: return 1.0
    if k > pool or pool <= 0: return 0.0
    tot = 0.0
    for n, pr in INH:
        n = min(n, pool)
        if n >= k:
            tot += pr * math.comb(pool - k, n - k) / math.comb(pool, n)
    return tot

def pct(p):
    if p >= .97: return 'almost every egg'
    if p < .01: return 'under 1 egg in 100'
    return f"about {round(p * 100)}% of eggs"

def p_one(pool):
    """Chance one particular passive is passed on."""
    return p_all(pool, 1)

def odds_text(p):
    if p <= 0: return 'not possible with this pair'
    n = max(1, round(1 / p))
    if n == 1: return 'almost every egg'
    return f"about 1 in {n} eggs ({round(p * 100)}%)" if p >= .01 else f"about 1 in {n} eggs (under 1%)"


# ---------- passive values ----------
def effects(pid):
    e = collections.Counter()
    for x in (pc.PASS.get(pid) or {}).get('effects', []):
        if x.get('target') in ('ToSelf', 'None', None):
            e[x['type']] += x['value']
    return e

def fight_value(pid, els):
    e = effects(pid)
    boost = max([e.get('ElementBoost_' + pc.ELI.get(x, x), 0) for x in els] + [0])
    return e.get('ShotAttack', 0) + boost + 0.4 * e.get('Defense', 0) + 0.2 * e.get('MaxHP', 0)

def work_value(pid):
    e = effects(pid)
    v = e.get('CraftSpeed', 0) - 0.6 * e.get('Sanity_Decrease', 0) - 0.5 * e.get('FullStomatch_Decrease', 0)
    if 'Nocturnal' in e: v += 12
    return v

def is_bad(pid):
    return (pc.PASS.get(pid) or {}).get('rank', 0) < 0

def rollable(pid):
    s = pc.PASS.get(pid) or {}
    return (s.get('add_pal') or s.get('add_rare_pal')) and not s.get('disabled')

def pn(pid): return pc.pname(pid)


# ---------- species pairs ----------
# 1.0.5 rules (engine/data/breeding.json): same species -> itself, special pairings always win, then breeding power.
# Two special pairings depend on which parent is male (Katress + Wixen).
PAIR, PAIR_G = {}, {}
for child, pairs in pc.FORMULA.items():
    for pr in pairs:
        k = frozenset((pr['parent_a'], pr['parent_b']))
        if pr.get('parent_a_gender') or pr.get('parent_b_gender'):
            PAIR_G.setdefault(k, []).append((pr, child))
        else:
            PAIR[k] = child

def gender_ok(pr, pa, pb):
    """True if pals pa and pb (in either order) fit this pair's gender rule, or the pair has none."""
    ga, gb = pr.get('parent_a_gender'), pr.get('parent_b_gender')
    if not ga and not gb: return True
    for x, y in ((pa, pb), (pb, pa)):
        if x['species'] == pr['parent_a'] and y['species'] == pr['parent_b'] and (not ga or x['gender'] == ga) and (not gb or y['gender'] == gb):
            return True
    return False

def child_of(a, b, ga='', gb=''):
    """Child species of a x b. For a gender-specific pair, ga/gb are a's and b's genders; None if they're unknown."""
    k = frozenset((a, b))
    if k in PAIR_G:
        for pr, ch in PAIR_G[k]:
            if gender_ok(pr, {'species': a, 'gender': ga}, {'species': b, 'gender': gb}): return ch
        return None
    return PAIR.get(k)

def can_mate(p, q):
    if p['i'] == q['i']: return False
    return not p['gender'] or not q['gender'] or p['gender'] != q['gender']

def other_gender(g):
    return {'M': 'female', 'F': 'male'}.get(g, '')


def build(pals, crews, attack):
    pals = [p for p in pals if p['species'] in pc.atlas]          # people can't be bred
    owned_ids = {p['species'] for p in pals}
    by_sp = collections.defaultdict(list)
    for p in pals: by_sp[p['species']].append(p)
    pids = lambda p: [x['id'] for x in p['passives']]
    candidates = {pid for pid in pc.PASS if rollable(pid)} | {x for p in pals for x in pids(p)}
    carriers = collections.defaultdict(list)
    for p in pals:
        for x in pids(p): carriers[x].append(p)
    label = lambda p: f"{p['nick'] or p['name']} (Lv {p['lv']}{', ' + {'M': 'male', 'F': 'female'}[p['gender']] if p['gender'] in ('M', 'F') else ''})"

    # ---- what to aim for ----
    def ideal_for(role, els):
        if role == 'fight':
            ranked = sorted((pid for pid in candidates if fight_value(pid, els) > 0), key=lambda pid: (-fight_value(pid, els), pn(pid)))
        else:
            ranked = sorted((pid for pid in candidates if work_value(pid) > 0), key=lambda pid: (-work_value(pid), pn(pid)))
        return ranked[:4]

    RAIDS = {b['pal']: b for b in pc.BOSSES if b['group'].startswith('Raid')}
    def how_to_get(sid):
        nm = pc.pal_name(sid)
        if sid in owned_ids: return {'kind': 'owned', 'text': f"You have {len(by_sp[sid])}."}
        if nm in RAIDS:
            return {'kind': 'raid', 'text': f"Summon it at a Summoning Altar (raid boss, Lv {RAIDS[nm]['lv']}) and catch it during the fight."}
        w = pc.where_to_catch(nm)
        if any('gx' in x for x in w): return {'kind': 'catch', 'text': 'Catch one: ' + w[0]['text'], 'find': [x for x in w if 'gx' in x][:2]}
        for pr in pc.FORMULA.get(sid, []):
            a, b = pr['parent_a'], pr['parent_b']
            if a == sid or b == sid: continue
            for pa in by_sp.get(a, []):
                for pb in by_sp.get(b, []):
                    if can_mate(pa, pb) and gender_ok(pr, pa, pb):
                        return {'kind': 'breed', 'text': f"Breed your {label(pa)} with your {label(pb)}: every egg is {nm}.", 'parents': [pa['i'], pb['i']]}
        later = next((x['text'] for x in w if x['kind'] == 'Later'), '')
        if later: return {'kind': 'later', 'text': later}
        if all(pr['parent_a'] == sid and pr['parent_b'] == sid for pr in pc.FORMULA.get(sid, [])):
            return {'kind': 'later', 'text': f"Only comes from two {nm} or from catching one, so catch your first one when you can."}
        return {'kind': 'later', 'text': "None of your pals can make it yet. Catch more kinds of pals and check again."}

    # ---- end-game targets ----
    def available_now(sid):
        return sid in owned_ids or how_to_get(sid)['kind'] in ('catch', 'breed', 'raid')

    def obtainable(sid):
        nm = pc.pal_name(sid)
        return nm in RAIDS or pc.catchable(nm) or any(pr['parent_a'] != sid or pr['parent_b'] != sid for pr in pc.FORMULA.get(sid, [])) or sid in owned_ids
    goals = []
    def same_only(sid):
        return all(pr['parent_a'] == sid and pr['parent_b'] == sid for pr in pc.FORMULA.get(sid, []))
    fighters = sorted((a for a in pc.atlas.values() if a.get('attack') and obtainable(a['id']) and a['id'] != 'WorldTreeDragon'),
                      key=lambda a: (-a['attack'], a['name']))
    for group, legend, limit, why in (('Fighters to breed', False, 8, 'One of the hardest hitters you can breed perfect passives onto'),
                                      ('Legendary fighters', True, 6, 'One of the strongest pals in the game. Only two of its own kind can make one, so you catch it')):
        used_el = collections.Counter(); picked = []
        for a in fighters:
            if same_only(a['id']) != legend: continue
            el = pc.EL.get(a['elements'][0], a['elements'][0]) if a.get('elements') else 'Neutral'
            if used_el[el] >= 1: continue
            used_el[el] += 1; picked.append(a)
            if len(picked) == limit: break
        for a in picked:
            els = [pc.EL.get(e, e) for e in a.get('elements', [])]
            goals.append({'group': group, 'role': 'fight', 'sid': a['id'], 'name': a['name'], 'els': els,
                          'why': f"{why} (base Attack {a['attack']}, {'/'.join(els)}).", 'ideal': ideal_for('fight', els)})
    for key, job in pc.WS.items():
        best = max((a.get('workSuitability', {}).get(key, 0) for a in pc.atlas.values()), default=0)
        if not best: continue
        tops = [a for a in pc.atlas.values() if a.get('workSuitability', {}).get(key, 0) == best and obtainable(a['id'])]
        if not tops: continue
        tops.sort(key=lambda a: (a['id'] not in owned_ids, not pc.reachable(a['name']), -sum(a.get('workSuitability', {}).values()), a['name']))
        a = tops[0]
        alt = [t['name'] for t in tops[1:3]]
        goals.append({'group': 'Workers', 'role': 'work', 'sid': a['id'], 'name': a['name'], 'job': job, 'lv': best,
                      'els': [pc.EL.get(e, e) for e in a.get('elements', [])],
                      'why': f"{job} Lv {best}, the highest there is" + (f" (same level: {', '.join(alt)})" if alt else '') + '.',
                      'ideal': ideal_for('work', [])})
        if not available_now(a['id']):
            now = [t for t in pc.atlas.values() if t.get('workSuitability', {}).get(key, 0) and available_now(t['id'])]
            now.sort(key=lambda t: (-t['workSuitability'][key], t['id'] not in owned_ids, t['name']))
            if now:
                t = now[0]
                goals[-1]['nowName'] = t['name']
                goals.append({'group': 'Workers', 'role': 'work', 'sid': t['id'], 'name': t['name'], 'job': job, 'lv': t['workSuitability'][key],
                              'els': [pc.EL.get(e, e) for e in t.get('elements', [])], 'interim': True,
                              'why': f"{job} Lv {t['workSuitability'][key]}, the best {job} pal you can get right now ({a['name']} is better but not in reach yet).",
                              'ideal': ideal_for('work', [])})

    # ---- plan one goal: steps with odds ----
    def plan_goal(g):
        sid, ideal = g['sid'], g['ideal']
        mine = by_sp.get(sid, [])
        steps = []
        if not mine:
            h = how_to_get(sid)
            steps.append({'kind': 'get', 'text': h['text'], 'parents': h.get('parents', []), 'find': h.get('find', [])})
            if h['kind'] == 'later':
                return steps, 0, None
        best = max(mine, key=lambda p: (len(set(pids(p)) & set(ideal)), -sum(is_bad(x) for x in pids(p)), p['hp'] + p['atk'] + p['def']), default=None)
        have_any = set(x for p in mine for x in pids(p)) & set(ideal)
        same_only = all(pr['parent_a'] == sid and pr['parent_b'] == sid for pr in pc.FORMULA.get(sid, []))
        if same_only:
            want = [d for d in ideal if d not in have_any]
            if want:
                steps.append({'kind': 'note', 'text': f"Only two {g['name']} can make a {g['name']}, so other pals can't pass passives into it. "
                              f"Catch extra {g['name']} and keep any with {', '.join(pn(d) for d in want)}."})
            ideal_left = []
        else:
            ideal_left = ideal
        # bring in wanted passives that no pal of this kind has yet
        # one step: carrier x partner -> this kind; two steps: carrier x Q -> R, then R x P -> this kind
        r_to_p = {}
        for pr in pc.FORMULA.get(sid, []):
            if pr.get('parent_a_gender') or pr.get('parent_b_gender'): continue      # gender-specific: handled by hand
            a, b = pr['parent_a'], pr['parent_b']
            if a in by_sp: r_to_p.setdefault(b, a)
            if b in by_sp: r_to_p.setdefault(a, b)
        stuck, missing = [], []
        for d in ideal_left:
            if d in have_any: continue
            outside = sorted(carriers.get(d, []), key=lambda c: (len(c['passives']), -c['lv']))
            if not outside:
                missing.append(d)
                continue
            found = None
            for c in outside[:15]:
                cp = set(pids(c))
                psp = r_to_p.get(c['species'])
                if psp:
                    q = min((q for q in by_sp[psp] if can_mate(c, q)), key=lambda q: (len(q['passives']), -q['lv']), default=None)
                    if q:
                        pool = len(cp | set(pids(q)))
                        found = (0, [{'kind': 'carry', 'parents': [c['i'], q['i']],
                                      'text': f"Move {pn(d)} over: breed your {label(c)}, which has {pn(d)}, with your {label(q)}. Every egg is {g['name']}, and {pct(p_one(pool))} keep {pn(d)}."}])
                        break
                for qsp, qs in by_sp.items():
                    r = child_of(c['species'], qsp, c['gender'], {'M': 'F', 'F': 'M'}.get(c['gender'], ''))
                    if not r or r not in r_to_p: continue
                    q = min((q for q in qs if can_mate(c, q)), key=lambda q: (len(q['passives']), -q['lv']), default=None)
                    if not q: continue
                    psp = r_to_p[r]
                    pmate = min(by_sp[psp], key=lambda x: (len(x['passives']), -x['lv']))
                    cost = len(q['passives']) + len(pmate['passives'])
                    if found is None or cost < found[0]:
                        rn = pc.pal_name(r)
                        pool1 = len(cp | set(pids(q))); pool2 = 2 + len(pmate['passives'])
                        found = (cost, [
                            {'kind': 'carry', 'parents': [c['i'], q['i']],
                             'text': f"Move {pn(d)} over, step 1: breed your {label(c)}, which has {pn(d)}, with your {label(q)}. Every egg is {rn}. Keep one that got {pn(d)} ({pct(p_one(pool1))} do)."},
                            {'kind': 'carry', 'parents': [pmate['i']],
                             'text': f"Step 2: breed that {rn} with one of your {pc.pal_name(psp)} (opposite gender). Every egg is {g['name']}. Keep one that kept {pn(d)} ({pct(p_one(pool2))} do)."}])
                if found: break
            if found: steps.extend(found[1])
            else: stuck.append((d, outside[0]))
        if stuck:
            steps.append({'kind': 'note', 'parents': [c['i'] for _, c in stuck],
                          'text': 'Keep these carriers: ' + '; '.join(f"your {label(c)} has {pn(d)}" for d, c in stuck) +
                                  f". None of your pals can carry it into {g['name']} yet, but that changes as you own more kinds of pals."})
        if missing:
            rare = [d for d in missing if (pc.PASS.get(d) or {}).get('add_rare_pal') and not (pc.PASS.get(d) or {}).get('add_pal')]
            normal = [d for d in missing if d not in rare]
            txt = ''
            if normal: txt += f"None of your pals has {', '.join(pn(d) for d in normal)} yet. It can show up on wild pals, so keep any pal you catch with it as a carrier. "
            if rare: txt += f"{', '.join(pn(d) for d in rare)} only shows up on Lucky (shiny) pals, so keep every Lucky pal you catch."
            steps.append({'kind': 'note', 'text': txt.strip()})
        # the final stack: best pair of this kind
        final = None
        if len(mine) >= 2:
            pairs = []
            for i, p in enumerate(mine):
                for q in mine[i + 1:]:
                    if not can_mate(p, q): continue
                    pool = set(pids(p)) | set(pids(q))
                    want = pool & set(ideal)
                    pairs.append((len(want), -len(pool - set(ideal)), p, q, pool, want))
            if pairs:
                k, negjunk, p, q, pool, want = max(pairs, key=lambda t: (t[0], t[1]))
                if k >= 2:
                    pr = p_all(len(pool), k)
                    junk = [x for x in pool if x not in ideal]
                    txt = f"Stack them: breed your {label(p)} with your {label(q)}. Together they carry {', '.join(pn(x) for x in want)}"
                    txt += f" plus {len(junk)} other passive{'s' if len(junk) != 1 else ''}" if junk else ''
                    txt += f". A baby with all {k} comes {odds_text(pr)}."
                    if junk:
                        txt += f" With parents that carried only the passives you want, it would be {odds_text(p_all(k, k))}, so swap in cleaner parents when you get them."
                    final = {'kind': 'combine', 'parents': [p['i'], q['i']], 'text': txt, 'odds': pr}
                    steps.append(final)
        if mine and len(mine) < 2:
            steps.append({'kind': 'note', 'text': f"You have one {g['name']}. Catch or breed a {other_gender(mine[0]['gender']) or 'second'} one so you can pair them."})
        score = len(set(pids(best)) & set(ideal)) if best else 0
        return steps, score, best

    for g in goals:
        steps, score, best = plan_goal(g)
        g['steps'] = steps
        g['bestPal'] = best['i'] if best else None
        g['have'] = score
        mine = set(x for p in by_sp.get(g['sid'], []) for x in pids(p))
        g['idealView'] = [{'n': pn(d), 'd': (pc.PASSN.get(d) or {}).get('description', ''),
                           'state': 'have' if best and d in pids(best) else ('kind' if d in mine else ('carrier' if carriers.get(d) else 'none'))}
                          for d in g['ideal']]
        h = how_to_get(g['sid'])
        g['status'] = ('Done' if best and score >= len(g['ideal']) else 'Close' if score >= 3 else
                       'Started' if g['sid'] in owned_ids else ('Can start now' if h['kind'] in ('catch', 'breed', 'raid') else 'Later'))
        g['how'] = h['text']
        g['find'] = h.get('find', [])

    # ---- the plan: what to do next ----
    crew_sp = {pals_by_i['species'] for c in crews for m in c.get('members', []) for pals_by_i in [next((x for x in pals if x['i'] == m['i']), None)] if pals_by_i}
    team_sp = {pals_by_i['species'] for a in attack if a['group'] in ('Towers', 'Story bosses') for t in a['team'] for pals_by_i in [next((x for x in pals if x['i'] == t['i']), None)] if pals_by_i}
    plan = []
    for g in goals:
        if g['status'] in ('Done', 'Later'): continue
        if not any(s['kind'] in ('carry', 'combine') or (s['kind'] == 'get' and s.get('parents')) for s in g['steps']): continue
        prio = (g['have'] * 3 + (4 if g['sid'] in crew_sp or g['sid'] in team_sp else 0) + (3 if g['sid'] in owned_ids else 0)
                + (2 if any(s['kind'] in ('carry', 'combine') for s in g['steps']) else 0) + (1 if g.get('interim') else 0))
        nxt = next((s for s in g['steps'] if s['kind'] in ('get', 'carry', 'combine')), None)
        title = f"{g['name']}: " + (f"the best {g['job']} worker" if g['role'] == 'work' else f"{'/'.join(g['els'])} heavy hitter")
        boost = sum(max(0, effects(d).get('CraftSpeed', 0)) for d in g['ideal']) if g['role'] == 'work' else \
            sum(max(0, effects(d).get('ShotAttack', 0)) + max([effects(d).get('ElementBoost_' + pc.ELI.get(x, x), 0) for x in g['els']] + [0]) for d in g['ideal'])
        why = g['why'] + (f" With {', '.join(pn(d) for d in g['ideal'])} it works about {round(boost)}% faster and needs less rest and food."
                          if g['role'] == 'work' else f" With {', '.join(pn(d) for d in g['ideal'])} it deals about {round(boost)}% more damage.")
        if g['sid'] in crew_sp: why += ' It is already in one of your crews, so every step pays off right away.'
        if g['sid'] in team_sp: why += ' It is already on one of your boss teams.'
        plan.append({'title': title, 'why': why, 'status': g['status'], 'steps': g['steps'], 'ideal': g['idealView'],
                     'next': nxt['text'] if nxt else '', 'prio': prio, 'role': 'Workers' if g['role'] == 'work' else 'Fighters'})
    plan.sort(key=lambda x: -x['prio'])
    picked, count = [], collections.Counter()
    for x in plan:
        if count[x['role']] < 3: picked.append(x); count[x['role']] += 1
    for x in plan:
        if len(picked) >= 6: break
        if x not in picked: picked.append(x)
    plan = sorted(picked[:6], key=lambda x: -x['prio'])

    # ---- mixed pairs that make a pal you don't have ----
    goal_sp = {g['sid'] for g in goals}
    pair_out = []
    seen = set()
    sp_list = sorted(by_sp)
    for i, a in enumerate(sp_list):
        for b in sp_list[i:]:
            if a == b: continue
            pa = pb = c = None
            for x in by_sp[a]:
                for y in by_sp[b]:
                    if can_mate(x, y):
                        c = child_of(a, b, x['gender'], y['gender'])
                        if c: pa, pb = x, y; break
                if pa: break
            if not pa or c in owned_ids or c in seen: continue
            at = pc.atlas.get(c) or {}
            ways = [pr for pr in pc.FORMULA.get(c, []) if not (pr['parent_a'] == c and pr['parent_b'] == c)]
            special = len(ways) <= 3
            nm = pc.pal_name(c)
            catch_ok = pc.reachable(nm)
            work_best = max(at.get('workSuitability', {}).values(), default=0)
            value = at.get('attack', 0) / 10 + work_best * 3 + (8 if c in goal_sp else 0) + (6 if special else 0) + (5 if not catch_ok else 0)
            seen.add(c)
            pair_out.append((value, {'child': nm, 'parents': [pa['i'], pb['i']],
                'why': ('Special pair: only a few exact pairs make this pal. ' if special else '') +
                       (f"It is one of your end-game goals. " if c in goal_sp else '') +
                       (f"You can't catch it where you can go right now, so breeding is the way to get it. " if not catch_ok else f"You could also catch it, but this works from home. ") +
                       f"Base Attack {at.get('attack', '?')}" + (f", best work Lv {work_best}" if work_best else '') + '.',
                'note': 'The same pair always gives the same kind of pal, so one egg is enough.'}))
    pair_out.sort(key=lambda t: -t[0])
    pairs = [x for _, x in pair_out[:6]]

    # ---- what not to waste Cake on ----
    avoid = []
    key_pals = [p for p in pals if p['species'] in crew_sp | team_sp | goal_sp]
    badp = [p for p in key_pals if any(is_bad(x) for x in pids(p))]
    if badp:
        avoid.append({'title': 'Parents with bad passives',
                      'text': 'These pals carry passives that make a pal worse, and babies can inherit them. Do not use them as parents. Breed from a clean one of the same kind instead: ' +
                              '; '.join(f"{label(p)}: {', '.join(pn(x) for x in pids(p) if is_bad(x))}" for p in badp[:6]) + '.',
                      'pals': [p['i'] for p in badp[:6]]})
    big = []
    for g in goals:
        for s in g['steps']:
            if s['kind'] == 'combine' and s.get('odds', 1) < .01: big.append(g['name'])
    if big:
        avoid.append({'title': 'Pairs with too many passives',
                      'text': f"For {', '.join(sorted(set(big)))}, your best pair carries so many different passives that a perfect baby comes less than 1 egg in 100. "
                              "Breed toward cleaner parents first (pals with only the passives you want), then stack.", 'pals': []})
    catchable_goals = [g['name'] for g in goals if g['sid'] not in owned_ids and pc.reachable(g['name'])]
    if catchable_goals:
        avoid.append({'title': 'Breeding for pals you can simply catch',
                      'text': f"{', '.join(catchable_goals[:6])} can be caught where you can already go. Catching is faster than breeding for them. Breed only once you have one, to stack passives.", 'pals': []})
    low = [p for p in pals if p['lv'] <= 20 and not any(fight_value(x, p['elements']) > 0 or work_value(x) > 0 for x in pids(p))
           and p['species'] not in crew_sp | team_sp | goal_sp and (p['hp'] + p['atk'] + p['def']) < 120]
    lowc = collections.Counter(p['name'] for p in low).most_common(5)
    if lowc:
        avoid.append({'title': 'Low-value pals',
                      'text': f"{', '.join(f'{n} ({c})' for n, c in lowc)}: low level, low true values and no useful passives. Use them for condensing instead of Cake.", 'pals': []})

    # ---- best parents to keep ----
    def keep_score(p):
        good = [x for x in pids(p) if (fight_value(x, p['elements']) >= 20 or work_value(x) >= 20) and not is_bad(x)]
        return len(good) * 10 + (p['hp'] + p['atk'] + p['def']) / 30 - 8 * sum(is_bad(x) for x in pids(p))
    keepers = sorted(pals, key=lambda p: -keep_score(p))[:6]

    for g in goals:
        g.pop('ideal', None)
    return {'plan': plan, 'goals': goals, 'pairs': pairs, 'avoid': avoid, 'keep': [p['i'] for p in keepers],
            'access': dict(pc.ACCESS)}
