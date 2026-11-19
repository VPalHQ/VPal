"""PalWorldSettings.ini: read every setting, change only the ones you edited, and never write a file that doesn't
read back the same way. Works exactly like the control panel's Settings tabs (same backups folder and change log)."""
import os, re, json, time, glob, shutil
from . import util, config

CATALOG = json.load(open(os.path.join(os.path.dirname(__file__), 'settings_catalog.json'), encoding='utf-8'))
META = {s['key']: s for s in CATALOG['settings']}
KEEP_BACKUPS = 30
LINE = re.compile(r'(?m)^OptionSettings=\((.*)\)[ \t\r]*$')


def _split(inner):
    items, buf, q, depth = [], [], False, 0
    for ch in inner:
        if ch == '"': q = not q
        elif not q and ch == '(': depth += 1
        elif not q and ch == ')': depth -= 1
        if ch == ',' and not q and depth == 0:
            items.append(''.join(buf)); buf = []
        else:
            buf.append(ch)
    items.append(''.join(buf))
    return items


def _read(sd):
    path = config.ini_path(sd)
    raw = open(path, 'rb').read()
    if raw.startswith(b'\xef\xbb\xbf'): enc, text = 'utf-8-sig', raw[3:].decode('utf-8')
    elif raw.startswith(b'\xff\xfe'): enc, text = 'utf-16', raw.decode('utf-16')
    else: enc, text = 'utf-8', raw.decode('utf-8', errors='replace')
    m = LINE.search(text)
    if not m: raise RuntimeError('Could not find the OptionSettings line in ' + path)
    items = []
    for part in _split(m.group(1)):
        k, eq, v = part.partition('=')
        items.append((k, v if eq else None))
    model = {'path': path, 'enc': enc, 'text': text, 'span': m.span(1), 'items': items}
    if _rebuild(model, {}) != text:
        raise RuntimeError('The settings file has a layout the Command Center cannot safely rewrite, so it will not touch it.')
    return model


def _rebuild(model, changes):
    parts = [k if v is None else f'{k}={changes.get(k, v)}' for k, v in model['items']]
    a, b = model['span']
    return model['text'][:a] + ','.join(parts) + model['text'][b:]


def _typed(meta, raw):
    t = meta['type'] if meta else 'Raw'
    try:
        if t == 'Float': return float(raw)
        if t == 'Int': return int(float(raw))
    except (TypeError, ValueError):
        return raw
    if t == 'Bool': return str(raw).lower() == 'true'
    if t == 'Text': return raw[1:-1] if len(raw) >= 2 and raw[0] == raw[-1] == '"' else raw
    return raw


def read_all(sd):
    """Everything the Settings page shows. Masked values (the admin password) never leave this PC's service."""
    model = _read(sd)
    vals = {}
    for k, v in model['items']:
        if v is not None and k not in vals: vals[k] = v
    out, other = [], []
    for s in CATALOG['settings']:
        if s['key'] not in vals: continue
        raw = vals[s['key']]
        e = dict(s, value=None if s.get('mask') else _typed(s, raw), raw=None if s.get('mask') else raw)
        if s['type'] == 'Text': e['quoted'] = raw.startswith('"')
        out.append(e)
    for k, v in vals.items():
        if k not in META: other.append({'key': k, 'tab': 'Other', 'type': 'Raw', 'label': k, 'desc': 'Not in the Command Center list yet, so it is shown as it is in the file.', 'locked': True, 'value': v, 'raw': v})
    return {'tabs': CATALOG['tabs'] + (['Other'] if other else []), 'settings': out + other, 'file': model['path'],
            'modified': round(os.path.getmtime(model['path']))}


def _format(meta, old_raw, v):
    t = meta['type']
    if meta.get('locked') or t == 'Raw': raise ValueError(f"{meta['label']} is locked.")
    if t in ('Float', 'Int'):
        try: n = float(v)
        except (TypeError, ValueError): raise ValueError(f"{meta['label']}: enter a number.")
        lo, hi = meta.get('min', -1e18), meta.get('max', 1e18)
        if n < lo or n > hi: raise ValueError(f"{meta['label']}: pick a value from {lo:g} to {hi:g}.")
        return f'{n:.6f}' if t == 'Float' else str(int(round(n)))
    if t == 'Bool': return 'True' if (v is True or str(v).lower() == 'true') else 'False'
    if t == 'Enum':
        if v not in meta.get('options', []): raise ValueError(f"{meta['label']}: pick one of {', '.join(meta.get('options', []))}.")
        return v
    if t == 'Text':
        v = str(v)
        if '"' in v: raise ValueError(f"{meta['label']}: remove the double quote (\") marks.")
        if '\n' in v or '\r' in v: raise ValueError(f"{meta['label']}: keep it on one line.")
        if meta['key'] == 'ServerName' and not v.strip(): raise ValueError('Server name cannot be blank.')
        return f'"{v}"' if old_raw.startswith('"') else v
    raise ValueError(f"{meta['label']} can't be changed here.")


def save(sd, changes):
    """changes: {key: new value}. Returns what changed. Makes a backup first; nothing is written if any check fails."""
    model = _read(sd)
    old = {}
    for k, v in model['items']:
        if v is not None and k not in old: old[k] = v
    raw_changes = {}
    for k, v in (changes or {}).items():
        meta = META.get(k)
        if not meta: raise ValueError(f'{k} is not a setting the Command Center knows.')
        if k not in old: raise ValueError(f'{k} is no longer in the settings file. Reload the page.')
        r = _format(meta, old[k], v)
        if r != old[k] and not (meta['type'] in ('Float', 'Int') and float(r) == float(old[k])):
            raw_changes[k] = r
    if not raw_changes: return {'saved': 0}
    new = _rebuild(model, raw_changes)
    check = LINE.search(new)
    items = [(k, v if eq else None) for k, eq, v in (p.partition('=') for p in _split(check.group(1)))] if check else []
    if len(items) != len(model['items']) or any(k in raw_changes and v != raw_changes[k] for k, v in items):
        raise RuntimeError('Safety check failed, so nothing was saved.')
    sd_bk = os.path.join(sd, 'settings-backups')
    os.makedirs(sd_bk, exist_ok=True)
    stamp = time.strftime('%Y-%m-%d_%H-%M-%S')
    shutil.copy2(model['path'], os.path.join(sd_bk, f'PalWorldSettings_{stamp}.ini'))
    for f in sorted(glob.glob(os.path.join(sd_bk, 'PalWorldSettings_*.ini')), reverse=True)[KEEP_BACKUPS:]:
        try: os.remove(f)
        except OSError: pass
    data = new.encode('utf-16') if model['enc'] == 'utf-16' else (b'\xef\xbb\xbf' if model['enc'] == 'utf-8-sig' else b'') + new.encode('utf-8')
    tmp = model['path'] + '.cc-tmp'
    with open(tmp, 'wb') as f: f.write(data)
    os.replace(tmp, model['path'])
    when = time.strftime('%Y-%m-%d %H:%M:%S')
    try:
        with open(os.path.join(sd, 'settings-changes-log.txt'), 'a', encoding='utf-8') as f:
            for k in sorted(raw_changes):
                f.write(f'{when}  {k} changed\n' if 'Password' in k else f'{when}  {k} : {old[k]} -> {raw_changes[k]}\n')
    except OSError:
        pass
    names = [META[k]['label'] for k in sorted(raw_changes)]
    util.event('settings', f"Saved {len(raw_changes)} setting change{'s' if len(raw_changes) != 1 else ''}: {', '.join(names[:6])}"
                           f"{'…' if len(names) > 6 else ''}. They apply after the next restart.", 'info')
    return {'saved': len(raw_changes), 'keys': sorted(raw_changes)}
