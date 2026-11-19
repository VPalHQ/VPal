"""Builds a VPal release's update files (for me, not shipped):

    python3 make_release.py SRC VERSION OUTDIR [--repo OWNER/REPO | --base URL] [--notes FILE] [--min-from V]

SRC is a VPal folder laid out like an install (build/files). Writes OUTDIR/VPal-update-VERSION.zip and
OUTDIR/vpal-update.json. The zip is checked with the updater's own rules before the json is written."""
import os, sys, re, json, time, hashlib, zipfile, argparse

ap = argparse.ArgumentParser()
ap.add_argument('src'); ap.add_argument('version'); ap.add_argument('out')
ap.add_argument('--repo'); ap.add_argument('--base'); ap.add_argument('--notes'); ap.add_argument('--min-from'); ap.add_argument('--setup')
a = ap.parse_args()

sys.path.insert(0, os.path.join(a.src, 'CommandCenter', 'service'))
import vpal_updater as vu

util_py = open(os.path.join(a.src, 'CommandCenter', 'service', 'cc', 'util.py'), encoding='utf-8').read()
m = re.search(r"^VERSION = '([^']*)'", util_py, re.M)
if not m or m.group(1) != a.version: sys.exit(f'util.py says {m and m.group(1)}, not {a.version}')

name = f'VPal-update-{a.version}.zip'
os.makedirs(a.out, exist_ok=True)
zp = os.path.join(a.out, name)
files = []
for d, subs, fs in os.walk(a.src):
    subs[:] = sorted(s for s in subs if s != '__pycache__')
    for f in sorted(fs):
        rel = os.path.relpath(os.path.join(d, f), a.src).replace(os.sep, '/')
        try:
            if vu.check_name(rel): files.append(rel)
        except vu.Refused:
            pass                                    # not part of an update (data, players, setup-only files)
with zipfile.ZipFile(zp, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for rel in files:
        z.write(os.path.join(a.src, *rel.split('/')), rel)
plan = vu.plan(zp)
assert vu.zip_version(zp) == a.version
data = open(zp, 'rb').read()
base = a.base or (f'https://github.com/{a.repo}/releases/download/v{a.version}' if a.repo else 'https://github.com/OWNER/REPO/releases/download/v' + a.version)
info = {'version': a.version, 'date': time.strftime('%Y-%m-%d'), 'zip': base.rstrip('/') + '/' + name,
        'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data),
        'notes': [l.strip().lstrip('-* ').strip() for l in open(a.notes, encoding='utf-8')] if a.notes else []}
info['notes'] = [n for n in info['notes'] if n]
if a.min_from: info['min_from'] = a.min_from
if a.setup: info['setup'] = a.setup
json.dump(info, open(os.path.join(a.out, 'vpal-update.json'), 'w', encoding='utf-8'), indent=1)
print(f'{name}: {len(plan)} files, {len(data):,} bytes, sha256 {info["sha256"][:16]}...')
