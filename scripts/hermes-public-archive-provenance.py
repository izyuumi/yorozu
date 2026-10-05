#!/usr/bin/env python3
"""Download only public lock-pinned wheels and compare without importing them.
No installs, profiles or interpreter from the prepared environment are executed.
"""
import argparse
import base64
import concurrent.futures
import csv
import email
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tomllib
import urllib.parse
import zipfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def norm(name):
    return name.lower().replace('_', '-').replace('.', '-')


def inspect_wheel(item):
    metadata_dir, package, output, site = item
    tags = email.message_from_bytes((metadata_dir / 'WHEEL').read_bytes()).get_all('Tag')
    def matches(url):
        filename = urllib.parse.unquote(url).rsplit('/', 1)[1]
        py, abi, platform = filename.removesuffix('.whl').rsplit('-', 3)[-3:]
        return {f'{a}-{b}-{c}' for a in py.split('.') for b in abi.split('.') for c in platform.split('.')} == set(tags)
    candidates = [w for w in package.get('wheels', []) if matches(w['url'])]
    if len(candidates) != 1:
        return {'name': package['name'], 'status': 'blocked', 'reason': 'No unique locked wheel for installed WHEEL tags', 'tags': tags}
    wheel = candidates[0]
    url = wheel['url']
    if urllib.parse.urlparse(url).scheme != 'https' or urllib.parse.urlparse(url).hostname != 'files.pythonhosted.org':
        raise ValueError('Only official public PyPI wheel origin allowed')
    target = output / urllib.parse.unquote(url.rsplit('/', 1)[1])
    if not target.exists():
        subprocess.run(['/usr/bin/curl', '-fLsS', '--proto', '=https', url, '-o', str(target)], check=True)
    data = target.read_bytes()
    if 'sha256:' + sha(data) != wheel['hash']:
        raise ValueError('Downloaded wheel differs from frozen lock')
    mismatches, missing, checked = [], [], 0
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = z.namelist()
        if len(set(names)) != len(names):
            raise ValueError('Duplicate archive member')
        record_name = next(n for n in names if n.endswith('.dist-info/RECORD'))
        claimed = set()
        for name, encoded, size in csv.reader(io.StringIO(z.read(record_name).decode())):
            if name.startswith('/') or '..' in Path(name).parts:
                raise ValueError('Unsafe wheel member')
            claimed.add(name)
            if name == record_name:
                continue
            content = z.read(name)
            if not encoded.startswith('sha256=') or base64.urlsafe_b64encode(hashlib.sha256(content).digest()).decode().rstrip('=') != encoded.split('=', 1)[1] or len(content) != int(size):
                raise ValueError('Wheel RECORD mismatch')
            installed = site / name
            if not installed.is_file():
                missing.append(name)
            elif installed.read_bytes() != content:
                mismatches.append(name)
            else:
                checked += 1
        if {n for n in names if not n.endswith('/')} != claimed:
            raise ValueError('Wheel contains unowned bytes')
    return {'name': package['name'], 'version': package['version'], 'url': url,
            'archivePath': str(target.resolve()), 'sha256': sha(data), 'size': len(data),
            'wheelRecordVerified': True, 'installedFilesEqual': checked, 'missing': missing,
            'mismatches': mismatches, 'status': 'verified' if not missing and not mismatches else 'blocked',
            'generatedMetadata': 'Installed RECORD, INSTALLER, REQUESTED, direct_url/uv metadata are not original wheel payload'}


def main():
    a = argparse.ArgumentParser(description=__doc__)
    a.add_argument('--source', type=Path, required=True)
    a.add_argument('--venv', type=Path, required=True)
    a.add_argument('--output', type=Path, required=True)
    args = a.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    lock = tomllib.loads((args.source / 'uv.lock').read_text())
    packages = {(norm(p['name']), p['version']): p for p in lock['package']}
    site = args.venv / 'lib/python3.13/site-packages'
    tasks, receipts = [], []
    for d in sorted(site.glob('*.dist-info')):
        m = email.message_from_bytes((d / 'METADATA').read_bytes())
        name, version = norm(m['Name']), m['Version']
        if name == 'hermes-agent':
            receipts.append({'name': name, 'version': version, 'status': 'source-built-editable', 'reason': 'No original wheel: generated metadata of exact Git source; source pin must be verified independently'})
        else:
            tasks.append((d, packages[name, version], args.output, site))
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        receipts.extend(pool.map(inspect_wheel, tasks))
    result = {'uvLockSha256': sha((args.source / 'uv.lock').read_bytes()), 'receipts': sorted(receipts, key=lambda x:x['name'])}
    (args.output / 'wheel-receipts.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'verified': sum(r['status']=='verified' for r in receipts), 'other': [r for r in receipts if r['status']!='verified']}))


if __name__ == '__main__':
    main()
