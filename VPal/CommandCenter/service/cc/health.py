"""The health check: one page that says what's fine, what's worth watching and what needs attention."""
import os, glob, time, shutil, socket
from . import util, config, procs, backups, settings, planner, release
from .palapi import ApiError

OK, FAIR, BAD, INFO = 'ok', 'fair', 'bad', 'info'


def _span(s):
    s = int(s); d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
    return (f'{d}d ' if d else '') + (f'{h}h ' if h else '') + f'{m}m'


def run(svc):
    sd, cfg, st = svc.sd, svc.cfg, svc.status
    out = []
    def sec(title): out.append({'title': title, 'items': []})
    def add(level, text): out[-1]['items'].append({'level': level, 'text': text})

    # ---- server program ----
    sec('Server program')
    ps = procs.server_procs(cfg)
    main = procs.main_proc(cfg)
    if not ps:
        if procs.maintenance_running(cfg): add(FAIR, 'The server is starting or updating. Check again in a few minutes.')
        elif st.get('hold'): add(INFO, 'The server is off on purpose (' + str(st['hold'].get('reason', '')) + ').')
        else: add(BAD, 'The server is off. Start it from the Dashboard.')
    else:
        big = [p for p in ps if procs.mem_bytes(p) > 500 * 2**20]
        if len(big) > 1: add(BAD, f'{len(big)} copies of the server are running at once. Close the extra server window so only one runs.')
        else:
            up = time.time() - main.create_time()
            add(OK, f"Running for {_span(up)}, using {procs.mem_bytes(main) / 2**30:.1f} GB of memory (restart point {st.get('memLimit')} GB).")
            f = st.get('forecast') or {}
            if f.get('hours') is not None: add(INFO, f"Memory is growing about {f['rate']} GB an hour, so the restart point is roughly {f['hours']} hours away.")
            nr = st.get('nextRestart') or {}
            if (nr.get('task') or nr.get('scheduled')) and up > 13 * 3600:
                add(FAIR, f'Running {int(up // 3600)} hours without a restart, so a planned restart may have been missed.')

    # ---- performance and players ----
    if ps:
        sec('Performance and players')
        if not st.get('restApi'): add(BAD, 'The REST API is off, so performance and player checks are not available.')
        elif st.get('fps') is None: add(FAIR, 'The server did not answer. If it just started, wait a minute and check again.')
        else:
            fps = round(st['fps'])
            add(OK if fps >= 50 else FAIR if fps >= 30 else BAD,
                f'{fps} FPS' + (' (smooth; full speed is about 60).' if fps >= 50 else ', a little strained.' if fps >= 30 else
                                 ', struggling. Lower wild Pal spawns or Pals per base.'))
            on = list(svc.tracker.online.values())
            if not on: add(INFO, 'Nobody is online right now.')
            for p in on:
                ms = int(round(float(p.get('ping') or 0)))
                add(OK if ms <= 100 else FAIR if ms <= 250 else BAD, f"{p.get('name')} (Lv {p.get('level')}) ping {ms} ms" +
                    (' - good connection' if ms <= 100 else ' - a bit laggy' if ms <= 250 else ' - very laggy'))
        # settings in the file that the running server hasn't loaded yet
        try:
            live = svc.api()._call('GET', '/settings')
            pending = []
            for s in settings.read_all(sd)['settings']:
                if s.get('locked') or s['type'] not in ('Float', 'Int', 'Bool') or s['key'] not in live: continue
                lv = live[s['key']]
                same = (str(lv).lower() == str(s['value']).lower()) if s['type'] == 'Bool' else abs(float(lv) - float(s['value'])) < 1e-4
                if not same: pending.append(s['label'])
            if pending: add(FAIR, f"{len(pending)} saved setting{'s' if len(pending) != 1 else ''} not in use until the next restart: " + ', '.join(pending[:8]))
            else: add(OK, 'The server is using every saved setting.')
        except Exception:
            pass

    # ---- watchdog ----
    sec('Watchdog')
    if st.get('hold'): add(FAIR, 'The watchdog is paused: ' + str(st['hold'].get('reason', '')) + '.')
    elif not cfg['watchdog']['enabled']: add(FAIR, 'The watchdog is turned off on the Watchdog tab.')
    else: add(OK, f"Watching the server every 15 seconds (version {util.VERSION}).")
    day = [e for e in util.recent_events(400) if time.time() - e['t'] < 86400]
    crashes = sum(1 for e in day if e['kind'] in ('crash', 'freeze'))
    if crashes: add(FAIR if crashes < 3 else BAD, f"{crashes} crash or freeze recover{'ies' if crashes != 1 else 'y'} in the last 24 hours. See Activity.")
    up = st.get('update') or {}
    if up.get('latest') and up.get('installed') and up['latest'] > up['installed']: add(FAIR, 'A Palworld server update is out and not installed yet.')
    elif up.get('error'): add(FAIR, 'Could not check for game updates: ' + up['error'])
    vu = release.public()
    if vu['available']: add(FAIR, f"VPal {vu['version']} is out (you have {vu['current']}). Click Update VPal at the top of the control panel.")
    elif vu['feed'] and vu['error']: add(INFO, vu['error'])
    elif up.get('installed'): add(OK, f"Game build {up['installed']} (up to date when last checked).")

    # ---- backups and disk ----
    sec('Backups and disk')
    wd = config.world_dir(sd)
    gb = sorted(glob.glob(os.path.join(wd, 'backup', 'world', '*')), key=os.path.getmtime, reverse=True) if wd else []
    if gb:
        age = time.time() - os.path.getmtime(gb[0])
        msg = f"Newest game backup: {_span(age)} ago."
        if not ps or age <= 900: add(OK, msg)
        elif not svc.tracker.online: add(INFO, msg + ' Normal while nobody is online; the server saves while people play.')
        else: add(BAD, msg + ' Backups should be minutes old while people are playing.')
    else:
        v = config.read_ini(sd).get('bIsUseBackupSaveData', '')
        add(BAD if v.lower() != 'true' else FAIR, 'No game backups found.' + (' Turn on World backups in Settings > Performance.' if v.lower() != 'true' else ''))
    nb = backups.newest(sd)
    if cfg['backups']['enabled']: add(OK if nb and time.time() - nb < cfg['backups']['every_hours'] * 3600 * 2 else FAIR,
                                      'Watchdog backups: ' + (f'newest {_span(time.time() - nb)} ago.' if nb else 'none yet.'))
    try:
        free = shutil.disk_usage(sd).free / 2**30
        add(OK if free >= 30 else FAIR if free >= 10 else BAD, f'The server drive has {free:.0f} GB free.' +
            ('' if free >= 10 else ' The server can damage saves when the disk fills up.'))
    except OSError:
        pass

    # ---- Pal Planner ----
    if planner.installed(sd):
        sec('Pal Planner')
        ps_ = planner.read_status(sd) or {}
        if not ps_: add(FAIR, 'Not built yet. Click Refresh now on the Pal Planner tab.')
        elif not ps_.get('ok'): add(BAD, 'Last update failed: ' + str(ps_.get('message', '')))
        else: add(OK, f"Updated {ps_.get('when')} from the {ps_.get('saved')} save.")
        add(OK if planner.web_running() else BAD, 'Its web server is ' + ('running.' if planner.web_running() else 'not running, so the family link shows an error.'))
        ts = planner.tailscale_info()
        if ts.get('funnel') and ts.get('dns'): add(OK, f"Family link is on: https://{ts['dns']}/")
        elif ts.get('installed'): add(FAIR, 'The family link is off.')

    # ---- connection ----
    from . import discord
    dc = discord.load()
    if dc.get('token'):
        sec('Discord')
        if not dc.get('channel_id'): add(FAIR, 'The bot is connected but no channel is picked yet. Finish step 2 on the Discord tab.')
        elif not dc.get('enabled'): add(INFO, f"Alerts are off (#{dc.get('channel_name')}).")
        elif dc.get('last_error'): add(BAD, 'The last alert did not reach Discord: ' + str(dc['last_error']))
        else: add(OK, f"Alerts go to #{dc.get('channel_name')} on {dc.get('guild_name')}.")
        if dc.get('commands_on'):
            ts = planner.tailscale_info()
            if any((x.get('path') or '').rstrip('/') == '/discord' for x in ts.get('paths') or []): add(OK, 'Slash commands are on.')
            else: add(FAIR, 'Slash commands are on, but the family link is not passing them through right now. It fixes itself within '
                            '5 minutes of the family link being on.')
    sec('Internet connection')
    for host, port, name in (('1.1.1.1', 443, 'the internet'), ('api.steampowered.com', 443, 'Steam')) + ((('discord.com', 443, 'Discord'),) if dc.get('token') else ()):
        t0 = time.time()
        try:
            socket.create_connection((host, port), timeout=4).close()
            ms = round((time.time() - t0) * 1000)
            add(OK if ms < 150 else FAIR, f'Reached {name} in {ms} ms.')
        except OSError:
            add(BAD, f'Could not reach {name}.')

    issues = [i['text'] for s in out for i in s['items'] if i['level'] == BAD]
    watch = [i['text'] for s in out for i in s['items'] if i['level'] == FAIR]
    return {'when': util.stamp(), 'sections': out, 'issues': issues, 'watch': watch}
