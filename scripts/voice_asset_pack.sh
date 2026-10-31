#!/bin/sh
# Builds VoiceModel.aar, the Apple-hosted asset pack iPhone and iPad download for voice input, from the
# pinned Hugging Face revision in VoiceModel.swift (keep the revision, names and hashes in sync).
# Upload the result with xcrun altool --upload-asset-pack (docs/release.md); the pack ID must match VoiceModel.packID.
set -eu
OUT=${1:?usage: scripts/voice_asset_pack.sh <output directory>}
REVISION=fcfae9027c00a6f3f872c48a841cfeb77e2b5a1c
mkdir -p "$OUT/files"
cd "$OUT"
while read -r name sha; do
    [ "$(shasum -a 256 "files/$name" 2>/dev/null | cut -d' ' -f1)" = "$sha" ] && continue
    curl -fL -C - -o "files/$name" "https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/resolve/$REVISION/$name"
    [ "$(shasum -a 256 "files/$name" | cut -d' ' -f1)" = "$sha" ] || { echo "SHA-256 mismatch: $name" >&2; exit 1; }
done <<HASHES
LFM3-Audio-2B-Q4_K_M.gguf 9a773289bd321ed879cd3a76545f6aca506e403851a45fb315420aee45625be2
mmproj-LFM3-Audio-2B-Q8_0.gguf 26601e904245a85bd8f3cf320a629e897cfc01c1d09369e8b4fd951f13024d3e
HASHES
cat > Manifest.json <<JSON
{
    "assetPackID": "VoiceModel",
    "downloadPolicy": { "onDemand": {} },
    "fileSelectors": [
        { "file": "LFM3-Audio-2B-Q4_K_M.gguf" },
        { "file": "mmproj-LFM3-Audio-2B-Q8_0.gguf" }
    ],
    "platforms": ["iOS"],
    "sourceRoot": "files"
}
JSON
xcrun ba-package Manifest.json -o "$PWD/VoiceModel.aar"
echo "$OUT/VoiceModel.aar"
