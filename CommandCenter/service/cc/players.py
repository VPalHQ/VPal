"""Who's online, everyone who has ever joined (with playtime), joins/leaves/level-ups, bans and the whitelist."""
import os, time, threading
from . import util

KNOWN = util.data('players.json')
_lock = threading.RLock()


def pid_of(p):
    return str(p.get('userId') or p.get('playerId') or p.get('name') or '')


class Tracker:
    def __init__(self):
        self.known = util.read_json(KNOWN, {}) or {}
        self.online = {}            # id -> player dict from the REST API (plus 'since')
        self.last_poll = None
        self.dirty = False

    def update(self, players, cfg, api):
        """players: the REST /players list. Records joins, leaves, level-ups and playtime; enforces the whitelist."""
        t = time.time()
        step = min(60, t - self.last_poll) if self.last_poll else 0
        self.last_poll = t
        now_ids = set()
        wl = cfg['whitelist']
        allowed = {x.strip().lower() for x in wl.get('ids', []) if x.strip()}
        with _lock:
            for p in players:
                uid = pid_of(p)
                if not uid: continue
                if wl.get('enabled') and allowed and not ({uid.lower(), str(p.get('playerId', '')).lower(), str(p.get('name', '')).lower()} & allowed):
                    try:
                        api.kick(uid, wl.get('message') or '')
                        util.event('whitelist', f"Removed {p.get('name') or uid}: not on the whitelist.", 'warn', player=uid)
                    except Exception as e:
                        util.log_error('Whitelist kick', e)
                    # remember them, so the control panel can show who was turned away and add them with one click
                    k = self.known.setdefault(uid, {'name': p.get('name', ''), 'first': round(t), 'play': 0, 'sessions': 0})
                    k.update({'name': p.get('name') or k.get('name', ''), 'playerId': p.get('playerId', ''),
                              'level': int(p.get('level') or 0), 'turned_away': round(t)})
                    self.dirty = True
                    continue
                now_ids.add(uid)
                k = self.known.setdefault(uid, {'name': p.get('name', ''), 'first': round(t), 'play': 0, 'sessions': 0})
                lv = int(p.get('level') or 0)
                if uid not in self.online:
                    k['sessions'] = k.get('sessions', 0) + 1
                    self.online[uid] = dict(p, since=t)
                    util.event('join', f"{p.get('name') or uid} joined (Lv {lv}).", 'good', player=uid)
                else:
                    k['play'] = round(k.get('play', 0) + step)
                    old = int(self.online[uid].get('level') or 0)
                    if lv > old > 0:
                        util.event('levelup', f"{p.get('name') or uid} reached Lv {lv}.", 'good', player=uid)
                    self.online[uid].update(p)
                k.update({'name': p.get('name') or k.get('name', ''), 'account': p.get('accountName', ''), 'playerId': p.get('playerId', ''),
                          'level': lv, 'last': round(t)})
                k.pop('turned_away', None)
                self.dirty = True
            for uid in list(self.online):
                if uid not in now_ids:
                    p = self.online.pop(uid)
                    mins = round((t - p.get('since', t)) / 60)
                    util.event('leave', f"{p.get('name') or uid} left after {mins} min.", 'info', player=uid)
                    self.dirty = True
        if self.dirty and (not getattr(self, '_saved', 0) or t - self._saved > 60):
            self.save()

    def server_gone(self):
        """The server stopped: everyone is offline."""
        with _lock:
            if self.online:
                for uid, p in self.online.items():
                    util.event('leave', f"{p.get('name') or uid} was disconnected (server stopped).", 'info', player=uid)
                self.online.clear()
                self.save()
        self.last_poll = None

    def save(self):
        with _lock:
            util.write_json(KNOWN, self.known)
            self.dirty = False
            self._saved = time.time()

    def snapshot(self):
        with _lock:
            on = [{'id': uid, 'name': p.get('name', ''), 'level': p.get('level'), 'ping': p.get('ping'), 'x': p.get('location_x'),
                   'y': p.get('location_y'), 'buildings': p.get('building_count'), 'since': round(p.get('since', 0)),
                   'account': p.get('accountName', '')} for uid, p in self.online.items()]
            known = [dict(v, id=k, online=k in self.online) for k, v in self.known.items()]
        known.sort(key=lambda x: -(x.get('last') or 0))
        return {'online': on, 'known': known}


def banlist(sd):
    """User ids in the server's ban list (Pal\\Saved\\SaveGames\\banlist.txt)."""
    p = os.path.join(sd, 'Pal', 'Saved', 'SaveGames', 'banlist.txt')
    try:
        with open(p, encoding='utf-8-sig', errors='replace') as f:
            return [l.strip() for l in f if l.strip()]
    except OSError:
        return []
