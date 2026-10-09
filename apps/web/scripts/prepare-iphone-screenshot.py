#!/usr/bin/env python3
"""Encode and verify a genuine native iPhone PNG without resizing its pixels."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
source = args.source.resolve()
data = source.read_bytes()
if source.suffix.lower() != '.png' or data[:8] != b'\x89PNG\r\n\x1a\n':
    parser.error('Use the original native PNG; no output written.')
chunks = {}
position = 8
while position < len(data):
    length = struct.unpack('>I', data[position:position + 4])[0]
    kind = data[position + 4:position + 8]
    chunks[kind] = data[position + 8:position + 8 + length]
    position += length + 12
width, height, depth, colour, _, _, _ = struct.unpack('>IIBBBBB', chunks[b'IHDR'])
if (width, height) != (1206, 2622) or depth != 8 or colour not in (2, 6):
    parser.error('Use the original native1206x2622, 8-bit RGB/RGBA PNG; no output written.')
if b'iCCP' not in chunks and b'sRGB' not in chunks:
    parser.error('Source must have an explicit sRGB tag or ICC profile; no output written.')
metadata = 'icc' if b'iCCP' in chunks else 'none'
def rgba(path):
    return subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(path), '-frames:v', '1',
                                    '-f', 'rawvideo', '-pix_fmt', 'rgba', '-'])
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
target = output / 'iphone-native-reply-1206.webp'
with tempfile.TemporaryDirectory() as temporary:
    encoded = Path(temporary) / target.name
    subprocess.run(['cwebp', '-quiet', '-lossless', '-exact', '-z', '9', '-metadata', metadata,
                    str(source), '-o', str(encoded)], check=True)
    source_pixels, encoded_pixels = rgba(source), rgba(encoded)
    if source_pixels != encoded_pixels:
        parser.error('Decoded RGBA differs from native source; no asset written.')
    target.write_bytes(encoded.read_bytes())
print(json.dumps({'source_name': source.name, 'source_sha256': hashlib.sha256(data).hexdigest(),
                  'source_dimensions': [width, height], 'source_bit_depth': depth,
                  'colour': 'ICC preserved' if metadata == 'icc' else 'Source explicitly sRGB; WebP displays as sRGB',
                  'output': target.name, 'bytes': target.stat().st_size,
                  'sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                  'sourceRGBA_MD5': hashlib.md5(source_pixels).hexdigest(),
                  'encodedRGBA_MD5': hashlib.md5(encoded_pixels).hexdigest(),
                  'identicalNativeDecodedPixels': True,
                  'encoding': 'Exact lossless native pixels; no resize; private metadata removed'}, indent=2))
