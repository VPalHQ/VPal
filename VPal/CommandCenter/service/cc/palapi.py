"""The Palworld server's own REST API (this PC only, port 8212 by default). Never exposed to the internet."""
import json, base64, urllib.request, urllib.error
from . import config


class ApiError(Exception):
    pass


class Api:
    def __init__(self, sd):
        self.info = config.api_info(sd)

    @property
    def enabled(self):
        return self.info is not None

    def _call(self, method, path, body=None, timeout=6):
        if not self.info: raise ApiError('The REST API is off in PalWorldSettings.ini (RESTAPIEnabled=False).')
        auth = base64.b64encode(('admin:' + self.info['password']).encode()).decode()
        data = None if body is None else json.dumps(body).encode('utf-8')
        req = urllib.request.Request(self.info['url'] + path, data=data, method=method,
                                     headers={'Authorization': 'Basic ' + auth, 'Content-Type': 'application/json; charset=utf-8',
                                              'Accept': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            raise ApiError(f'The server answered {e.code} to {path}' + (' (wrong admin password?)' if e.code == 401 else ''))
        except Exception as e:                         # refused, timed out, reset
            raise ApiError(f'No answer from the server ({e.__class__.__name__})')
        if not raw: return {}
        try: return json.loads(raw.decode('utf-8', errors='replace'))
        except ValueError: return {}

    # reads
    def server_info(self): return self._call('GET', '/info')
    def metrics(self): return self._call('GET', '/metrics')
    def settings(self): return self._call('GET', '/settings')
    def players(self):
        return [p for p in (self._call('GET', '/players').get('players') or []) if p]

    # actions
    def announce(self, message): return self._call('POST', '/announce', {'message': message[:200]})
    def save(self): return self._call('POST', '/save', {}, timeout=60)
    def shutdown(self, wait_s, message): return self._call('POST', '/shutdown', {'waittime': int(wait_s), 'message': message[:200]})
    def force_stop(self): return self._call('POST', '/stop', {})
    def kick(self, uid, message=''): return self._call('POST', '/kick', {'userid': uid, 'message': message or 'You were removed from the server.'})
    def ban(self, uid, message=''): return self._call('POST', '/ban', {'userid': uid, 'message': message or 'You are banned from this server.'})
    def unban(self, uid): return self._call('POST', '/unban', {'userid': uid})
