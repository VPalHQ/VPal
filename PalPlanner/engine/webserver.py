"""Serves PalPlanner\\web to this PC only (127.0.0.1). Tailscale Funnel passes the family's https
requests to it, so nothing is opened on the router and no administrator rights are needed.

  pythonw webserver.py [port]      (started by the Palworld control panel and at Windows sign-in)
"""
import sys, os, json, time, hmac, functools, http.server, urllib.request

VERSION = '3'                              # the Command Center restarts this server when the file's version changes
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18765
FAILS = {}
WEB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'web')


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        '': 'application/octet-stream',
        '.html': 'text/html; charset=utf-8',
        '.json': 'application/json',
        '.webp': 'image/webp',
        '.png': 'image/png',
        '.webmanifest': 'application/manifest+json',
        '.js': 'text/javascript',
        '.css': 'text/css',
        '.txt': 'text/plain; charset=utf-8',
    }

    def do_GET(self):
        if self.path.split('?')[0] == '/live':
            return self.from_watchdog('live', {'players': [], 'cc': False})
        if self.path.split('?')[0] == '/voice':
            return self.from_watchdog('voice', {'configured': False, 'cc': False})
        if self.path == '/__version' and self.client_address[0] == '127.0.0.1' and not self.headers.get('X-Forwarded-For'):
            return self._json(200, {'version': VERSION})
        return super().do_GET()

    def from_watchdog(self, what, fallback):
        """live: where everyone online is right now, for the planner's map. voice: the Voice tab (the Discord voice
        channel and who is in it). Both need a valid planner code, and come from the watchdog on this PC
        (http://127.0.0.1:18770), which reads them from the game server and from Discord."""
        code = (self.headers.get('X-Planner-Code') or '').strip().lower()
        ip = (self.headers.get('X-Forwarded-For') or self.client_address[0]).split(',')[0].strip()
        t = time.time()
        FAILS[ip] = [x for x in FAILS.get(ip, []) if t - x < 900]
        ok = False
        if code and len(FAILS[ip]) < 10:
            try:
                players = json.load(open(os.path.join(os.path.dirname(WEB), 'players.json'), encoding='utf-8')).get('players') or []
                ok = any(hmac.compare_digest(code, str(p.get('code') or '').lower()) for p in players if p)
            except (OSError, ValueError):
                ok = False
        if not ok:
            FAILS[ip].append(t)
            return self._json(403, {'error': 'code'})
        try:
            with urllib.request.urlopen('http://127.0.0.1:18770/api/' + what, timeout=12) as r:
                data = json.loads(r.read().decode('utf-8'))
        except Exception:
            data = fallback
        return self._json(200, data)

    def _json(self, code, obj):
        b = json.dumps(obj).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(b)

    def list_directory(self, path):          # never show folder listings
        self.send_error(404)
        return None

    def end_headers(self):
        p = self.path.split('?')[0]
        if p.endswith(('.json', '.html', '/', '.webmanifest')):
            self.send_header('Cache-Control', 'no-cache')
        self.send_header('X-Content-Type-Options', 'nosniff')
        super().end_headers()

    def log_message(self, *args):             # pythonw has no console
        pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False               # on Windows this stops a second copy sharing the port


def main():
    if sys.stdout is None: sys.stdout = open(os.devnull, 'w')
    if sys.stderr is None: sys.stderr = open(os.devnull, 'w')
    try:
        srv = Server(('127.0.0.1', PORT), functools.partial(Handler, directory=WEB))
    except OSError:
        return 0                               # already running
    srv.serve_forever()


if __name__ == '__main__':
    sys.exit(main())
