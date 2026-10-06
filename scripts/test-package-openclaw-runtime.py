#!/usr/bin/env python3
"""No downloads/providers. Filesystem/archive rejection tests for offline assembler."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import os
import json

spec = importlib.util.spec_from_file_location('packager', Path(__file__).with_name('package-openclaw-runtime.py'))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve() / 'root'
        self.root.mkdir()
        (self.root / 'file').write_text('offline fixture')
        (self.root / 'file').chmod(0o644)

    def tearDown(self):
        self.temp.cleanup()

    def test_inventory_and_reproducible_archive(self):
        (self.root / 'link').symlink_to('file')
        (self.root / 'file').chmod(0o444)  # Git pack/index files are read-only inputs.
        rows = p.inventory(self.root)
        self.assertEqual(len(rows), 2)
        a, b = self.root.parent / 'a.tgz', self.root.parent / 'b.tgz'
        p.archive(self.root, a)
        p.archive(self.root, b)
        self.assertEqual(p.digest(a), p.digest(b))
        self.assertEqual(p.verify_archive(self.root, a), 2)
        (self.root / 'file').chmod(0o644)
        (self.root / 'file').write_text('changed')
        with self.assertRaises(ValueError):
            p.verify_archive(self.root, a)

    def test_escaping_symlink(self):
        (self.root / 'link').symlink_to('../root')
        # A confined link is okay, even with lexical ..; resolved escape is not.
        p.inventory(self.root)
        (self.root / 'link').unlink()
        (self.root / 'link').symlink_to('..')
        with self.assertRaises(ValueError):
            p.inventory(self.root)

    def test_absolute_and_dangling_links(self):
        for target in ['/etc/passwd', 'absent']:
            (self.root / 'link').symlink_to(target)
            with self.assertRaises((ValueError, FileNotFoundError)):
                p.inventory(self.root)
            (self.root / 'link').unlink()

    def test_hardlink(self):
        os.link(self.root / 'file', self.root / 'hard')
        with self.assertRaises(ValueError):
            p.inventory(self.root)

    def test_special_and_writable(self):
        os.mkfifo(self.root / 'fifo')
        with self.assertRaises(ValueError):
            p.inventory(self.root)
        (self.root / 'fifo').unlink()
        (self.root / 'file').chmod(0o666)
        with self.assertRaises(ValueError):
            p.inventory(self.root)

    def test_paths(self):
        for path in ['', '/a', '../a', 'a/../b', 'a//b', 'a\\b', 'a\x00b']:
            with self.assertRaises(ValueError):
                p.safe_relative(path)

    def test_existing_output_fail_closed(self):
        with self.assertRaisesRegex(ValueError, 'fresh'):
            p.assemble(self.root, self.root, self.root, self.root / 'file', self.root)

    def test_reseal_admits_only_resigned_macho_bytes(self):
        root = self.root
        (root / 'node').write_bytes(b'\xcf\xfa\xed\xfe' + b'unsigned node')
        (root / 'node').chmod(0o755)
        (root / 'plain.js').write_text('code')
        rows = p.inventory(root)
        manifest = {'schemaVersion': 1, 'kind': 'yorozu-openclaw-runtime', 'productionReady': False, 'hashStage': 'assembled-before-signing',
                    'pins': p.PIN, 'dependencyEvidence': p.EVIDENCE, 'files': rows, 'inventorySha256': p.hashlib.sha256(p.encoded(rows)).hexdigest()}
        (root / p.MANIFEST).write_bytes(p.encoded(manifest) + b'\n')
        with self.assertRaises(ValueError):  # nothing resigned: the sealed Node must have been signed
            p.reseal_after_nested_signing(root)
        (root / 'node').write_bytes(b'\xcf\xfa\xed\xfe' + b'signed node')
        receipt = p.reseal_after_nested_signing(root)
        sealed = json.loads((root / p.MANIFEST).read_text())
        self.assertEqual(sealed['hashStage'], p.SIGNED_STAGE)
        self.assertEqual(sealed['reseal']['resignedPaths'], ['node'])
        self.assertEqual(sealed['reseal']['unsignedInventorySha256'], manifest['inventorySha256'])
        self.assertEqual(receipt['inventorySha256'], p.hashlib.sha256(p.encoded([r for r in p.inventory(root) if r['path'] != p.MANIFEST])).hexdigest())
        with self.assertRaises(ValueError):  # already resealed
            p.reseal_after_nested_signing(root)
        (root / p.MANIFEST).write_bytes(p.encoded(manifest) + b'\n')
        (root / 'plain.js').write_text('changed non-native')
        with self.assertRaises(ValueError):
            p.reseal_after_nested_signing(root)
        (root / 'plain.js').write_text('code')
        (root / 'extra').write_text('new file')
        with self.assertRaises(ValueError):
            p.reseal_after_nested_signing(root)

    def test_frozen_evidence_requires_pnpm_installation_and_lock_receipt(self):
        with self.assertRaises(ValueError):
            p.frozen_evidence(self.root, 'pnpm@12.5.1', '0' * 64)
        (self.root / 'node_modules' / '.pnpm').mkdir(parents=True)
        (self.root / 'node_modules' / '.modules.yaml').write_text('x')
        (self.root / 'node_modules' / '.pnpm' / 'lock.yaml').write_text('lock')
        with self.assertRaises(ValueError):
            p.frozen_evidence(self.root, 'pnpm@12.5.1', '0' * 64)
        with self.assertRaises(ValueError):
            p.frozen_evidence(self.root, 'npm@11', p.digest(self.root / 'node_modules' / '.pnpm' / 'lock.yaml'))
        evidence = p.frozen_evidence(self.root, 'pnpm@12.5.1', p.digest(self.root / 'node_modules' / '.pnpm' / 'lock.yaml'))
        self.assertEqual(evidence['kind'], 'pnpm-frozen-lockfile-install-v1')
        self.assertTrue(evidence['archiveProvenanceVerified'] and evidence['lockfileMatchEstablished'])
        self.assertEqual(evidence['lockSha256'], p.PIN['lockSha256'])

    def test_copy_rejects_escape(self):
        (self.root / 'link').symlink_to('../outside')
        (self.root.parent / 'outside').write_text('outside')
        with self.assertRaises(ValueError):
            p.copy_file(self.root / 'link', self.root.parent / 'copy', self.root)


if __name__ == '__main__':
    unittest.main()
