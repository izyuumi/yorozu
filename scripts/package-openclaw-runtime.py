#!/usr/bin/env python3
"""Offline development assembler. No install, downloads, profiles, or runtime launch.
Copies only tracked source, reviewed build files, explicit local node_modules, plugin,
and Node. Byte custody is established; original npm archives/lock correspondence are
NOT established by reuse. The output cannot claim production readiness.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import gzip

PIN = {
    'sourceSha': 'f04797ef4d24f3da0f9df74acd58ab773ab5f11e',
    'upstreamSha': 'fc23bc864e4553c2d215e479eeec47b67a0bf943',
    'patchSha256': '601c2eea193de989977a122a98bda8653910848092f7c4937195e40bf63ebc4e',
    'lockSha256': 'c717cc8ed7331b2b4787ed4cbe80d46d3d733de69e3dc9dd7f1d49e6b4942802',
    'entrySha256': 'c7f8d626f2751ee75995ca991b594fb41a21afe0d053e81883a8f85c2eede68e',
    'buildInfoSha256': '38390412b3f1a8109e5e63c30ba9686076571539efa8df3010d4c0d45a55514d',
    'protocolSha256': 'e5dad9efc6acfb59124d1c9872541b811abc56956d3d11abea7f2c37866aed4a',
    'nodeSha256': '56d28b39a8048f0cd1af7ad7e09f6cbe1c04439b6dfeb6c8d9090c082af60861',
}
EVIDENCE = {'kind': 'reused-local-bytes-inventory-only', 'archiveProvenanceVerified': False, 'lockfileMatchEstablished': False}
# A closure produced by `pnpm install --frozen-lockfile` with the pinned package manager:
# pnpm verified every fetched archive against the integrity digests of the reviewed
# lockfile and refused resolution changes. The assembler re-checks the pinned lockfile
# digest and the pnpm-written installed lock before admitting this claim.
FROZEN_EVIDENCE = {'kind': 'pnpm-frozen-lockfile-install-v1', 'archiveProvenanceVerified': True, 'lockfileMatchEstablished': True}
MACHO = {b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe', b'\xbe\xba\xfe\xca'}
MANIFEST = 'runtime-artifact.json'
SIGNED_STAGE = 'after-nested-signing-before-outer-bundle-signing'


def frozen_evidence(source, package_manager, installed_lock_sha256):
    """Admit the frozen-install claim only with explicit, rechecked facts."""
    if not isinstance(package_manager, str) or not package_manager.startswith('pnpm@'):
        raise ValueError('frozen-lockfile evidence requires the pinned pnpm version')
    modules = source / 'node_modules' / '.modules.yaml'
    installed = source / 'node_modules' / '.pnpm' / 'lock.yaml'
    if not modules.is_file() or not installed.is_file():
        raise ValueError('frozen-lockfile evidence requires a pnpm-written installation')
    if digest(installed) != installed_lock_sha256:
        raise ValueError('installed lock digest differs from the explicit frozen-install receipt')
    return {**FROZEN_EVIDENCE, 'packageManager': package_manager, 'lockSha256': PIN['lockSha256'], 'installedLockSha256': installed_lock_sha256}


def reseal_after_nested_signing(root):
    """Record nested code-signing byte changes of existing Mach-O files only."""
    root = root.resolve(strict=True)
    manifest = json.loads((root / MANIFEST).read_text())
    if manifest.get('kind') != 'yorozu-openclaw-runtime' or manifest.get('hashStage') != 'assembled-before-signing' or manifest.get('pins') != PIN:
        raise ValueError('reseal requires an unsigned sealed OpenClaw artifact with the exact pins')
    if hashlib.sha256(encoded(manifest['files'])).hexdigest() != manifest['inventorySha256']:
        raise ValueError('sealed inventory digest mismatch')
    prior = {r['path']: r for r in manifest['files']}
    rows = [r for r in inventory(root) if r['path'] != MANIFEST]
    current = {r['path']: r for r in rows}
    if prior.keys() != current.keys():
        raise ValueError('signing changed the artifact layout')
    resigned = []
    for path, row in current.items():
        if prior[path] == row:
            continue
        if 'sha256' not in row or 'sha256' not in prior[path] or prior[path]['mode'] != row['mode']:
            raise ValueError('reseal permits hash updates to existing regular files only')
        with (root / path).open('rb') as f:
            if f.read(4) not in MACHO:
                raise ValueError('reseal permits changed bytes in Mach-O files only: ' + path)
        resigned.append(path)
    if 'node' not in resigned:
        raise ValueError('nested signing must have resigned the sealed Node binary')
    manifest['reseal'] = {'unsignedInventorySha256': manifest['inventorySha256'], 'unsignedNodeSha256': PIN['nodeSha256'], 'resignedPaths': sorted(resigned)}
    manifest['files'] = rows
    manifest['inventorySha256'] = hashlib.sha256(encoded(rows)).hexdigest()
    manifest['hashStage'] = SIGNED_STAGE
    (root / MANIFEST).write_bytes(encoded(manifest) + b'\n')
    (root / MANIFEST).chmod(0o644)
    receipt = {'hashStage': SIGNED_STAGE, 'inventorySha256': manifest['inventorySha256'], 'resignedPaths': len(resigned), 'unsignedInventorySha256': manifest['reseal']['unsignedInventorySha256']}
    print(json.dumps(receipt, sort_keys=True))
    return receipt


def encoded(v):
    return json.dumps(v, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def digest(p):
    with open(p, 'rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def git(source, *args):
    return subprocess.check_output(['/usr/bin/git', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', '-C', str(source), *args],
                                   env={'PATH': '/usr/bin:/bin', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_OPTIONAL_LOCKS': '0'})


def safe_relative(v):
    if not isinstance(v, str) or not v or v.startswith('/') or '\\' in v or any(ord(c) < 32 or ord(c) == 127 for c in v) or any(p in ('', '.', '..') for p in v.split('/')):
        raise ValueError('unsafe relative path')
    return v


def inventory(root):
    rows = []
    for p in sorted(root.rglob('*')):
        rel = safe_relative(p.relative_to(root).as_posix())
        s = p.lstat()
        if p.is_symlink():
            target = os.readlink(p)
            if os.path.isabs(target) or '\\' in target or not target or any(ord(c) < 32 or ord(c) == 127 for c in target):
                raise ValueError('invalid link')
            p.resolve(strict=True).relative_to(root.resolve())
            rows.append({'path': rel, 'link': target})
        elif stat.S_ISREG(s.st_mode):
            if s.st_nlink != 1 or s.st_mode & 0o022:
                raise ValueError('hardlinked or writable payload')
            rows.append({'path': rel, 'sha256': digest(p), 'bytes': s.st_size, 'mode': 0o755 if s.st_mode & 0o111 else 0o644})
        elif not stat.S_ISDIR(s.st_mode):
            raise ValueError('special payload')
    return sorted(rows, key=lambda row: row['path'])


def copy_file(src, dst, source_root):
    info = src.lstat()
    dst.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    if stat.S_ISLNK(info.st_mode):
        src.resolve(strict=True).relative_to(source_root.resolve())
        link = os.readlink(src)
        if os.path.isabs(link):
            raise ValueError('absolute source symlink')
        if dst.exists() or dst.is_symlink():
            if not dst.is_symlink() or os.readlink(dst) != link:
                raise ValueError('conflicting copied link')
        else:
            dst.symlink_to(link)
    elif stat.S_ISREG(info.st_mode):
        if dst.is_symlink():
            raise ValueError('copy over symlink')
        shutil.copyfile(src, dst)
        dst.chmod(0o755 if info.st_mode & 0o111 else 0o644)
        if digest(src) != digest(dst):
            raise ValueError('input changed during copy')
    else:
        raise ValueError('not a regular file or link')


def archive(root, output):
    # Canonical sorted members and timestamp/ownership, no host names/absolute paths.
    with output.open('wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0, compresslevel=1) as gz, tarfile.open(fileobj=gz, mode='w|') as tar:
        for p in sorted(root.rglob('*')):
            t = tar.gettarinfo(str(p), arcname=p.relative_to(root).as_posix())
            t.uid = t.gid = 0
            t.uname = t.gname = ''
            t.mtime = 0
            t.mode = (0o755 if t.mode & 0o111 else 0o644) if t.isfile() else (0o755 if t.isdir() else 0o777)
            if t.isfile():
                with p.open('rb') as f:
                    tar.addfile(t, f)
            else:
                tar.addfile(t)


def verify_archive(root, output):
    expected = {r['path']: r for r in inventory(root)}
    seen = set()
    with tarfile.open(output, 'r|gz') as tar:
        for t in tar:
            safe_relative(t.name)
            if t.isdir():
                continue
            if t.name in seen:
                raise ValueError('duplicate archive entry')
            seen.add(t.name)
            r = expected[t.name]
            if 'link' in r:
                if not t.issym() or t.linkname != r['link']:
                    raise ValueError('archive link mismatch')
            elif not t.isfile() or t.size != r['bytes'] or t.mode != r['mode'] or hashlib.file_digest(tar.extractfile(t), 'sha256').hexdigest() != r['sha256']:
                raise ValueError('archive content mismatch')
    if seen != set(expected):
        raise ValueError('archive missing entries')
    return len(seen)


def assemble(source, evidence, plugin, node, output, dependency_evidence=EVIDENCE):
    if output.exists():
        raise ValueError('output must be fresh')
    if git(source, 'rev-parse', 'HEAD').decode().strip() != PIN['sourceSha'] or git(source, 'status', '--porcelain', '--untracked-files=no').strip():
        raise ValueError('source identity/cleanliness mismatch')
    if hashlib.sha256(git(source, 'diff', '--binary', '--abbrev=8', '--no-color', '--no-ext-diff', '--no-textconv', '--src-prefix=a/', '--dst-prefix=b/', PIN['upstreamSha'], 'HEAD')).hexdigest() != PIN['patchSha256']:
        raise ValueError('full upstream diff mismatch')
    checks = {'pnpm-lock.yaml': 'lockSha256', 'dist/yorozu-gateway-embedding.js': 'entrySha256', 'dist/build-info.json': 'buildInfoSha256', 'dist/protocol.schema.json': 'protocolSha256'}
    for rel, key in checks.items():
        if digest(source / rel) != PIN[key]:
            raise ValueError('reviewed build pin mismatch')
    if digest(node) != PIN['nodeSha256']:
        raise ValueError('Node mismatch')
    build_rows = json.loads((evidence / 'built-artifacts-manifest.json').read_text())
    paths = set(git(source, 'ls-files', '-z').decode().strip('\0').split('\0'))
    for row in build_rows:
        rel = safe_relative(row['path'])
        p = source / rel
        if 'symlink' in row:
            if not p.is_symlink() or os.readlink(p) != row['symlink']:
                raise ValueError('reviewed build link mismatch')
        elif p.is_symlink() or digest(p) != row['sha256']:
            raise ValueError('reviewed build byte mismatch')
        paths.add(rel)
    # Reuse complete workspace-local closures, including workspace link targets.
    # No dependency resolver/install command is called. No claim of minimal closure.
    dependency_paths = set()
    for base, dirs, files in os.walk(source, followlinks=False):
        dirs[:] = [d for d in dirs if d != '.git']
        base = Path(base)
        for name in list(dirs):
            p = base / name
            if p.is_symlink():
                files.append(name)
                dirs.remove(name)
        for name in files:
            p = base / name
            rel = p.relative_to(source).as_posix()
            if 'node_modules' in p.relative_to(source).parts:
                dependency_paths.add(rel)
    paths.update(dependency_paths)
    root = output / 'Resources' / 'agent-runtimes' / 'openclaw'
    root.mkdir(parents=True, mode=0o755)
    for rel in sorted(paths):
        safe_relative(rel)
        if '.git' in Path(rel).parts:
            raise ValueError('git internals forbidden')
        copy_file(source / rel, root / 'source' / rel, source)
    # Minimal detached Git object custody required by the existing adapter. No
    # branch, remote, hooks, alternates, inherited config, or mutable source repo.
    metadata = root / 'source' / '.git'
    (metadata / 'objects' / 'pack').mkdir(parents=True)
    (metadata / 'refs').mkdir()
    (metadata / 'HEAD').write_text(PIN['sourceSha'] + '\n')
    (metadata / 'config').write_text('[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tfilemode = true\n')
    # Only the two commits and their trees/blobs, not parent history or accounts.
    objects = git(source, 'rev-list', '--objects', '--no-walk', PIN['sourceSha'], PIN['upstreamSha'])
    ids = b'\n'.join(line.split(b' ')[0] for line in objects.splitlines()) + b'\n'
    pack = subprocess.check_output(['/usr/bin/git', '-C', str(source), 'pack-objects', '--stdout'], input=ids,
                                   env={'PATH': '/usr/bin:/bin', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'})
    pack_path = metadata / 'objects' / 'pack' / ('pack-' + pack[-20:].hex() + '.pack')
    pack_path.write_bytes(pack)
    git(root / 'source', 'index-pack', str(pack_path))
    git(root / 'source', 'read-tree', PIN['sourceSha'])
    git(root / 'source', 'diff', '--quiet', 'HEAD', '--')
    for name in ('adapter.mjs', 'manifest.json'):
        if not (plugin / name).is_file():
            raise ValueError('missing plugin input')
    # Explicit task-owned plugin tree also carries the uniform-memory bridge when
    # integrated. Do not silently package only the adapter while omitting imports.
    for p in sorted(plugin.rglob('*')):
        if '.git' in p.relative_to(plugin).parts or '__pycache__' in p.relative_to(plugin).parts:
            raise ValueError('unexpected plugin metadata')
        if not p.is_dir() or p.is_symlink():
            copy_file(p, root / 'plugin' / p.relative_to(plugin), plugin)
    copy_file(node, root / 'node', node.parent)
    rows = inventory(root)
    artifact = {'schemaVersion': 1, 'kind': 'yorozu-openclaw-runtime', 'productionReady': False,
                'hashStage': 'assembled-before-signing', 'pins': PIN, 'dependencyEvidence': dependency_evidence,
                'files': rows, 'inventorySha256': hashlib.sha256(encoded(rows)).hexdigest()}
    (root / 'runtime-artifact.json').write_bytes(encoded(artifact) + b'\n')
    (root / 'runtime-artifact.json').chmod(0o644)
    archive_path = output / 'openclaw-sealed-development.tar.gz'
    archive(root, archive_path)
    entries = verify_archive(root, archive_path)
    receipt = {'productionReady': False, 'sourceCommit': PIN['sourceSha'], 'pins': PIN,
               'inventorySha256': artifact['inventorySha256'], 'archiveSha256': digest(archive_path),
               'manifestSha256': digest(root / 'runtime-artifact.json'), 'archiveVerifiedEntries': entries,
               'reusedDependencyEntries': len(dependency_paths), 'dependencyEvidence': dependency_evidence,
               'remainingGates': [*([] if dependency_evidence.get('lockfileMatchEstablished') else ['Original dependency archive provenance and lockfile correspondence']),
                   'Native shared-library closure/platform relocation acceptance',
                   'Independent integrated loader/adapter/memory review and paired-device/host-tool acceptance',
                   'Embedding-owned stop/restart/lifetime acceptance', 'Distribution signing and post-sign inventory resealing']}
    (output / 'receipt.json').write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
    print(json.dumps(receipt, sort_keys=True, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reseal-after-nested-signing', type=Path, help='sealed artifact root inside a nested-signed bundle')
    for name in ('source', 'evidence', 'plugin', 'node', 'output'):
        parser.add_argument('--' + name, type=Path)
    parser.add_argument('--frozen-install-package-manager', help='e.g. pnpm@12.5.1; selects pnpm-frozen-lockfile-install-v1 evidence')
    parser.add_argument('--frozen-install-installed-lock-sha256', help='sha256 of node_modules/.pnpm/lock.yaml written by that install')
    args = parser.parse_args()
    if args.reseal_after_nested_signing:
        reseal_after_nested_signing(args.reseal_after_nested_signing)
    else:
        inputs = {name: getattr(args, name) for name in ('source', 'evidence', 'plugin', 'node', 'output')}
        if any(value is None for value in inputs.values()):
            raise SystemExit('assembly requires --source --evidence --plugin --node --output')
        evidence = EVIDENCE
        if args.frozen_install_package_manager or args.frozen_install_installed_lock_sha256:
            if not (args.frozen_install_package_manager and args.frozen_install_installed_lock_sha256):
                raise SystemExit('frozen-install evidence requires both the package manager and the installed lock digest')
            evidence = frozen_evidence(inputs['source'], args.frozen_install_package_manager, args.frozen_install_installed_lock_sha256)
        assemble(**inputs, dependency_evidence=evidence)
