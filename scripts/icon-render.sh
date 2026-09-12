#!/bin/sh
# Re-render everything downstream of the app icon artwork.
#
#   ./scripts/icon-render.sh
#
# scripts/icon-art.mjs owns the drawing and writes the layer SVGs that
# apps/ios/Resources/AppIcon.icon composes. Xcode renders that bundle itself for iOS, but
# three places need a flat raster instead, and they are what this script produces:
#
#   - apps/ios/Resources/Assets.xcassets/AppIconImage.imageset, which the pairing screen
#     shows (an app icon is not readable as an Image asset, so it needs its own copy)
#   - apps/mac/Resources/Yorozu.icns, because scripts/build-mac.sh assembles its bundle by
#     hand and has no asset catalog to compile the .icon into
#   - docs/icon-{light,dark,tinted}.png, for reviewing the three appearances
#
# The outputs are committed: this runs when the artwork changes, not on every build.
set -eu
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# macOS has rasterised SVG through ImageIO since Ventura, so the whole renderer is an
# NSImage draw. Beats making the repo depend on librsvg or a headless browser for this.
cat > "$WORK/svgpng.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
guard let image = NSImage(contentsOfFile: args[1]) else { fatalError("cannot read \(args[1])") }
let size = Int(args[3])!
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
SWIFT
# env -u SDKROOT: an SDKROOT inherited from the shell points swiftc at the wrong SDK.
env -u SDKROOT swiftc -O "$WORK/svgpng.swift" -o "$WORK/svgpng"

node scripts/icon-art.mjs "$WORK"

for APPEARANCE in light dark tinted; do
  "$WORK/svgpng" "$WORK/icon-$APPEARANCE.svg" "docs/icon-$APPEARANCE.png" 1024
done

cp docs/icon-light.png apps/ios/Resources/Assets.xcassets/AppIconImage.imageset/icon-1024.png

# iconutil wants every size spelled out, including the @2x names, or it refuses the set.
ICONSET="$WORK/Yorozu.iconset"
mkdir -p "$ICONSET" apps/mac/Resources
for SIZE in 16 32 128 256 512; do
  "$WORK/svgpng" "$WORK/icon-macos.svg" "$ICONSET/icon_${SIZE}x${SIZE}.png" "$SIZE"
  "$WORK/svgpng" "$WORK/icon-macos.svg" "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" "$((SIZE * 2))"
done
iconutil --convert icns --output apps/mac/Resources/Yorozu.icns "$ICONSET"

echo "rendered docs/icon-*.png, AppIconImage.imageset and apps/mac/Resources/Yorozu.icns"
