# Image and native demo preparation

This is a **local preparation, not a publishable image fix yet**. The public site's
Mac capture is 820 × 540. It renders at 1198 CSS pixels at the maximum desktop
size, requiring 2396 source pixels on a 2× screen. No matching larger original
PNG or native Mac recording was found in the retained sources. Do not upscale
the existing WebP or replace it with a different screenshot under the same caption.

The iPhone approval image is 804 × 1748, displayed at 292 CSS pixels wide inside
its border. It supplies enough pixels at 2×. The cleared icon is 512 × 512 and
needs no replacement. At 3× the phone would benefit from its genuine 1206-pixel
original, if the original matching demo capture can be obtained.

## Required original capture

Use `docs/website-screenshots.md` and the actual native app showcase, with the
same fictional Saturday outing. Keep the application, state directory and bundle
identifier isolated from the installed app. Retain a native PNG and a short
window-only native recording, both at least 2400 pixels wide with the existing
820:540 aspect ratio. A 1230 × 810 point native window captured at 2× gives
2460 × 1620 pixels. Record genuine interaction rather than animating a still.

Keep capture provenance: exact source commit, native bundle, window size,
backing scale, original file hashes and scene. Never include personal chats,
desktop windows or notifications. Do not alter permissions or authentication.
Use the released foreground lease and restore the user's Teams/Icon Composer
state after any native capture. No native capture was performed by this task.

## Prepared converters

```sh
python3 apps/web/scripts/prepare-mac-screenshot.py ORIGINAL.png --output LOCAL_ASSETS
python3 apps/web/scripts/prepare-mac-demo.py ORIGINAL.mov --output LOCAL_ASSETS
```

The still converter generates lossless WebP at 640, 820, 1280, 1920 and 2400
pixels, with the 820-pixel fallback named `mac-demo-light.webp`. Every derivative
comes from the same genuine PNG. It rejects a source smaller than 2400 pixels;
none of its operations upscale an image.

The video converter trims an existing segment to at most eight seconds, removes
audio and metadata, and prepares a VP9 WebM plus H.264 MP4 fallback at 24fps.
It probes dimensions, codec, duration and byte count, and records source/output
hashes. It rejects an undersized source. Candidate byte size and visual detail
must be measured on the genuine recording before claiming a load-time benefit.

## Proposed public integration after capture

Apply the prepared `ready-after-native-capture.patch` only after all five still
files exist. Its `srcset` and `sizes` match the current fluid container, preserving
the page's layout, intrinsic aspect ratio, palette, wording and alt text.

Offer the WebM through user-initiated native video controls with `playsinline`
and `preload="none"`, a sharp still poster, and MP4/static fallback. Keep the
responsive still visible initially; no autoplay or initial video download.
Any needed JavaScript must remain a same-origin external file under the current
CSP. Do not turn the icon or other static assets into video.

Before publication: inspect the actual native content; build and run the website
tests; verify source selection at desktop/mobile and 1×/2×/3×; measure bytes,
duration and codec; verify WebM and MP4 playback/fallback and no initial video
requests. Preserve routes, feeds, legal/pairing pages, hosting and app releases.
Submit the authorized website-only deployment through the existing official
workflow's normal approval review once the candidate passes. Do not route around
an approval rejection.

## Completed checks and remaining limit

The served asset hashes and real 2× browser measurements are recorded under
`task-10/image-quality-evidence` and `image-quality-retina-diagnosis`. Converter
syntax and lossless downsampling were checked. The undersized native PNG and
portrait recording are correctly rejected before creating output directories.
The fully encoded Mac assets, improved poster, candidate playback and final
visual-quality checks remain blocked on genuine original capture files.
