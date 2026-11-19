"""Palworld Server Watchdog: the background part of the control panel (no window, no web page).

  pythonw ccservice.py          run the service (started at sign-in and re-checked every 5 minutes by a scheduled task;
                                if one is already running this copy exits right away)
  python  ccservice.py status   print the current status (for the control panel and for troubleshooting)

Unofficial fan tool. Not affiliated with Pocketpair.
"""
import os, sys, json, time, threading, socket

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.environ.get('CC_LIB') or os.path.join(HERE, 'lib'))
sys.path.insert(0, HERE)

if sys.stdout is None: sys.stdout = open(os.devnull, 'w')      # pythonw has no console
if sys.stderr is None: sys.stderr = open(os.devnull, 'w')

from cc import util


def already_running():
    s = socket.socket()
    s.settimeout(0.5)
    try:
        return s.connect_ex(('127.0.0.1', util.PORT)) == 0
    finally:
        s.close()


def updating():
    """True while vpal_updater.py is putting a VPal update in place: a watchdog started then (at sign-in, by the
    5-minute task or by the control panel) would load half-new files, so it leaves it to the updater."""
    try:
        return time.time() - os.path.getmtime(os.path.join(os.path.dirname(HERE), 'data', 'updates', 'updating.lock')) < 600
    except OSError:
        return False


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'status':
        import urllib.request
        try:
            with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{util.PORT}/api/status'), timeout=5) as r:
                print(r.read().decode())
            return 0
        except Exception as e:
            print(json.dumps({'error': f'The Command Center is not running ({e.__class__.__name__}).'}))
            return 1
    if already_running() or updating(): return 0
    from cc import web, watchdog, release
    srv = None
    for i in range(30):                           # the port can stay busy for a moment after an old copy closed
        try:
            srv = web.make_server(); break
        except OSError:
            if already_running(): return 0        # another copy won the race
            time.sleep(2)
    if srv is None: return 1
    release.note_result()                         # how the last VPal update went, if there was one
    svc = watchdog.Service()
    web.SVC = svc
    from cc import discord
    discord.SVC = svc
    discord.start_alerts()
    discord.start_listener()
    try:
        svc.tick()                                # fill the status before the control panel asks
    except Exception as e:
        util.log_error('First check', e)
    threading.Thread(target=svc.loop, daemon=True).start()
    srv.serve_forever()


if __name__ == '__main__':
    sys.exit(main())
