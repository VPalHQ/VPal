"""Welcome messages for players who join, and the messages you send to everyone.

The welcome text lives in welcome-message.txt in the server folder (the same file the control panel and the older
PowerShell welcome helper use), so changing it anywhere changes it everywhere. {name} becomes the player's name.

Who sends it:
  auto  the Command Center sends it, unless the older welcome helper (WelcomeMessage.ps1) is running
  cc    the Command Center always sends it, and closes the older helper so nobody gets greeted twice
  off   nobody from here
"""
import os, time
import psutil
from . import util, config

DEFAULT = 'Welcome {name}! Have fun out there.'


def path(sd):
    return os.path.join(sd, 'welcome-message.txt')


def text(sd):
    try:
        with open(path(sd), encoding='utf-8-sig') as f:
            t = ' '.join(f.read().split())
            if t: return t
    except OSError:
        pass
    return DEFAULT


def save_text(sd, t):
    t = ' '.join(str(t or '').split())
    if not t: raise ValueError('The welcome message cannot be blank.')
    if len(t) > 200: raise ValueError('Keep it under 200 characters (the game cuts longer messages).')
    with open(path(sd), 'w', encoding='utf-8') as f: f.write(t)
    return t


def helper_procs():
    out = []
    for p in psutil.process_iter(['pid', 'name', 'cmdline']):
        try:
            if 'welcomemessage.ps1' in ' '.join(p.info['cmdline'] or []).lower(): out.append(p)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return out


class Welcomer:
    def __init__(self):
        self.sent = {}            # player id -> the 'since' of the visit we already greeted
        self.primed = False       # players already online when the Command Center started were greeted before

    def tick(self, cfg, sd, tracker, api):
        wc = cfg['welcome']
        if wc['mode'] == 'off': return
        helpers = helper_procs()
        if helpers:
            if wc['mode'] == 'cc':
                for p in helpers:
                    try: p.kill()
                    except psutil.Error: pass
                util.event('welcome', 'Closed the older welcome helper; the watchdog sends welcome messages now.', 'info')
            else:
                self.primed = True
                for uid, p in tracker.online.items(): self.sent[uid] = p.get('since')
                return                    # the older helper is greeting people
        now = time.time()
        if not self.primed:
            self.primed = True
            for uid, p in tracker.online.items(): self.sent[uid] = p.get('since')
            return
        for uid, p in list(tracker.online.items()):
            since = p.get('since')
            if self.sent.get(uid) == since: continue
            if now - since < wc['delay_seconds']: continue
            msg = text(sd).replace('{name}', p.get('name') or 'friend')
            try:
                api.announce(msg)
                self.sent[uid] = since
                util.event('welcome', f"Welcomed {p.get('name') or uid}.", 'info', player=uid)
            except Exception as e:
                self.sent[uid] = since
                util.log_error('Welcome message', e)
