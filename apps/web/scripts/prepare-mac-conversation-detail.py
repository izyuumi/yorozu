#!/usr/bin/env python3
"""Crop authentic native Mac screenshot pixels without resizing or redrawing."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
source = args.source.resolve()
expected = '4265fa995de78e7233b00d07f0ccb754a30e27653e9299242577ce7ddee18478'
if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
    parser.error('Use the retained authentic2400x971 native PNG; no asset written.')
# Complete final assistant paragraph, user reply and native composer, without empty desktop space.
x, y, width, height = 975, 620, 720, 351
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
target = output / 'mac-conversation-detail.webp'
with tempfile.TemporaryDirectory() as temporary:
    encoded = Path(temporary) / target.name
    subprocess.run(['cwebp', '-quiet', '-lossless', '-exact', '-z', '9', '-metadata', 'icc',
                    '-crop', str(x), str(y), str(width), str(height), str(source), '-o', str(encoded)], check=True)
    base = ['ffmpeg', '-v', 'error', '-i']
    end = ['-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-']
    original_pixels = subprocess.check_output(base + [str(source), '-vf', f'crop={width}:{height}:{x}:{y}'] + end)
    encoded_pixels = subprocess.check_output(base + [str(encoded)] + end)
    if original_pixels != encoded_pixels:
        parser.error('Decoded native crop differs; no asset written.')
    target.write_bytes(encoded.read_bytes())
print(json.dumps({'sourceSHA256': expected, 'sourceDimensions': [2400, 971],
                  'crop': {'x': x, 'y': y, 'width': width, 'height': height},
                  'file': target.name, 'bytes': target.stat().st_size,
                  'sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                  'sourceCropRGBA_MD5': hashlib.md5(original_pixels).hexdigest(),
                  'outputRGBA_MD5': hashlib.md5(encoded_pixels).hexdigest(),
                  'identicalNativeCropPixels': True,
                  'transformation': 'Exact native crop, lossless WebP, ICC preserved if present; no resizing/upscaling/redraw'}, indent=2))
