#!/bin/sh
# Compile the saved Icon Composer document without regenerating its SVG geometry.
# AppIcon.icon is the artwork authority; Apple's compiler supplies its glass and masks.
set -eu
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
ICON=apps/ios/Resources/AppIcon.icon

# Render the appearance artwork with the same native material settings. Dark and
# tinted PNGs are static artwork previews; system tint is chosen by the user/device.
for APPEARANCE in light dark tinted; do
  VARIANT="$WORK/$APPEARANCE/AppIcon.icon"
  mkdir -p "$WORK/$APPEARANCE"
  cp -R "$ICON" "$VARIANT"
  python3 - "$VARIANT/icon.json" "$APPEARANCE" <<'PY'
import json, sys
from pathlib import Path
path, appearance = Path(sys.argv[1]), sys.argv[2]
icon = json.loads(path.read_text())
if appearance == "dark":
    icon["fill"] = next(x["value"] for x in icon["fill-specializations"] if x["appearance"] == "dark")
elif appearance == "tinted":
    icon["fill"] = {"automatic-gradient": "extended-srgb:0.57647,0.65882,0.67451,1.00000"}
icon.pop("fill-specializations", None)
for group in icon["groups"]:
    for layer in group["layers"]:
        variants = layer["image-name-specializations"]
        selected = next(x for x in variants if x.get("appearance", "light") == appearance)
        layer["image-name-specializations"] = [{"value": selected["value"]}]
path.write_text(json.dumps(icon, indent=2) + "\n")
PY
  mkdir -p "$WORK/$APPEARANCE/compiled"
  xcrun actool "$VARIANT" --compile "$WORK/$APPEARANCE/compiled" \
    --platform macosx --target-device mac --minimum-deployment-target 15.0 \
    --app-icon AppIcon --standalone-icon-behavior all \
    --output-partial-info-plist "$WORK/$APPEARANCE/compiled/Info.plist" \
    --output-format human-readable-text --warnings --errors
  iconutil --convert iconset "$WORK/$APPEARANCE/compiled/AppIcon.icns" \
    --output "$WORK/$APPEARANCE/preview.iconset"
  cp "$WORK/$APPEARANCE/preview.iconset/icon_512x512@2x.png" "docs/icon-$APPEARANCE.png"
done

cp "$WORK/light/compiled/AppIcon.icns" apps/mac/Resources/Yorozu.icns
cp docs/icon-light.png apps/ios/Resources/Assets.xcassets/AppIconImage.imageset/icon-1024.png
echo "Rendered native Mac icon, pairing/widget image, and static appearance artwork previews."
