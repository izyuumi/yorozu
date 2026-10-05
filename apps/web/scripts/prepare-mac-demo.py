#!/usr/bin/env python3
"""Encode a short genuine native Mac recording as WebM and MP4, never upscale."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path, help="Original window-only native recording")
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--start", type=float, default=0)
parser.add_argument("--duration", type=float, default=6)
args = parser.parse_args()
source = args.source.resolve()
probe = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
    "stream=codec_name,width,height:format=duration", "-of", "json", str(source)
]))
stream = probe["streams"][0]
if stream["width"] < 2400:
    parser.error("Need an original native recording at least 2400 pixels wide; no outputs written.")
if abs(stream["width"] / stream["height"] - 820 / 540) > 0.002:
    parser.error("Recording must preserve the current Mac window aspect ratio; no cropping or stretching.")
if not (0 <= args.start and 0 < args.duration <= 8 and
        args.start + args.duration <= float(probe["format"]["duration"])):
    parser.error("Choose an existing segment of at most eight seconds.")
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
assets = []
with tempfile.TemporaryDirectory(prefix="native-video-", dir=output) as temporary:
    stage = Path(temporary)
    for extension, settings in [
        ("webm", ["-c:v", "libvpx-vp9", "-crf", "26", "-b:v", "0", "-row-mt", "1", "-cpu-used", "3"]),
        ("mp4", ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-movflags", "+faststart"])
    ]:
        name = f"mac-demo.{extension}"
        target = stage / name
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", str(args.start),
            "-i", str(source), "-t", str(args.duration), "-an", "-map_metadata", "-1",
            "-vf", "fps=24,scale=1920:-2:flags=lanczos", "-pix_fmt", "yuv420p", *settings, str(target)
        ], check=True)
        info = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
            "stream=codec_name,width,height,avg_frame_rate:format=duration,size", "-of", "json", str(target)
        ]))
        assets.append({"file": name, "bytes": target.stat().st_size,
                       "sha256": hashlib.sha256(target.read_bytes()).hexdigest(), "probe": info})
    for asset in assets:
        (stage / asset["file"]).replace(output / asset["file"])
manifest = {"source": str(source), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "source_probe": probe, "assets": assets, "audio": "Removed", "publication": "Not performed",
            "integration": "User-initiated playback only; preload=none; sharp responsive still first; MP4/static fallback",
            "provenance_requirement": "Retain native capture evidence; an enlarged low-resolution recording is not acceptable."}
(output / "mac-video-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, indent=2))
