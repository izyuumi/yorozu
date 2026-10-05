#!/usr/bin/env python3
"""Inert trusted-input gate. Run BEFORE executing anything from an artifact.

Trust root: reviewed Git revision, not runtime-artifact.json. A signing transition
requires a separately retained unsigned manifest, itself checked against that root.
This verifies prepared payload approval, not original archive acquisition approval.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re

spec = importlib.util.spec_from_file_location('packager', Path(__file__).with_name('package-hermes-runtime.py'))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
PREFIX = 'packages/harness-plugins/hermes/'


def trusted_json(repo, revision, name):
    return json.loads(p.git(repo, 'show', revision + ':' + PREFIX + name))


def verify_manifest(manifest, pin, layout, plugin_rows):
    if manifest.get('schemaVersion') != 1 or manifest.get('kind') != 'yorozu-hermes-runtime':
        p.fail('Invalid runtime identity')
    if manifest.get('upstream') != pin:
        p.fail('Artifact upstream differs from committed input pin')
    if manifest.get('paths') != {k: layout['paths'][k] for k in ('python', 'source', 'adapter')}:
        p.fail('Artifact paths differ from committed layout')
    if sorted(r['path'] for r in manifest['machODependencies']) != layout['approvedAssembledPayload']['nativePaths']:
        p.fail('Native signing allowlist differs from committed layout')
    rows = manifest['files']
    if len({r['path'] for r in rows}) != len(rows) or p.tree_digest(rows) != manifest['inventorySha256']:
        p.fail('Invalid inventory')
    payload = [r for r in rows if not r['path'].startswith('plugin/')]
    if p.tree_digest(payload) != layout['approvedAssembledPayload']['inventoryWithoutPluginSha256']:
        p.fail('Payload differs from committed approved assembled inventory')
    if [r for r in rows if r['path'].startswith('plugin/')] != plugin_rows:
        p.fail('Plugin bytes differ from reviewed source')
    if manifest['hashStage'] != 'assembled-before-signing':
        p.fail('Trusted baseline must be assembled-before-signing')


def verify(root, repo, revision, unsigned_manifest=None):
    if not re.fullmatch('[0-9a-f]{40}', revision):
        p.fail('Exact reviewed Git revision required')
    root = root.resolve(strict=True)
    pin = trusted_json(repo, revision, 'runtime-input-pin.json')
    layout = trusted_json(repo, revision, 'runtime-layout.json')
    evidence_pin = layout['publicArchiveEvidence']
    evidence_bytes = p.git(repo, 'show', revision + ':' + evidence_pin['path'])
    evidence = json.loads(evidence_bytes)
    if (hashlib.sha256(evidence_bytes).hexdigest() != evidence_pin['sha256'] or
        evidence.get('originalArchivesEstablished') is not True or
        evidence.get('sourceSha') != pin['sourceSha'] or
        evidence.get('uvLockSha256') != pin['uvLockSha256'] or
        evidence['python']['preparedRuntimeTreeSha256'] != pin['pythonTreeSha256'] or
        evidence['python']['binarySha256'] != pin['pythonBinarySha256'] or
        {(d['name'], d['version']) for d in evidence['dependencies']} !=
        {(d['name'], d['version']) for d in pin['dependencies']}):
        p.fail('Original archive evidence differs from committed input pins')
    plugin_rows = []
    for name in sorted(p.PLUGIN_FILES):
        data = p.git(repo, 'show', revision + ':' + PREFIX + name)
        plugin_rows.append({'path': 'plugin/' + name, 'sha256': hashlib.sha256(data).hexdigest(), 'mode': 0o644})
    manifest = json.loads((root / p.MANIFEST).read_text())
    baseline = json.loads(unsigned_manifest.read_text()) if unsigned_manifest else manifest
    verify_manifest(baseline, pin, layout, plugin_rows)
    rows = p.inventory(root, lambda name: name == p.MANIFEST)
    if unsigned_manifest:
        # Never take the mutable manifest's list of native files as authority.
        before = {r['path']: r for r in baseline['files']}
        after = {r['path']: r for r in rows}
        if before.keys() != after.keys():
            p.fail('Signing changed artifact layout')
        known_native = set(layout['approvedAssembledPayload']['nativePaths'])
        for name, row in after.items():
            if row == before[name]:
                continue
            if (name not in known_native or not name.startswith('python/') or
                'sha256' not in row or 'sha256' not in before[name] or
                row.get('mode') != before[name].get('mode')):
                p.fail('Signing changed non-native payload')
            with (root / name).open('rb') as stream:
                if stream.read(4) not in p.MACHO:
                    p.fail('Signing replaced a native file with non-native bytes')
        # Pin all identity/derivation fields; only existing native hashes and
        # measured signing-stage audit outputs may change.
        mutable = {'files', 'inventorySha256', 'hashStage', 'machODependencies', 'inertImportProbe'}
        if {k:v for k,v in manifest.items() if k not in mutable} != {k:v for k,v in baseline.items() if k not in mutable}:
            p.fail('Signing changed provenance identity')
    if rows != manifest['files'] or p.tree_digest(rows) != manifest['inventorySha256']:
        p.fail('Artifact bytes differ from sealed inventory')
    p.validate_site_ownership(root / 'python/lib/python3.13/site-packages')
    return {'verified': True, 'reviewedSourceSha': revision, 'inventorySha256': manifest['inventorySha256'],
            'originalArchiveGate': 'separate; see committed public archive evidence', 'runtimeExecuted': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--reviewed-repo', type=Path, required=True)
    parser.add_argument('--reviewed-revision', required=True)
    parser.add_argument('--unsigned-manifest', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.artifact, args.reviewed_repo, args.reviewed_revision, args.unsigned_manifest), sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit('Hermes release provenance failed: ' + str(error))
