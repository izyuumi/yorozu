#!/usr/bin/env python3
"""Prepare lossless responsive WebP files from an original native Mac capture.

This deliberately rejects the website's existing low-resolution image. Obtain a
new native capture with the documented demo state before calling this script.
It never upscales an input, redraws the interface, or publishes anything.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path, help="Original native-capture PNG, at least 2400 pixels wide")
parser.add_argument("--output", type=Path, required=True, help="Local directory for the prepared assets")
args = parser.parse_args()
source = args.source.resolve()
if source.suffix.lower() != ".png":
    parser.error("Use the original native PNG; recompressing the existing WebP cannot recover detail.")
info = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(source)], text=True)
width = int(re.search(r"pixelWidth: (\d+)", info).group(1))
height = int(re.search(r"pixelHeight: (\d+)", info).group(1))
if width < 2400:
    parser.error(f"Native source is only {width} pixels wide; need at least 2400. No assets written.")
if abs(width / height - 820 / 540) > 0.002:
    parser.error("Capture the existing demo with its 820:540 aspect ratio. No cropping or stretched screenshots.")
encoder = shutil.which("cwebp")
if encoder is None:
    parser.error("cwebp is required; no assets written.")

output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
assets = []
with tempfile.TemporaryDirectory(prefix="native-webp-", dir=output) as temporary:
    stage = Path(temporary)
    for target_width in [640, 820, 1280, 1920, 2400]:
        assert target_width <= width
        name = "mac-demo-light.webp" if target_width == 820 else f"mac-demo-light-{target_width}.webp"
        target = stage / name
        subprocess.run([
            encoder, "-quiet", "-lossless", "-z", "9", "-metadata", "none",
            "-resize", str(target_width), "0", str(source), "-o", str(target)
        ], check=True)
        measured = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(target)], text=True)
        actual_width = int(re.search(r"pixelWidth: (\d+)", measured).group(1))
        assert actual_width == target_width
        assets.append({"file": name, "width": target_width, "bytes": target.stat().st_size,
                       "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
    for asset in assets:
        shutil.move(str(stage / asset["file"]), output / asset["file"])

manifest = {"source": str(source), "source_width": width, "source_height": height,
            "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "encoding": "Lossless WebP from original PNG; downsampling only; metadata removed",
            "assets": assets, "publication": "Not performed",
            "provenance_requirement": "Operator must retain proof that the input is a genuine native capture, not an upscaled export."}
(output / "mac-screenshot-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, indent=2))
