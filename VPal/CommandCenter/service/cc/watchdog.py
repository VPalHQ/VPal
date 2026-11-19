"""The heart of the Command Center: every 15 seconds it checks the server and steps in when needed.

  crash   the server process vanished and Windows or the game logged a crash -> start it again (ports checked first)
  freeze  the process is there but its REST API stopped answering for a few minutes -> save if it can, close it, start again
  memory  the server's memory passed the limit (or the PC is nearly out) -> warn players, save, restart
  update  Steam has a newer server build -> warn players, restart (the start script installs the update)
  schedule optional daily restart times (off by default)

It never fights you: while a hold is on (you stopped the server from the control panel or the Command Center), while
the scheduled restart script or SteamCMD is running, or while one of its own jobs runs, it only watches.
"""
import os, time, threading, traceback
from . import util, config, procs, players, backups, updates, messages, planner, discord, release
from .palapi import Api, ApiError

HOLD = util.data('hold.json')       # written by the control panel's Stop button and by our own jobs
STATE = util.data('state.json')


def fmt_left(s):
    s = int(round(s))
    if s >= 60:
        m = round(s / 60)
        return f'{m} minute' + ('' if m == 1 else 's')
    return f'{s} seconds'


class Cancelled(Exception):
    pass


class Service:
    def __init__(self):
        self.cfg = config.load()
        self.sd = config.server_dir(self.cfg)
        self.tracker = players.Tracker()
        self.welcomer = messages.Welcomer()
        st = util.read_json(STATE, {}) or {}
        self.last_backup = st.get('last_backup', 0)
        self.last_update_check = st.get('last_update_check', 0)
        self.update_info = st.get('update', {})
        self.last_mem_restart = st.get('last_mem_restart', 0)
        self.last_schedule = st.get('last_schedule', '')
        self.proc_seen = None          # (pid, create_time) of the server last tick
        self.proc_gone_at = None
        self.rest_fail_since = None
        self.rest_ok_at = None
        self.mem_high_since = None
        self.info = {}
        self.metrics = {}
        self.mem_hist = []             # (t, GB) for the last 3 hours, for the leak forecast
        self.job = None                # a job that stops or starts the server: {'kind','text','started','left','cancel':Event}
        self.job_lock = threading.Lock()
        self.bg = {}                   # background work that never touches the running server: {'backup': text, 'updatecheck': text}
        self.ext_restart = None
        self.ext_checked = 0
        self.last_metric = 0
        self.pending_crash = False
        self.crash_times = []
        self.crash_gave_up = False
        self.status = {}
        self.wake = threading.Event()

    # ---------------- small pieces ----------------
    def api(self):
        return Api(self.sd)

    def save_state(self):
        util.write_json(STATE, {'last_backup': self.last_backup, 'last_update_check': self.last_update_check, 'update': self.update_info,
                                'last_mem_restart': self.last_mem_restart, 'last_schedule': self.last_schedule})

    def hold(self):
        h = util.read_json(HOLD, None)
        if not h: return None
        if h.get('until') and h['until'] < time.time():
            try: os.remove(HOLD)
            except OSError: pass
            return None
        return h

    def set_hold(self, reason, minutes=None):
        self.my_hold = f'cc-{time.time():.3f}'
        util.write_json(HOLD, {'reason': reason, 'since': round(time.time()), 'by': self.my_hold,
                               'until': round(time.time() + minutes * 60) if minutes else None})

    def clear_hold(self, any_hold=False):
        """Removes the hold. Our jobs only remove their own, so a Stop from the control panel during a job still counts."""
        h = util.read_json(HOLD, None)
        if h and not any_hold and h.get('by') != getattr(self, 'my_hold', None): return
        try: os.remove(HOLD)
        except OSError: pass

    def busy(self):
        return self.job is not None

    def run_bg(self, name, text, fn):
        """Backups and update checks run beside the watchdog, so a crash during one is still caught."""
        if name in self.bg: return False
        self.bg[name] = text
        def go():
            try: fn()
            except Exception as e:
                util.event('error', f'{text} failed: {e}', 'warn')
                traceback.print_exc()
            finally:
                self.bg.pop(name, None)
        threading.Thread(target=go, daemon=True).start()
        return True

    # ---------------- jobs (one at a time, in their own thread) ----------------
    def run_job(self, kind, text, fn, *args):
        with self.job_lock:
            if self.job: raise RuntimeError(f"Busy: {self.job['text']}")
            self.job = {'kind': kind, 'text': text, 'started': round(time.time()), 'left': None, 'cancel': threading.Event(), 'step': ''}
        def go():
            try:
                fn(*args)
            except Cancelled:
                util.event(kind, 'Cancelled: ' + text, 'warn')
                try: self.api().announce('The restart was cancelled. Carry on!')
                except Exception: pass
            except Exception as e:
                util.event('error', f'{text} failed: {e}', 'bad')
                traceback.print_exc()
            finally:
                self.job = None
                self.wake.set()
        threading.Thread(target=go, daemon=True).start()
        return True

    def step(self, text):
        if self.job: self.job['step'] = text

    def sleep(self, seconds):
        if self.job and self.job['cancel'].wait(seconds): raise Cancelled()

    def countdown(self, minutes, msg_key):
        """Warns players at 5, 3, 1 minute and 30 seconds (only the marks inside the window). Skipped if nobody is online."""
        total = minutes * 60
        if total <= 0 or not self.tracker.online:
            return
        tpl = self.cfg['messages'].get(msg_key) or self.cfg['messages']['restart']
        marks = [m for m in (900, 600, 300, 180, 60, 30) if m < total] + [total]
        marks = sorted(set(marks), reverse=True)
        end = time.time() + total
        for m in marks:
            wait = end - m - time.time()
            if wait > 0: self.sleep(wait)
            if self.job: self.job['left'] = m
            try: self.api().announce(tpl.replace('{left}', fmt_left(m)))
            except ApiError: pass
            if not self.tracker.online and m > 30: break       # everyone left: no need to keep waiting
        self.sleep(max(0, min(30, end - time.time())))

    def stop_server(self, message, warn_s=10):
        """Save, shut down cleanly, wait for it to close (force it after 3 minutes)."""
        api = self.api()
        self.step('Saving the world')
        try: api.save()
        except ApiError: pass
        self.sleep(3)
        self.step('Shutting down')
        try: api.shutdown(warn_s, message)
        except ApiError: pass
        end = time.time() + 180
        while procs.server_procs(self.cfg):
            if time.time() > end:
                util.event('stop', 'The server did not close in 3 minutes, so it was closed by force.', 'warn')
                procs.kill_server(self.cfg)
                break
            self.sleep(2)
        self.tracker.server_gone()

    def start_server(self, why):
        """Waits for the old server's ports to free up, then starts it with the start script."""
        self.step('Waiting for the old server to let go of its ports')
        ok, other = procs.wait_ports_free(self.cfg, config.ports(self.sd), timeout=120,
                                          min_wait=self.cfg['watchdog'].get('port_min_wait_seconds', 15))
        if other:
            util.event('error', 'Another program is using a server port: ' + ', '.join(other) + '. The server may not start properly.', 'bad')
        elif not ok:
            util.event('error', 'The old server held its ports for over 2 minutes. Starting anyway.', 'warn')
        if procs.server_procs(self.cfg):
            util.event('start', 'Something else already started the server.', 'info')
            return
        self.step('Starting the server')
        procs.start_server(self.cfg, self.sd)
        util.event('start', f'Started the server ({why}). It checks for game updates first, then loads the world.', 'good')
        self.rest_fail_since = None
        self.proc_gone_at = None

    def wait_online(self, minutes=12):
        """Waits for the REST API to answer. If the server closes while starting, hands it to the crash rule."""
        self.step('Waiting for the server to come back')
        end = time.time() + minutes * 60
        seen = False
        while time.time() < end:
            try:
                self.api().server_info()
                util.event('start', 'The server is back online.', 'good')
                return True
            except ApiError:
                pass
            if procs.server_procs(self.cfg):
                seen = True
            elif seen and not procs.maintenance_running(self.cfg):
                util.event('crash', 'The server closed while it was starting.', 'bad')
                self.pending_crash = True
                return False
            self.sleep(2)
        util.event('error', f'The server did not answer within {minutes} minutes of starting.', 'bad')
        return False

    def crash_allowed(self):
        """Stops a crash loop: at most 3 automatic starts after crashes in 30 minutes."""
        t = time.time()
        self.crash_times = [x for x in self.crash_times if t - x < 1800]
        if len(self.crash_times) >= 3:
            if not self.crash_gave_up:
                self.crash_gave_up = True
                util.event('crash', 'The server crashed 3 times in 30 minutes, so the watchdog stopped restarting it. Check the server window '
                                    'or recent changes (mods, settings), then start it from the control panel.', 'bad')
            return False
        self.crash_times.append(t)
        self.crash_gave_up = False
        return True

    def restart_job(self, kind, why, warn_minutes, msg_key, backup=True):
        self.set_hold(kind, minutes=30)
        try:
            self.countdown(warn_minutes, msg_key)
            if backup and self.cfg['backups'].get('before_restart'):
                self.step('Backing up the world')
                try:
                    try: self.api().save()
                    except ApiError: pass
                    self.sleep(3)
                    backups.snapshot(self.sd, 'before-restart', why)
                except Cancelled:
                    raise
                except Exception as e:
                    util.log_error('Backup before restart', e)
            msg = (self.cfg['messages'].get(msg_key) or self.cfg['messages']['restart']).replace('{left}', '10 seconds')
            self.stop_server(msg)
            self.start_server(why)
            self.wait_online()
        finally:
            self.clear_hold()

    # ---------------- public actions (from the control panel or Discord) ----------------
    def act_restart(self, minutes, reason='restart'):
        return self.run_job('restart', f'Restart ({reason})', self.restart_job, 'restart', reason, minutes, 'restart')

    def act_stop(self, minutes, by='from the control panel'):
        def go():
            self.set_hold('stopped ' + by)
            self.countdown(minutes, 'restart')
            self.stop_server('Server is shutting down. See you soon!')
            util.event('stop', f'Stopped {by}. The watchdog leaves it off until you start it.', 'info')
        return self.run_job('stop', 'Stopping the server', go)

    def act_start(self, by='from the control panel'):
        def go():
            self.clear_hold(any_hold=True)
            if procs.server_procs(self.cfg): return
            self.start_server('started ' + by)
            self.wait_online()
        return self.run_job('start', 'Starting the server', go)

    def act_backup(self, note=''):
        def go():
            if procs.server_procs(self.cfg):
                try: self.api().save()
                except ApiError: pass
                time.sleep(3)
            e = backups.snapshot(self.sd, 'manual', note)
            util.event('backup', f"Backup made ({e['size'] / 2**20:.0f} MB).", 'good')
        if not self.run_bg('backup', 'Backing up the world', go): raise RuntimeError('A backup is already being made.')
        return True

    def act_restore(self, bid, minutes):
        def go():
            entry = next((x for x in backups.list_all(self.sd) if x['id'] == bid), None)
            if not entry: raise RuntimeError('That backup no longer exists.')
            self.set_hold('restoring a backup', minutes=60)
            try:
                running = bool(procs.server_procs(self.cfg))
                if running:
                    self.countdown(minutes, 'restart')
                    self.stop_server('Server restarting to restore a backup. Back in a few minutes!')
                self.step('Making a safety copy of the world as it is now')
                safety = backups.snapshot(self.sd, 'before-restore', 'before restoring ' + entry['when'])
                self.step('Restoring')
                backups.restore_files(self.sd, bid)
                util.event('restore', f"Restored the backup from {entry['when']}. A safety copy of the world before the restore was saved "
                                      f"({safety['when']}).", 'good')
                if running:
                    self.start_server('after a restore')
                    self.wait_online()
            finally:
                self.clear_hold()
        return self.run_job('restore', 'Restoring a backup', go)

    def act_cancel(self):
        if self.job and self.job['kind'] in ('restart', 'stop', 'restore', 'memory', 'update', 'schedule') and self.job['step'] == '':
            self.job['cancel'].set()
            return True
        return False

    def act_check_update(self):
        if not self.run_bg('updatecheck', 'Checking Steam for a Palworld update', lambda: self.update_work(force=True)):
            raise RuntimeError('Already checking.')
        return True

    # ---------------- the 15-second check ----------------
    def tick(self):
        self.cfg = config.load()
        self.sd = config.server_dir(self.cfg)
        wd_cfg = self.cfg['watchdog']
        t = time.time()
        proc = procs.main_proc(self.cfg)
        hold = self.hold()
        maint = procs.maintenance_running(self.cfg)
        standing_down = bool(hold) or maint or self.busy()
        api = self.api()
        rest_ok = False

        # a stop-hold from the control panel ends once the server is running and answering again (started some other way)
        if hold and not hold.get('until') and proc and not self.busy() and self.rest_ok_at and t - self.rest_ok_at < 30:
            try: running_for = t - proc.create_time()
            except Exception: running_for = 0
            if running_for > 300:
                self.clear_hold(any_hold=True); hold = None
                standing_down = maint
                util.event('service', 'The server is running again, so the watchdog is back on.', 'info')
        if proc:
            try:
                key = (proc.pid, proc.create_time())
                mem = procs.mem_bytes(proc) / 2**30
            except Exception:
                key, mem = None, 0
            if self.proc_seen and key and key != self.proc_seen and not standing_down:
                util.event('start', 'The server was started again (outside the watchdog).', 'info')
            self.proc_seen = key
            self.proc_gone_at = None
            age = t - key[1] if key else 0
            try:
                self.info = api.server_info()
                self.metrics = api.metrics()
                pl = api.players()
                rest_ok = True
                self.rest_ok_at = t
                self.rest_fail_since = None
                self.tracker.update(pl, self.cfg, api)
                try: self.welcomer.tick(self.cfg, self.sd, self.tracker, api)
                except Exception as e: util.log_error('Welcome messages', e)
            except ApiError as e:
                if self.rest_fail_since is None: self.rest_fail_since = t
                self.last_rest_error = str(e)
            # freeze: the process is there but has not answered for a while
            if (not rest_ok and wd_cfg['enabled'] and wd_cfg['freeze_restart'] and api.enabled and not standing_down
                    and age > wd_cfg['startup_grace_minutes'] * 60 and self.rest_fail_since
                    and t - self.rest_fail_since >= wd_cfg['freeze_minutes'] * 60):
                self.run_job('freeze', 'Restarting a frozen server', self.freeze_job, round((t - self.rest_fail_since) / 60))
            # memory
            self.mem_hist = [x for x in self.mem_hist if t - x[0] < 3 * 3600] + [(t, mem)]
            self.check_memory(mem, standing_down, rest_ok)
        else:
            if self.proc_seen:
                # it was running last check and now it's gone
                self.proc_seen = None
                self.proc_gone_at = t
                self.tracker.server_gone()
                self.mem_hist = []
                if standing_down:
                    pass
                elif wd_cfg['enabled'] and wd_cfg['crash_restart']:
                    time.sleep(5)
                    why = procs.crash_evidence(self.sd, t - 60)
                    if why or wd_cfg.get('restart_any_stop'):
                        util.event('crash', 'The server stopped unexpectedly' + (f" ({', '.join(why[:2])})" if why else '') + '.', 'bad')
                        if self.crash_allowed():
                            self.run_job('crash', 'Starting the server after a crash', self.crash_job)
                    else:
                        util.event('stop', 'The server was closed (no sign of a crash), so the watchdog left it off.', 'info')
                else:
                    util.event('stop', 'The server stopped.', 'warn')
            self.info, self.metrics = {}, {}
            self.rest_fail_since = None
            # the server died while one of our jobs was starting it
            if (self.pending_crash and not standing_down and wd_cfg['enabled'] and wd_cfg['crash_restart']
                    and not procs.server_procs(self.cfg)):
                self.pending_crash = False
                if self.crash_allowed():
                    self.run_job('crash', 'Starting the server after a crash', self.crash_job)

        # every minute: history for the charts
        if t - self.last_metric >= 60:
            self.last_metric = t
            tot, avail = procs.system_memory()
            util.add_metric({'t': round(t), 'up': 1 if proc else 0, 'ok': 1 if rest_ok else 0, 'fps': self.metrics.get('serverfps'),
                             'pl': len(self.tracker.online) if proc else 0, 'mem': round(self.mem_hist[-1][1], 2) if (proc and self.mem_hist) else None,
                             'free': round(avail, 2)})

        if not standing_down:
            self.check_schedule(t, bool(proc))
            self.check_backup(t, bool(proc), rest_ok)
            if bool(proc) and rest_ok: self.check_update()
        if t - getattr(self, 'ver_checked', 0) > 60:
            self.ver_checked = t
            self.check_self_update()
            if release.due(): self.run_bg('vpalcheck', 'Checking for a VPal update', release.check)
        if t - getattr(self, 'web_checked', 0) > 60:
            self.web_checked = t
            self.run_bg('plannerweb', "Checking the Pal Planner's website", lambda: planner.keep_web(self.sd))
        if t - getattr(self, 'paths_checked', 0) > int(os.environ.get('CC_PATHS_SECONDS') or 300):
            self.paths_checked = t
            want = []
            dc_on = bool(discord.load().get('commands_on'))
            if dc_on: want.append(('/discord', discord.PORT))
            first = not getattr(self, 'admin_dropped', False)
            self.admin_dropped = True
            def link_work():
                if first: planner.drop_old_admin_page()
                fixed = planner.keep_paths(want)
                if dc_on and (fixed or t - getattr(self, 'ep_checked', 0) > 1800):
                    self.ep_checked = t
                    discord.keep_endpoint()
            if want or first: self.run_bg('linkpaths', 'Checking the family link', link_work)
        if t - self.ext_checked > 900:
            self.ext_checked = t
            self.ext_restart = procs.next_external_restart(self.cfg)
        self.build_status(proc, rest_ok, hold, maint)

    # ---------------- what each watchdog rule does ----------------
    def crash_job(self):
        self.set_hold('restarting after a crash', minutes=20)
        try:
            self.start_server('after a crash')
            self.wait_online()
        finally:
            self.clear_hold()

    def freeze_job(self, minutes):
        self.set_hold('restarting a frozen server', minutes=20)
        try:
            util.event('freeze', f"The server stopped answering about {max(1, minutes)} minute{'s' if max(1, minutes) > 1 else ''} ago. "
                                 'Closing it and starting it again.', 'bad')
            try: self.api().save()
            except ApiError: pass
            procs.kill_server(self.cfg)
            self.tracker.server_gone()
            self.start_server('after a freeze')
            self.wait_online()
        finally:
            self.clear_hold()

    def restart_soon(self):
        """Seconds until a planned restart (ours or the Windows task), or None."""
        cands = []
        if self.ext_restart and self.ext_restart > time.time(): cands.append(self.ext_restart - time.time())
        ns = self.next_schedule()
        if ns: cands.append(ns - time.time())
        return min(cands) if cands else None

    def check_memory(self, mem, standing_down, rest_ok):
        mc = self.cfg['memory']
        if not mc['enabled'] or standing_down: self.mem_high_since = None; return
        tot, avail = procs.system_memory()
        limit = config.memory_limit_gb(self.cfg, tot)
        critical = avail < max(0.5, mc['min_free_gb'] * 0.6)
        high = mem >= limit or avail < mc['min_free_gb']
        if not high: self.mem_high_since = None; return
        t = time.time()
        if self.mem_high_since is None: self.mem_high_since = t
        if t - self.mem_high_since < mc.get('sustain_minutes', 2) * 60 and not critical: return     # must stay high a while (not a spike)
        soon = self.restart_soon()
        if not critical and soon is not None and soon < mc['skip_if_restart_within_minutes'] * 60: return
        if not critical and t - self.last_mem_restart < mc['cooldown_minutes'] * 60: return
        self.last_mem_restart = t
        self.save_state()
        warn = 1 if critical else mc['warn_minutes']
        util.event('memory', f'Server memory is {mem:.1f} GB (limit {limit:g} GB, {avail:.1f} GB free on the PC). Restarting with a '
                             f'{warn:g}-minute warning (sooner if nobody is online).', 'bad' if critical else 'warn')
        self.run_job('memory', 'Memory restart', self.restart_job, 'memory', 'memory was high', warn, 'memory')

    def next_schedule(self):
        sc = self.cfg['schedule']
        if not sc['enabled'] or not sc['times']: return None
        now = time.localtime()
        best = None
        for hm in sc['times']:
            try: h, m = [int(x) for x in hm.split(':')]
            except ValueError: continue
            for add in (0, 1):
                t = time.mktime((now.tm_year, now.tm_mon, now.tm_mday + add, h, m, 0, 0, 0, -1))
                if t > time.time() and (best is None or t < best): best = t
        return best

    def check_schedule(self, t, running):
        ns = self.next_schedule()
        if not ns or not running or self.busy(): return
        warn = self.cfg['schedule']['warn_minutes'] * 60
        key = time.strftime('%Y-%m-%d %H:%M', time.localtime(ns))
        if ns - t <= warn + 20 and self.last_schedule != key:
            self.last_schedule = key
            self.save_state()
            util.event('schedule', f'Scheduled restart ({time.strftime("%I:%M %p", time.localtime(ns)).lstrip("0")}).', 'info')
            self.run_job('schedule', 'Scheduled restart', self.restart_job, 'schedule', 'scheduled restart', max(0, (ns - t) / 60), 'restart')

    def check_backup(self, t, running, rest_ok):
        bc = self.cfg['backups']
        if not bc['enabled'] or not running or not rest_ok: return
        if t - self.last_backup < bc['every_hours'] * 3600: return
        self.last_backup = t
        self.save_state()
        def go():
            try: self.api().save()
            except ApiError: pass
            time.sleep(3)
            e = backups.snapshot(self.sd, 'auto')
            util.event('backup', f"Backup made ({e['size'] / 2**20:.0f} MB).", 'info')
        self.run_bg('backup', 'Backing up the world', go)

    def check_update(self):
        uc = self.cfg['updates']
        if not uc['enabled']: return
        t = time.time()
        if t - self.last_update_check < uc['check_minutes'] * 60: return
        soon = self.restart_soon()
        if soon is not None and soon < 900: return          # the restart's own SteamCMD run is about to update it anyway
        self.last_update_check = t
        self.save_state()
        self.run_bg('updatecheck', 'Checking Steam for a Palworld update', self.update_work)

    def update_work(self, force=False):
        uc = self.cfg['updates']
        have = updates.installed_build(self.sd)
        try:
            latest = updates.latest_build(self.cfg, self.sd)
        except Exception as e:
            self.update_info = dict(self.update_info, error=str(e), checked=round(time.time()), installed=have)
            self.save_state()
            if force: util.event('update', f'Could not check for updates: {e}', 'warn')
            return
        self.update_info = {'installed': have, 'latest': latest, 'checked': round(time.time()), 'error': ''}
        self.save_state()
        if have and latest > have:
            util.event('update', f'A Palworld server update is out (build {latest}, you have {have}).', 'warn')
            if uc['auto_restart'] and procs.server_procs(self.cfg):
                soon = self.restart_soon()
                if soon is not None and soon < uc['warn_minutes'] * 60 + 300:
                    util.event('update', 'The planned restart is coming up soon and will install it.', 'info')
                else:
                    try:
                        self.run_job('update', 'Restarting to install a Palworld update', self.restart_job, 'update', 'update', uc['warn_minutes'], 'update')
                    except RuntimeError:
                        self.last_update_check = time.time() - uc['check_minutes'] * 60 + 300      # busy now: look again in 5 minutes
        elif force:
            util.event('update', f'The server is up to date (build {have}).', 'good')

    # ---------------- what the control panel shows ----------------
    def forecast(self):
        """Hours until the memory limit at the current rate (None if flat or falling)."""
        h = self.mem_hist
        if len(h) < 20 or h[-1][0] - h[0][0] < 1800: return None
        n = len(h); mt = sum(x[0] for x in h) / n; mm = sum(x[1] for x in h) / n
        den = sum((x[0] - mt) ** 2 for x in h)
        if not den: return None
        slope = sum((x[0] - mt) * (x[1] - mm) for x in h) / den * 3600       # GB per hour
        tot, _ = procs.system_memory()
        lim = config.memory_limit_gb(self.cfg, tot)
        if slope <= 0.02: return {'rate': round(slope, 2), 'hours': None}
        return {'rate': round(slope, 2), 'hours': round(max(0, (lim - h[-1][1]) / slope), 1)}

    def newest_backup(self):
        t = time.time()
        if t - getattr(self, '_nb_at', 0) > 60:
            try: self._nb = backups.newest(self.sd)
            except OSError: self._nb = None
            self._nb_at = t
        return round(self._nb) if self._nb else None

    def build_status(self, proc, rest_ok, hold, maint):
        tot, avail = procs.system_memory()
        up = None
        try: up = round(time.time() - proc.create_time()) if proc else None
        except Exception: pass
        state = 'off'
        if proc: state = 'running' if rest_ok else ('starting' if up is not None and up < self.cfg['watchdog']['startup_grace_minutes'] * 60 else 'not answering')
        job = None
        if self.job: job = {k: v for k, v in self.job.items() if k != 'cancel'}
        ns = self.next_schedule()
        self.status = {
            'version': util.VERSION, 'state': state, 'uptime': up, 'serverName': self.info.get('servername') or config.read_ini(self.sd).get('ServerName', '').strip('"'),
            'gameVersion': self.info.get('version', ''), 'fps': self.metrics.get('serverfps'), 'frameTime': self.metrics.get('serverframetime'),
            'players': len(self.tracker.online), 'maxPlayers': self.metrics.get('maxplayernum'), 'days': self.metrics.get('days'),
            'mem': round(self.mem_hist[-1][1], 2) if (proc and self.mem_hist) else None, 'memLimit': config.memory_limit_gb(self.cfg, tot),
            'pcTotal': round(tot, 1), 'pcFree': round(avail, 1), 'forecast': self.forecast() if proc else None,
            'restApi': bool(config.api_info(self.sd)), 'hold': hold, 'maintenance': maint, 'job': job,
            'nextRestart': {'scheduled': round(ns) if ns else None, 'task': round(self.ext_restart) if self.ext_restart else None},
            'update': self.update_info, 'lastBackup': self.newest_backup(), 'background': dict(self.bg),
            'serverDir': self.sd, 'world': os.path.basename(config.world_dir(self.sd) or ''), 'startScript': config.start_script(self.cfg, self.sd),
            'steamcmd': config.steamcmd_path(self.cfg, self.sd), 't': round(time.time()),
        }

    def check_self_update(self):
        """After an update is extracted, start the new watchdog and let this old copy go (when it's not busy)."""
        import re, sys, subprocess
        try:
            m = re.search(r"^VERSION = '([^']*)'", open(os.path.join(os.path.dirname(__file__), 'util.py'), encoding='utf-8').read(), re.M)
        except OSError:
            return
        if not m or m.group(1) == util.VERSION or self.busy() or self.bg: return
        util.event('service', f'Updating the watchdog from {util.VERSION} to {m.group(1)}.', 'info')
        script = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'ccservice.py')
        kw = {'creationflags': procs.NO_WINDOW | 0x00000008 | 0x00000200} if util.IS_WIN else {'start_new_session': True}
        subprocess.Popen([sys.executable, script], cwd=os.path.dirname(script), close_fds=True, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kw)
        self.tracker.save()
        os._exit(0)

    def loop(self):
        util.event('service', f'Watchdog {util.VERSION} started.', 'info')
        every = float(os.environ.get('CC_TICK') or 15)
        last_trim = 0
        while True:
            try:
                self.tick()
            except Exception as e:
                util.log_error('Watchdog check', e)
                traceback.print_exc()
            if time.time() - last_trim > 6 * 3600:
                last_trim = time.time()
                util.trim_file(util.EVENTS, 5000)
                util.trim_file(util.METRICS, 12000)          # about a week of one-a-minute rows
            self.wake.wait(every)
            self.wake.clear()
