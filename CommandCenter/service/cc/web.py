"""The watchdog's local API, used by the control panel (and the Pal Planner's map) on this PC only.

Answers only on 127.0.0.1:18770. Anything that came through a proxy (the family link) or names another host is
refused, and every change needs an X-CC header that a web page on another site can't add without asking first.
There is no web page: the control panel is the only screen.
"""
import os, json, time, urllib.parse, http.server
from . import util, config, procs, players, backups, health, planner, discord, release
from .palapi import ApiError

SVC = None          # the watchdog.Service, set by ccservice.py


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'PalworldWatchdog'

    def log_message(self, *a):
        pass

    FORWARD = ('X-Forwarded-For', 'X-Forwarded-Proto', 'X-Forwarded-Host', 'Forwarded', 'Tailscale-Funnel-Request', 'Tailscale-User-Login')

    def _local(self):
        h = (self.headers.get('Host') or '').lower()
        return h in (f'127.0.0.1:{util.PORT}', f'localhost:{util.PORT}') and not any(self.headers.get(x) for x in self.FORWARD)

    def _send(self, code, body):
        body = json.dumps(body, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(body)

    def _json_body(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n > 200_000: raise ValueError('too big')
        raw = self.rfile.read(n) if n else b'{}'
        return json.loads(raw.decode('utf-8') or '{}')

    # ---------------- GET ----------------
    def do_GET(self):
        if not self._local(): return self._send(403, {'error': 'This only answers on the server PC.'})
        u = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        if not u.path.startswith('/api/'):
            return self._send(404, {'error': 'Nothing here. Use the Palworld control panel.'})
        try:
            return self._send(200, self.get_api(u.path[5:], q))
        except FileNotFoundError as e:
            return self._send(404, {'error': str(e)})
        except Exception as e:
            return self._send(500, {'error': str(e)})

    def get_api(self, path, q):
        s = SVC
        if path == 'status': return s.status
        if path == 'live':
            # for the Pal Planner's map (asked by the planner's own web server on this PC, after it checked the player's code)
            TX, TY, SC = 123930.0, 157935.0, 459.0          # same world-to-map numbers as the planner
            out = []
            for p in s.tracker.online.values():
                try: x, y = float(p.get('location_x')), float(p.get('location_y'))
                except (TypeError, ValueError): continue
                out.append({'name': p.get('name', ''), 'level': p.get('level'), 'gx': round((y - TY) / SC), 'gy': round((x + TX) / SC)})
            return {'t': round(time.time()), 'state': s.status.get('state'), 'players': out,
                    'game': s.status.get('gameVersion') or ''}          # the Ask tab warns if the game is newer than its data
        if path == 'discord':
            c = discord.load()
            r = discord.public(c)
            r['invite'] = discord.invite_url(c) if c.get('app_id') else ''
            ts = planner.tailscale_info()
            r['familyLink'] = bool(ts.get('funnel') and ts.get('dns'))
            r['commandsUrl'] = f"https://{ts['dns']}/discord" if ts.get('dns') else ''
            r['mounted'] = any(x.get('path', '').rstrip('/') == '/discord' for x in ts.get('paths') or [])
            if q.get('guilds') and c.get('token'):
                try: r['guilds'] = discord.guilds()
                except discord.DiscordError as e: r['guildsError'] = str(e)
            if q.get('channels') and c.get('token'):
                try:
                    raw = discord.rest('GET', f"/guilds/{q['channels']}/channels")
                    r['channels'] = discord.channels(q['channels'], raw)
                    r['voiceChannels'] = discord.voice_channels(q['channels'], raw)
                except discord.DiscordError as e: r['channelsError'] = str(e)
            r['voice'] = discord.voice_status()
            return r
        if path == 'voice': return discord.voice_status()
        if path == 'health': return health.run(s)
        if path == 'vpal-update': return release.public()
        if path == 'players':
            snap = s.tracker.snapshot()
            snap['bans'] = players.banlist(s.sd)
            snap['whitelist'] = s.cfg['whitelist']
            return snap
        if path == 'events':
            kinds = set(q['kinds'].split(',')) if q.get('kinds') else None
            return {'list': util.recent_events(int(q.get('limit') or 100), kinds)}
        if path == 'backups':
            return {'list': backups.list_all(s.sd), 'keep': s.cfg['backups']['keep'], 'folder': backups.DIR}
        if path == 'backups/preview':
            return backups.preview(s.sd, q.get('id', ''))
        if path == 'config':
            c = config.load()
            tot, _ = procs.system_memory()
            c['_auto'] = {'memLimit': config.memory_limit_gb(dict(c, memory=dict(c['memory'], limit_gb=0)), tot), 'pcTotal': round(tot, 1),
                          'startScript': config.start_script(c, s.sd), 'steamcmd': config.steamcmd_path(c, s.sd), 'serverDir': s.sd,
                          'ports': config.ports(s.sd), 'restApi': bool(config.api_info(s.sd))}
            return c
        raise FileNotFoundError('Unknown: ' + path)

    # ---------------- POST (changes) ----------------
    def do_POST(self):
        if not self._local(): return self._send(403, {'error': 'This only answers on the server PC.'})
        if self.headers.get('X-CC') != '1': return self._send(403, {'error': 'Not allowed.'})
        u = urllib.parse.urlparse(self.path)
        if not u.path.startswith('/api/'): return self._send(404, {'error': 'Unknown.'})
        try:
            return self._send(200, self.post_api(u.path[5:], self._json_body()) or {'ok': True})
        except (ApiError, RuntimeError, ValueError, FileNotFoundError) as e:
            return self._send(400, {'error': str(e)})
        except Exception as e:
            util.log_error('Control panel request', e)
            return self._send(500, {'error': str(e)})

    def post_api(self, path, b):
        s = SVC
        api = s.api()
        mins = float(b.get('minutes') or 0)
        if path == 'server/start': s.act_start(); return
        if path == 'server/stop': s.act_stop(mins); return
        if path == 'server/restart': s.act_restart(mins, b.get('reason') or 'you restarted it'); return
        if path == 'server/save':
            api.save(); util.event('backup', 'Saved the world.', 'info'); return
        if path == 'job/cancel':
            if not s.act_cancel(): raise RuntimeError('That can no longer be cancelled.')
            return
        if path in ('players/kick', 'players/ban', 'players/unban'):
            uid = str(b.get('id') or '').strip()
            if not uid: raise ValueError('No player picked.')
            who = (s.tracker.known.get(uid) or {}).get('name') or uid
            if path == 'players/kick': api.kick(uid, b.get('message', '')); util.event('kick', f'Kicked {who}.', 'warn', player=uid)
            if path == 'players/ban': api.ban(uid, b.get('message', '')); util.event('ban', f'Banned {who}.', 'bad', player=uid)
            if path == 'players/unban': api.unban(uid); util.event('unban', f'Unbanned {who}.', 'good', player=uid)
            return
        if path == 'whitelist':
            cur = config.load()['whitelist']
            ids = [str(x).strip() for x in (b.get('ids', cur['ids']) or []) if str(x).strip()]
            c = config.update({'whitelist': {'enabled': bool(b.get('enabled', cur['enabled'])), 'ids': ids, 'message': b.get('message', cur['message'])}})
            util.event('whitelist', 'Whitelist ' + ('on' if c['whitelist']['enabled'] else 'off') + f" ({len(c['whitelist']['ids'])} allowed).", 'info')
            s.cfg = c
            return c['whitelist']
        if path == 'backups/create': s.act_backup(b.get('note', '')); return
        if path == 'backups/restore':
            if b.get('confirm') != 'RESTORE': raise ValueError('Restore was not confirmed.')
            s.act_restore(str(b.get('id') or ''), mins); return
        if path == 'config':
            c = config.update(b)
            s.cfg = c
            s.ext_checked = 0                     # look at the Windows restart task again on the next check
            util.event('service', 'Watchdog settings changed.', 'info')
            return c
        if path == 'update/check': s.act_check_update(); return
        if path == 'vpal-update/check': return release.check(force=True)
        if path == 'vpal-update/start': return release.start(s)
        if path.startswith('discord/'): return self.post_discord(path[8:], b)
        if path == 'hold/clear':
            s.clear_hold(any_hold=True); util.event('service', 'You turned the watchdog back on.', 'info'); return
        raise FileNotFoundError('Unknown: ' + path)

    # ---------------- Discord ----------------
    def post_discord(self, what, b):
        try:
            if what == 'app': return discord.check_app(b.get('app_id'), b.get('public_key'), b.get('token'))
            if what == 'server':
                v = b.get('voice_id')
                return discord.choose(str(b.get('guild_id') or ''), str(b.get('channel_id') or ''), None if v is None else str(v))
            if what == 'alerts':
                c = discord.load()
                if 'enabled' in b: c['enabled'] = bool(b['enabled'])
                for k, v in (b.get('alerts') or {}).items():
                    if k in discord.ALERT_DEFAULTS: c['alerts'][k] = bool(v)
                discord.save(c); return discord.public(c)
            if what == 'test':
                discord.send('✅ VPal Server Command Center can post here. Alerts will show up in this channel.'); return
            if what == 'commands':
                on = bool(b.get('on'))
                c = discord.load()
                if on:
                    ts = planner.tailscale_info(fresh=True)
                    if not (ts.get('funnel') and ts.get('dns')): raise RuntimeError('Slash commands come in through your family link. Turn it on first.')
                    r = planner.funnel_path(True, '/discord', discord.PORT)
                    if not r['ok']: return {'ok': False, 'text': r['text'], 'approve': r['approve']}
                    time.sleep(2)
                    discord.set_endpoint(f"https://{ts['dns']}/discord", tries=4)
                    discord.register_commands()
                    c = discord.load(); c['commands_on'] = True; discord.save(c)
                    util.event('discord', 'Discord slash commands are on.', 'good')
                else:
                    try: discord.set_endpoint('')
                    except discord.DiscordError: pass
                    planner.funnel_path(False, '/discord')
                    c = discord.load(); c['commands_on'] = False; discord.save(c)
                    util.event('discord', 'Discord slash commands are off.', 'info')
                return {'ok': True}
            if what == 'forget':
                try: discord.set_endpoint('')
                except discord.DiscordError: pass
                planner.funnel_path(False, '/discord')
                discord.save({}); util.event('discord', 'Disconnected the Discord bot.', 'info'); return
        except discord.DiscordError as e:
            raise RuntimeError(str(e))
        raise FileNotFoundError('Unknown: discord/' + what)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def server_bind(self):
        import socket
        # Only one watchdog may listen. Windows: exclusive use of the port. Linux: allow re-binding over old
        # closed connections (TIME_WAIT), which still refuses a second listener.
        if util.IS_WIN and hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        elif not util.IS_WIN:
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        super().server_bind()


def make_server():
    return Server(('127.0.0.1', util.PORT), Handler)
