"""The Discord bot: alerts in a channel you pick, and slash commands (/status, /players, /restart ...).

How it talks to Discord:
  * alerts and setup use Discord's REST API with the bot token (outgoing https only)
  * slash commands arrive as signed web requests: Discord -> your family link /discord (Tailscale Funnel) -> this PC
    on 127.0.0.1:18771. Every request must carry Discord's Ed25519 signature or it is refused.
Admin commands (restart, stop, kick ...) only work for people with Manage Server or Administrator in your Discord.
The bot token is kept in data\\discord.json on this PC and is never shown anywhere.
"""
import os, json, time, queue, threading, urllib.request, urllib.error, http.server
from . import util, config, ed25519

API = os.environ.get('CC_DISCORD_API') or 'https://discord.com/api/v10'
CFG = util.data('discord.json')
PORT = 18771
PERMS = 1024 + 2048 + 16384          # view channels, send messages, embed links
ADMIN_BITS = 0x8 | 0x20               # Administrator, Manage Server
UA = f'DiscordBot (https://github.com/palworld-command-center, {util.VERSION})'
ALERT_DEFAULTS = {'problems': True, 'restarts': True, 'updates': True, 'backups': False, 'joins': False, 'levelups': False}
KIND_GROUP = {'crash': 'problems', 'freeze': 'problems', 'error': 'problems', 'memory': 'restarts', 'restart': 'restarts',
              'schedule': 'restarts', 'start': 'restarts', 'stop': 'restarts', 'update': 'updates', 'backup': 'backups',
              'restore': 'restarts', 'join': 'joins', 'leave': 'joins', 'levelup': 'levelups'}
SVC = None
_q = queue.Queue(maxsize=200)


class DiscordError(Exception):
    pass


def load():
    c = util.read_json(CFG, {}) or {}
    c.setdefault('alerts', dict(ALERT_DEFAULTS))
    for k, v in ALERT_DEFAULTS.items(): c['alerts'].setdefault(k, v)
    return c


def save(c):
    util.write_json(CFG, c)


def public(c=None):
    """What the control panel may see (never the token)."""
    c = c or load()
    out = {k: v for k, v in c.items() if k != 'token'}
    out['hasToken'] = bool(c.get('token'))
    return out


def rest(method, path, body=None, token=None, timeout=15):
    token = token or load().get('token')
    if not token: raise DiscordError('The bot token is not set yet.')
    data = None if body is None else json.dumps(body).encode('utf-8')
    for attempt in range(3):
        req = urllib.request.Request(API + path, data=data, method=method, headers={
            'Authorization': 'Bot ' + token, 'User-Agent': UA, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            txt = e.read().decode('utf-8', errors='replace')
            if e.code == 429 and attempt < 2:
                try: time.sleep(min(10, float(json.loads(txt).get('retry_after', 2))))
                except ValueError: time.sleep(2)
                continue
            if e.code == 401: raise DiscordError('Discord did not accept the bot token. Copy it again (Bot > Reset Token).')
            if e.code == 403: raise DiscordError('Discord says the bot is not allowed to do that. Check it was added to your server and can see the channel.')
            raise DiscordError(f'Discord answered {e.code}: {txt[:200]}')
        except urllib.error.URLError as e:
            raise DiscordError(f'Could not reach Discord ({e.reason}).')
    raise DiscordError('Discord is busy. Try again in a minute.')


# ---------------- setup ----------------
def check_app(app_id, public_key, token):
    app_id, public_key, token = (app_id or '').strip(), (public_key or '').strip(), (token or '').strip()
    if token in ('', '__keep__'): token = load().get('token') or ''
    if not token: raise DiscordError('Paste the bot token (Bot > Reset Token).')
    if token.lower().startswith('bot '): token = token[4:].strip()
    if not app_id.isdigit(): raise DiscordError('The Application ID is a long number (General Information > Application ID).')
    try:
        if len(bytes.fromhex(public_key)) != 32: raise ValueError
    except ValueError:
        raise DiscordError('The Public Key is 64 letters and numbers (General Information > Public Key).')
    me = rest('GET', '/users/@me', token=token)
    app = rest('GET', '/applications/@me', token=token)
    if str(app.get('id')) != app_id: raise DiscordError('That bot token belongs to a different application than the Application ID.')
    c = load()
    c.update({'app_id': app_id, 'public_key': public_key, 'token': token, 'bot_name': me.get('username', ''), 'checked': round(time.time())})
    save(c)
    util.event('discord', f"Discord bot connected: {me.get('username', '')}.", 'good')
    return public(c)


def invite_url(c=None):
    c = c or load()
    return (f"https://discord.com/oauth2/authorize?client_id={c.get('app_id', '')}&scope=bot%20applications.commands"
            f"&permissions={PERMS}&integration_type=0")


def guilds():
    return [{'id': g['id'], 'name': g.get('name', '')} for g in rest('GET', '/users/@me/guilds')]


def channels(guild_id, raw=None):
    out = []
    for ch in raw if raw is not None else rest('GET', f'/guilds/{guild_id}/channels'):
        if ch.get('type') in (0, 5): out.append({'id': ch['id'], 'name': ch.get('name', ''), 'pos': ch.get('position', 0)})
    return sorted(out, key=lambda c: c['pos'])


def voice_channels(guild_id, raw=None):
    out = []
    for ch in raw if raw is not None else rest('GET', f'/guilds/{guild_id}/channels'):
        if ch.get('type') in (2, 13): out.append({'id': ch['id'], 'name': ch.get('name', ''), 'pos': ch.get('position', 0)})
    return sorted(out, key=lambda c: c['pos'])


def choose(guild_id, channel_id, voice_id=None):
    """The Discord server, the text channel for alerts and (optional) the voice channel for the Pal Planner's Voice tab."""
    c = load()
    gs = {g['id']: g['name'] for g in guilds()}
    if guild_id not in gs: raise DiscordError('The bot is not in that Discord server yet. Use the invite link first.')
    raw = rest('GET', f'/guilds/{guild_id}/channels')
    chs = {ch['id']: ch['name'] for ch in channels(guild_id, raw)}
    if channel_id not in chs: raise DiscordError('Pick a text channel.')
    c.update({'guild_id': guild_id, 'guild_name': gs[guild_id], 'channel_id': channel_id, 'channel_name': chs[channel_id]})
    if voice_id is not None:
        vcs = {ch['id']: ch['name'] for ch in voice_channels(guild_id, raw)}
        if voice_id and voice_id not in vcs: raise DiscordError('Pick a voice channel, or none.')
        c.update({'voice_id': voice_id, 'voice_name': vcs.get(voice_id, '')})
    save(c)
    _voice_cache.clear()
    return public(c)


# ---------------- the Pal Planner's Voice tab ----------------
_voice_cache = {}


def widget(guild_id):
    """The server widget (Discord: Server Settings > Widget > Enable Server Widget). Public, no token. Lists online
    members, with the voice channel each one is in, for voice channels that @everyone can see."""
    req = urllib.request.Request(f'{API}/guilds/{guild_id}/widget.json', headers={'User-Agent': UA})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return 'ok', json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        if e.code in (403, 404): return 'off', {}
        return 'error', {}
    except (urllib.error.URLError, OSError, ValueError):
        return 'error', {}


def voice_status():
    """What the Pal Planner's Voice tab shows. Asked often by everyone's phones, so it is kept for 20 seconds."""
    c = load()
    gid, vid = c.get('guild_id'), c.get('voice_id')
    if not (gid and vid): return {'configured': False}
    hit = _voice_cache.get('v')
    if hit and time.time() - hit[0] < 20: return hit[1]
    state, w = widget(gid)
    out = {'configured': True, 'server': c.get('guild_name', ''), 'channel': c.get('voice_name', ''),
           'joinUrl': f'https://discord.com/channels/{gid}/{vid}', 'appUrl': f'discord://-/channels/{gid}/{vid}',
           'widget': state, 'inVoice': None, 'invite': '', 't': round(time.time())}
    if state == 'ok':
        visible = any(str(ch.get('id')) == str(vid) for ch in w.get('channels') or [])
        out['inVoice'] = sorted({str(m.get('username') or '') for m in w.get('members') or [] if str(m.get('channel_id') or '') == str(vid)} - {''},
                                key=str.lower) if visible else None
        out['private'] = not visible
        out['invite'] = str(w.get('instant_invite') or '')
    _voice_cache['v'] = (time.time(), out)
    return out


ADMIN = '32'          # default_member_permissions: Manage Server (Discord hides these from everyone else)
MINUTES = {'name': 'warning', 'description': 'Minutes of warning for players in the game', 'type': 4, 'required': False,
           'choices': [{'name': 'none', 'value': 0}, {'name': '1 minute', 'value': 1}, {'name': '5 minutes', 'value': 5}, {'name': '10 minutes', 'value': 10}]}
PLAYER = {'name': 'player', 'description': 'Who', 'type': 3, 'required': True, 'autocomplete': True}
COMMANDS = [
    {'name': 'status', 'description': 'How the Palworld server is doing'},
    {'name': 'players', 'description': 'Who is online right now'},
    {'name': 'playtime', 'description': 'Who has played the most'},
    {'name': 'planner', 'description': 'Get the Pal Planner link'},
    {'name': 'restart', 'description': 'Restart the server (warns players first)', 'default_member_permissions': ADMIN, 'options': [MINUTES]},
    {'name': 'stop', 'description': 'Stop the server', 'default_member_permissions': ADMIN, 'options': [MINUTES]},
    {'name': 'start', 'description': 'Start the server', 'default_member_permissions': ADMIN},
    {'name': 'backup', 'description': 'Back up the world now', 'default_member_permissions': ADMIN},
    {'name': 'announce', 'description': 'Send a message to everyone in the game', 'default_member_permissions': ADMIN,
     'options': [{'name': 'message', 'description': 'What to say', 'type': 3, 'required': True, 'max_length': 200}]},
    {'name': 'kick', 'description': 'Remove a player until they rejoin', 'default_member_permissions': ADMIN, 'options': [PLAYER]},
    {'name': 'ban', 'description': 'Ban a player', 'default_member_permissions': ADMIN, 'options': [PLAYER]},
    {'name': 'unban', 'description': 'Unban a player', 'default_member_permissions': ADMIN, 'options': [PLAYER]},
]


def register_commands():
    c = load()
    if not c.get('guild_id'): raise DiscordError('Pick your Discord server first.')
    rest('PUT', f"/applications/{c['app_id']}/guilds/{c['guild_id']}/commands", COMMANDS)
    c['commands'] = round(time.time()); save(c)


def set_endpoint(url, tries=1):
    """Tells Discord where to send slash commands. Discord checks the address right away (it sends a test request),
    so when the family link has only just been set up this can take a few tries."""
    for n in range(tries):
        try:
            rest('PATCH', '/applications/@me', {'interactions_endpoint_url': url})
            break
        except DiscordError as e:
            if 'could not be verified' not in str(e) and 'interactions_endpoint_url' not in str(e): raise
            if n == tries - 1:
                raise DiscordError("Discord couldn't reach your family link at /discord. Check the family link works on a "
                                   'phone, wait a minute and try again.')
            time.sleep(5)
    c = load(); c['endpoint'] = url; save(c)


def keep_endpoint():
    """Discord drops the commands address if it can't reach it for a while (for example while the family link was
    off). Checks it is still set to this server's family link and sets it again if not."""
    from . import planner
    c = load()
    if not (c.get('commands_on') and c.get('token')): return
    ts = planner.tailscale_info()
    if not (ts.get('funnel') and ts.get('dns')): return
    if not any((x.get('path') or '').rstrip('/') == '/discord' for x in ts.get('paths') or []): return
    want = f"https://{ts['dns']}/discord"
    if (rest('GET', '/applications/@me').get('interactions_endpoint_url') or '') != want:
        set_endpoint(want, tries=3)
        util.event('discord', 'Reconnected Discord slash commands to the family link.', 'info')


def send(text):
    c = load()
    if not (c.get('token') and c.get('channel_id')): raise DiscordError('Finish the Discord setup first.')
    return rest('POST', f"/channels/{c['channel_id']}/messages", {'content': text[:1900], 'allowed_mentions': {'parse': []}})


# ---------------- alerts (from the activity log) ----------------
ICON = {'bad': '🔴', 'warn': '🟠', 'good': '🟢', 'info': '🔵'}


def on_event(e):
    c = load()
    if not (c.get('enabled') and c.get('channel_id') and c.get('token')): return
    group = KIND_GROUP.get(e['kind'])
    if e['kind'] == 'error' and e.get('level') != 'bad': return
    if not group or not c['alerts'].get(group): return
    try: _q.put_nowait(f"{ICON.get(e.get('level'), '•')} {e['text']}")
    except queue.Full: pass


def _sender():
    while True:
        text = _q.get()
        batch = [text]
        time.sleep(2)                                   # bundle bursts (a restart makes several lines)
        while not _q.empty() and len(batch) < 10:
            batch.append(_q.get_nowait())
        try:
            send('\n'.join(batch))
            c = load(); c['last_ok'] = round(time.time()); c.pop('last_error', None); save(c)
        except Exception as ex:
            c = load(); c['last_error'] = f'{util.stamp()}: {ex}'; save(c)


def start_alerts():
    util.LISTENERS.append(on_event)
    threading.Thread(target=_sender, daemon=True).start()


# ---------------- slash commands ----------------
def _reply(text, private=False):
    return {'type': 4, 'data': {'content': text[:1900], 'flags': 64 if private else 0, 'allowed_mentions': {'parse': []}}}


def _span(s):
    s = int(s or 0); d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
    return (f'{d}d ' if d else '') + (f'{h}h ' if h else '') + f'{m}m'


def _is_admin(i):
    try: return bool(int((i.get('member') or {}).get('permissions') or 0) & ADMIN_BITS)
    except ValueError: return False


def handle(i):
    s = SVC
    t = i.get('type')
    if t == 1: return {'type': 1}
    data = i.get('data') or {}
    name = data.get('name')
    opts = {o['name']: o.get('value') for o in data.get('options') or []}
    if t == 4:                                   # autocomplete for player names
        typed = str(opts.get('player') or '').lower()
        ks = sorted(s.tracker.known.items(), key=lambda kv: -(kv[1].get('last') or 0))
        ch = [{'name': (v.get('name') or k)[:100], 'value': k} for k, v in ks if typed in (v.get('name') or k).lower()][:25]
        return {'type': 8, 'data': {'choices': ch}}
    if t != 2: return _reply('Unknown request.', True)
    st = s.status
    if name == 'status':
        if st.get('state') == 'off': return _reply(f"**{st.get('serverName') or 'The server'}** is off." + (' (stopped on purpose)' if st.get('hold') else ''))
        lines = [f"**{st.get('serverName') or 'Palworld server'}**: {st.get('state')} for {_span(st.get('uptime'))}",
                 f"Players: {st.get('players')}/{st.get('maxPlayers') or '?'} · FPS: {round(st['fps']) if st.get('fps') is not None else '?'}"
                 + (f" · memory {st['mem']} of {st['memLimit']} GB" if st.get('mem') is not None else '')]
        nr = st.get('nextRestart') or {}
        nxt = min([x for x in (nr.get('task'), nr.get('scheduled')) if x] or [0])
        if nxt: lines.append(f'Next restart: <t:{nxt}:t> (<t:{nxt}:R>)')
        if st.get('job'): lines.append('Right now: ' + st['job'].get('text', ''))
        return _reply('\n'.join(lines))
    if name == 'players':
        on = list(s.tracker.online.values())
        if not on: return _reply('Nobody is online right now.')
        return _reply(f'**Online now ({len(on)}):**\n' + '\n'.join(
            f"• {p.get('name')} (Lv {p.get('level')}) · on for {_span(time.time() - p.get('since', time.time()))}" for p in on))
    if name == 'playtime':
        ks = sorted(s.tracker.known.values(), key=lambda v: -(v.get('play') or 0))[:10]
        if not ks: return _reply('No playtime recorded yet.')
        return _reply('**Most played:**\n' + '\n'.join(f"{n + 1}. {v.get('name')}: {_span(v.get('play'))}" for n, v in enumerate(ks)))
    if name == 'planner':
        from . import planner
        ts = planner.tailscale_info()
        if not (ts.get('funnel') and ts.get('dns')): return _reply('The Pal Planner link is off right now.', True)
        return _reply(f"Your Pal Planner: https://{ts['dns']}/ (use your own code)", True)
    # admin from here on
    if not _is_admin(i): return _reply('Only server admins can do that.', True)
    who = ((i.get('member') or {}).get('user') or {}).get('username', 'someone')
    try:
        if name == 'restart':
            s.act_restart(float(opts.get('warning') or 0), f'restarted from Discord by {who}')
            return _reply(f"Restarting{' after a ' + str(opts.get('warning')) + '-minute warning' if opts.get('warning') else ' now'} (asked by {who}).")
        if name == 'stop':
            s.act_stop(float(opts.get('warning') or 0), by=f'from Discord by {who}'); return _reply(f'Stopping the server (asked by {who}). It stays off until someone starts it.')
        if name == 'start':
            s.act_start(by=f'from Discord by {who}'); return _reply(f'Starting the server (asked by {who}). It takes a few minutes.')
        if name == 'backup':
            s.act_backup(f'from Discord by {who}'); return _reply('Backing up the world.', True)
        if name == 'announce':
            s.api().announce(str(opts.get('message') or '')); util.event('announce', f"Sent from Discord by {who}: {opts.get('message')}", 'info')
            return _reply('Sent to everyone in the game.', True)
        if name in ('kick', 'ban', 'unban'):
            uid = str(opts.get('player') or '')
            if uid not in s.tracker.known:
                m = [k for k, v in s.tracker.known.items() if (v.get('name') or '').lower() == uid.lower()]
                if not m: return _reply('I don’t know that player. Pick them from the list.', True)
                uid = m[0]
            nm = (s.tracker.known.get(uid) or {}).get('name') or uid
            getattr(s.api(), name)(uid)
            done = {'kick': 'Kicked', 'ban': 'Banned', 'unban': 'Unbanned'}[name]
            util.event(name, f'{done} {nm} from Discord ({who}).', 'good' if name == 'unban' else 'warn', player=uid)
            return _reply(f'{done} {nm}.', True)
    except Exception as e:
        return _reply('That didn’t work: ' + str(e), True)
    return _reply('Unknown command.', True)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        self._send(404, {'error': 'not here'})

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n > 100_000: return self._send(413, {'error': 'too big'})
        body = self.rfile.read(n)
        c = load()
        sig, ts = self.headers.get('X-Signature-Ed25519', ''), self.headers.get('X-Signature-Timestamp', '')
        try:
            ok = bool(c.get('public_key')) and ed25519.verify(bytes.fromhex(c['public_key']), ts.encode() + body, bytes.fromhex(sig))
        except ValueError:
            ok = False
        if not ok: return self._send(401, {'error': 'invalid request signature'})
        try:
            i = json.loads(body)
            return self._send(200, handle(i))
        except Exception as e:
            util.log_error('Discord command', e)
            return self._send(200, _reply('Something went wrong on the server PC.', True))


class _Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    # HTTPServer would also set SO_REUSEADDR, and Windows refuses that next to SO_EXCLUSIVEADDRUSE (WinError 10022)
    allow_reuse_address = False
    allow_reuse_port = False

    def server_bind(self):
        import socket
        if util.IS_WIN and hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        elif not util.IS_WIN:
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        super().server_bind()


def start_listener():
    """Listens for slash commands on 127.0.0.1:18771. Keeps trying for a few minutes, because right after the Command
    Center restarts itself the old copy may still be letting go of the port."""
    def run():
        last = None
        for _ in range(90):
            try:
                srv = _Server(('127.0.0.1', PORT), Handler)
            except OSError as e:
                last = e; time.sleep(2); continue
            srv.serve_forever()
            return
        util.log_error('Discord commands listener', last)
    threading.Thread(target=run, daemon=True).start()
