"""Inert adversarial fixtures: no native runtime, signing, model or accounts."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('hermes-release-provenance.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
p = r.p


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'runtime'
        self.root.mkdir()
        self.revision = 'a' * 40
        self.pin = {'sourceSha': p.SOURCE_SHA, 'uvLockSha256': 'lock', 'pythonTreeSha256': 'tree', 'pythonBinarySha256': 'bin', 'dependencies': []}
        self.plugin = {}
        for name in p.PLUGIN_FILES:
            data = ('reviewed ' + name).encode()
            self.plugin[r.PREFIX + name] = data
            self.put('plugin/' + name, data)
        self.put('python/bin/python3.13', b'\xcf\xfa\xed\xfeinitial native fixture')
        self.put('python/lib/module.py', b'inert = True\n')
        self.rows = p.inventory(self.root)
        self.native = ['python/bin/python3.13']
        self.manifest = {'schemaVersion': 1, 'kind': 'yorozu-hermes-runtime', 'upstream': self.pin,
                         'paths': {'python': 'python/bin/python3.13', 'source': 'source', 'adapter': 'plugin/adapter.mjs'},
                         'hashStage': 'assembled-before-signing', 'files': self.rows, 'inventorySha256': p.tree_digest(self.rows),
                         'machODependencies': [{'path': n} for n in self.native]}
        self.evidence = {'originalArchivesEstablished': True, 'sourceSha': p.SOURCE_SHA, 'uvLockSha256':'lock',
                         'python': {'preparedRuntimeTreeSha256':'tree', 'binarySha256':'bin'}, 'dependencies': []}
        self.evidence_bytes = json.dumps(self.evidence).encode()
        self.layout = {'paths': self.manifest['paths'], 'approvedAssembledPayload': {
            'nativePaths': self.native, 'inventoryWithoutPluginSha256': p.tree_digest([v for v in self.rows if not v['path'].startswith('plugin/')])},
            'publicArchiveEvidence': {'path':'docs/evidence.json', 'sha256':hashlib.sha256(self.evidence_bytes).hexdigest()}}
        self.save()
        self.baseline = self.root.parent / 'unsigned.json'
        self.baseline.write_text(json.dumps(self.manifest))
        self.git = patch.object(p, 'git', side_effect=self.git_read)
        self.git.start()

    def tearDown(self):
        self.git.stop()
        self.temp.cleanup()

    def put(self, name, data):
        f = self.root / name
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(data)
        f.chmod(0o644)

    def git_read(self, repo, command, target):
        self.assertEqual(command, 'show')
        revision, name = target.split(':', 1)
        self.assertEqual(revision, self.revision)
        if name.endswith('runtime-input-pin.json'):
            return json.dumps(self.pin).encode()
        if name.endswith('runtime-layout.json'):
            return json.dumps(self.layout).encode()
        if name == 'docs/evidence.json':
            return self.evidence_bytes
        return self.plugin[name]

    def save(self, regenerate=False):
        if regenerate:
            self.manifest['files'] = p.inventory(self.root, lambda n:n==p.MANIFEST)
            self.manifest['inventorySha256'] = p.tree_digest(self.manifest['files'])
        (self.root / p.MANIFEST).write_text(json.dumps(self.manifest))

    def verify(self, signed=False):
        return r.verify(self.root, Path('.'), self.revision, self.baseline if signed else None)

    def test_reviewed_unsigned_payload_passes_without_execution(self):
        self.assertTrue(self.verify()['verified'])

    def test_plugin_tampering_with_regenerated_inventory_fails(self):
        self.put('plugin/adapter.mjs', b'unreviewed')
        self.save(True)
        with self.assertRaisesRegex(ValueError, 'Plugin bytes'):
            self.verify()

    def test_python_tampering_with_regenerated_inventory_fails(self):
        self.put('python/lib/module.py', b'unreviewed')
        self.save(True)
        with self.assertRaisesRegex(ValueError, 'approved assembled inventory'):
            self.verify()

    def test_substituted_upstream_pin_fails(self):
        self.manifest['upstream'] = {**self.pin, 'pythonBinarySha256':'substitute'}
        self.save()
        with self.assertRaisesRegex(ValueError, 'committed input pin'):
            self.verify()

    def test_signing_existing_native_only_passes(self):
        self.put(self.native[0], b'\xcf\xfa\xed\xfesigned native fixture')
        self.manifest['hashStage'] = 'after-nested-signing-before-outer-bundle-signing'
        self.save(True)
        self.assertTrue(self.verify(True)['verified'])
        with self.assertRaises(ValueError):
            self.verify(False)

    def test_signing_does_not_authorize_plugin_changes(self):
        self.put('plugin/adapter.mjs', b'changed')
        self.save(True)
        with self.assertRaisesRegex(ValueError, 'non-native'):
            self.verify(True)

    def test_forged_native_allowlist_cannot_reclassify_python_source(self):
        baseline = json.loads(self.baseline.read_text())
        baseline['machODependencies'].append({'path':'python/lib/module.py'})
        self.baseline.write_text(json.dumps(baseline))
        self.put('python/lib/module.py', b'\xcf\xfa\xed\xfeevil')
        self.save(True)
        with self.assertRaisesRegex(ValueError, 'allowlist'):
            self.verify(True)

    def test_signing_mode_and_layout_changes_rejected(self):
        (self.root/self.native[0]).chmod(0o755)
        self.save(True)
        with self.assertRaisesRegex(ValueError, 'non-native'):
            self.verify(True)
        self.put('python/new.so', b'\xcf\xfa\xed\xfenew')
        self.save(True)
        with self.assertRaisesRegex(ValueError, 'layout'):
            self.verify(True)

    def test_forged_unsigned_baseline_rejected(self):
        self.put('python/lib/module.py', b'forged')
        self.save(True)
        self.baseline.write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, 'approved assembled inventory'):
            self.verify(True)


if __name__ == '__main__':
    unittest.main()
