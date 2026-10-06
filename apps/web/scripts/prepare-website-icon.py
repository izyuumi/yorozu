#!/usr/bin/env python3
"""Prepare website sizes from the approved Icon Composer PNG export."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import struct
import zlib
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
source = args.source.resolve()
expected = '9e72b449b456cd3479fa04da23052debd62912cf1310d5df974e8519bdd9e0eb'
if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
    parser.error('Use the selected approved1024px Icon Composer export; no output written.')
output = args.output.resolve()
records = []
temporary = tempfile.TemporaryDirectory()
prepared = []
for relative, size in [('assets/icon.png', 512), ('favicon.png', 64), ('apple-touch-icon.png', 180)]:
    target = Path(temporary.name) / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['/usr/bin/sips', '-z', str(size), str(size), str(source), '--out', str(target)],
                   check=True, stdout=subprocess.DEVNULL)
    # Preserve encoded pixels while removing export metadata and explicitly tagging sRGB.
    data = target.read_bytes()
    kept, position = [], 8
    colour = {}
    while position < len(data):
        length = struct.unpack('>I', data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + length]
        if kind in (b'gAMA', b'cHRM'):
            colour[kind] = payload
        if kind in (b'IHDR', b'gAMA', b'cHRM', b'IDAT', b'IEND', b'PLTE', b'tRNS', b'sRGB'):
            kept.append((kind, data[position:position + length + 12]))
        position += length + 12
    if colour.get(b'gAMA') != struct.pack('>I', 45455) or colour.get(b'cHRM') != struct.pack('>8I', 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000):
        parser.error('Native resized output colour metadata is not sRGB; stop without publishing.')
    if not any(kind == b'sRGB' for kind, _ in kept):
        payload = b'\x00'
        tag = struct.pack('>I', len(payload)) + b'sRGB' + payload + struct.pack('>I', zlib.crc32(b'sRGB' + payload))
        kept.insert(1, (b'sRGB', tag))
    sanitized = data[:8] + b''.join(chunk for _, chunk in kept)
    # IDAT chunks are byte-identical; only ancillary metadata changed.
    target.write_bytes(sanitized)
    prepared.append((output / relative, sanitized))
    records.append({'file': relative, 'colour': 'Explicit sRGB with canonical gamma/chromaticities',
                    'exportMetadataRemoved': True,  'dimensions': [size, size], 'bytes': target.stat().st_size,
                    'sha256': hashlib.sha256(target.read_bytes()).hexdigest()})
for destination, data in prepared:
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
temporary.cleanup()
print(json.dumps({'sourceName': source.name, 'sourceSHA256': expected, 'sourceDimensions': [1024, 1024],
                  'sourceColour': 'OriginalPNG explicitly sRGB,8-bitRGBA,noICC',
                  'transformation': 'Native sips downsampling only; no new design, crop or enlargement',
                  'outputs': records}, indent=2))
