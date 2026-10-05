#!/usr/bin/env python3
"""Verify official standalone archive against the prepared runtime; never execute it."""
import argparse
import ast
import importlib.util
import json
from pathlib import Path
import re
import tarfile
import tempfile

spec = importlib.util.spec_from_file_location('packager', Path(__file__).with_name('package-hermes-runtime.py'))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
ARCHIVE_SHA = '9e01f63bbb08576cd9c8bc2d0564d098cb30c8453a0cd4bcf6aef458f6d2a147'
URL = 'https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.13.16%2B20261003-aarch64-apple-darwin-install_only_stripped.tar.gz'
SYSCONFIG = 'lib/python3.13/_sysconfigdata__darwin_darwin.py'


def literal_config(path):
    body = ast.parse(path.read_text()).body
    if len(body) != 1 or not isinstance(body[0], ast.Assign) or len(body[0].targets) != 1 or not isinstance(body[0].targets[0], ast.Name) or body[0].targets[0].id != 'build_time_vars':
        p.fail('sysconfig must contain only a literal build_time_vars assignment')
    return ast.literal_eval(body[0].value)


def derived_config(original, prefix):
    values = {}
    for key, value in original.items():
        if isinstance(value, str):
            value = ' '.join(value.split()).replace('\\', '\\\\')
            value = re.sub(r'(?<!\S)/install(?=/|\s|$)', lambda _: prefix, value)
            if key in {'CC', 'LINKCC', 'BLDSHARED', 'LDSHARED'}:
                value = value.replace('clang', 'cc')
            if key in {'CXX', 'LDCXXSHARED'}:
                value = value.replace('clang++', 'c++')
            if key == 'AR':
                value = 'ar'
        values[key] = value
    values['PYTHON_BUILD_STANDALONE'] = 1
    return values


def verify(archive, prepared, pin):
    if p.digest(archive) != ARCHIVE_SHA:
        p.fail('Python archive differs from official release asset digest')
    with tempfile.TemporaryDirectory(prefix='hermes-python-archive-') as temporary:
        with tarfile.open(archive) as stream:
            # digest first, extraction second; Python data filter rejects escape,
            # device nodes and unsafe links; source is the pinned official asset.
            stream.extractall(temporary, filter='data')
        original = Path(temporary) / 'python'
        before, after = p.python_inventory(original), p.python_inventory(prepared)
        if p.digest(prepared / 'bin/python3.13') != pin['pythonBinarySha256'] or p.tree_digest(after) != pin['pythonTreeSha256']:
            p.fail('Prepared Python differs from committed input pin')
        if [r for r in before if r['path'] != SYSCONFIG] != [r for r in after if r['path'] != SYSCONFIG]:
            p.fail('Python archive differs beyond explicit sysconfig derivation')
        if derived_config(literal_config(original / SYSCONFIG), str(prepared)) != literal_config(prepared / SYSCONFIG):
            p.fail('Python sysconfig derivation differs')
        return {'url': URL, 'sha256': ARCHIVE_SHA, 'size': archive.stat().st_size,
                'officialRuntimeTreeSha256': p.tree_digest(before),
                'preparedRuntimeTreeSha256': p.tree_digest(after), 'binarySha256': pin['pythonBinarySha256'],
                'runtimeRows': len(after), 'unchangedRows': len(after)-1,
                'sysconfig': {'path': SYSCONFIG, 'originalSha256': p.digest(original/SYSCONFIG),
                              'preparedSha256': p.digest(prepared/SYSCONFIG), 'literalOnly': True,
                              'derivation': 'Whitespace normalization, backslash escaping, install-prefix relocation, system compiler names, PYTHON_BUILD_STANDALONE=1; exact literal dictionary comparison'},
                'verified': True, 'runtimeExecuted': False}


def main():
    a = argparse.ArgumentParser(description=__doc__)
    a.add_argument('--archive', type=Path, required=True)
    a.add_argument('--prepared-python', type=Path, required=True)
    a.add_argument('--pin', type=Path, required=True)
    args = a.parse_args()
    print(json.dumps(verify(args.archive, args.prepared_python.resolve(), json.loads(args.pin.read_text())), indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
