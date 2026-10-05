"""Offline archive/derivation tests. All payloads are inert owned fixtures."""
import base64
import csv
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


w = load('hermes-public-archive-provenance')
p = load('hermes-python-archive-provenance')


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def wheel(self, tamper=False):
        site = self.root / 'site'
        metadata = site / 'example-1.0.dist-info'
        metadata.mkdir(parents=True)
        wheel = b'Wheel-Version: 1.0\nTag: py2-none-any\nTag: py3-none-any\n'
        (metadata / 'WHEEL').write_bytes(wheel)
        (site / 'example.py').write_bytes(b'fixture = True\n')
        target = self.root / 'example-1.0-py2.py3-none-any.whl'
        record = io.StringIO()
        writer = csv.writer(record)
        entries = {'example.py': b'fixture = True\n', 'example-1.0.dist-info/WHEEL': wheel}
        for name, data in entries.items():
            writer.writerow([name, 'sha256=' + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).decode().rstrip('='), len(data)])
        writer.writerow(['example-1.0.dist-info/RECORD', '', ''])
        with zipfile.ZipFile(target, 'w') as z:
            for name,data in entries.items():
                z.writestr(name, b'tamper' if tamper and name=='example.py' else data)
            z.writestr('example-1.0.dist-info/RECORD', record.getvalue())
        package = {'name':'example','version':'1.0','wheels':[{'url':'https://files.pythonhosted.org/'+target.name,'hash':'sha256:'+w.sha(target.read_bytes())}]}
        return metadata, package, self.root, site

    def test_compressed_universal_tags_and_wheel_records(self):
        with patch.object(w.subprocess, 'run') as run:
            value = w.inspect_wheel(self.wheel())
        run.assert_not_called()
        self.assertEqual(value['status'], 'verified')
        self.assertEqual(value['installedFilesEqual'], 2)

    def test_archive_hash_checked_before_parsing_zip(self):
        item = self.wheel()
        item[1]['wheels'][0]['hash'] = 'sha256:' + '0'*64
        with patch.object(w.zipfile, 'ZipFile') as parse:
            with self.assertRaisesRegex(ValueError,'frozen lock'):
                w.inspect_wheel(item)
        parse.assert_not_called()

    def test_regenerated_archive_hash_cannot_hide_bad_wheel_record(self):
        with self.assertRaisesRegex(ValueError, 'Wheel RECORD mismatch'):
            w.inspect_wheel(self.wheel(True))

    def test_modified_installed_module_remains_blocked(self):
        item = self.wheel()
        (item[3]/'example.py').write_bytes(b'tampered')
        result = w.inspect_wheel(item)
        self.assertEqual(result['status'], 'blocked')
        self.assertEqual(result['mismatches'], ['example.py'])

    def test_sysconfig_must_be_literal_assignment_without_execution(self):
        f = self.root/'config.py'
        f.write_text('build_time_vars = {"prefix": "/install"}\n')
        self.assertEqual(p.literal_config(f), {'prefix':'/install'})
        f.write_text('build_time_vars = {"prefix": "/install"}\nraise RuntimeError("never execute")\n')
        with self.assertRaisesRegex(ValueError,'literal'):
            p.literal_config(f)

    def test_sysconfig_derivation_is_bounded(self):
        self.assertEqual(p.derived_config({'prefix':'/install','INSTALL':'/usr/bin/install -c','CC':'clang','OTHER':'keep clang'}, '/fixture'),
                         {'prefix':'/fixture','INSTALL':'/usr/bin/install -c','CC':'cc','OTHER':'keep clang','PYTHON_BUILD_STANDALONE':1})

    def test_python_archive_digest_precedes_extraction(self):
        f=self.root/'bad.tar.gz'
        f.write_bytes(b'not a tar')
        with patch.object(p.tarfile,'open') as extract:
            with self.assertRaisesRegex(ValueError,'official release'):
                p.verify(f,self.root,{})
        extract.assert_not_called()


if __name__ == '__main__':
    unittest.main()
