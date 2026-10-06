#!/usr/bin/env python3
"""No downloads/providers. Filesystem/archive rejection tests for offline assembler."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import os

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

    def test_copy_rejects_escape(self):
        (self.root / 'link').symlink_to('../outside')
        (self.root.parent / 'outside').write_text('outside')
        with self.assertRaises(ValueError):
            p.copy_file(self.root / 'link', self.root.parent / 'copy', self.root)


if __name__ == '__main__':
    unittest.main()
