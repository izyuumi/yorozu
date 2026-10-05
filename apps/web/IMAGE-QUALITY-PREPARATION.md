# Native website media

The earlier public Mac hero supplied820×540 pixels at1198CSS pixels wide,
which was insufficient for a2× display (2396pixels needed). The replacement is
an actual2400×971 native window capture, with its natural aspect preserved.
The Mac is now a supporting overview below the phone-first hero. No original image is upscaled.

## Mac poster

Source: public app source55cb5221, existing synthetic previewThreads/previewChat
fixtures, supported textScale2, task-owned unique disposable demo bundle and
idle client transport. No installed app, provider, host cache, private chats or
other desktop windows are used. On the actual1× display, AppKit constrained
window height; the successful original2400×971 capture is used unchanged.
Later capture geometry attempts did not produce verifiable windows and were
stopped. They contribute no pixels to the published assets. Temporary app-source
shims were restored; app sources and release metadata have no task diff.

`prepare-mac-screenshot.py` rejects inputs below2400pixels and produces lossless
WebP640/820/1280/1920/2400 from the native PNG, preserving aspect and removing
metadata. Responsive srcset/sizes selects enough pixels at desktop2× and mobile.
The2400pixel asset is67,850bytes. Current phone approval still and cleared icon
already supply enough pixels at2× and remain unchanged.

## iPhone recording

Original: retained native Simulator recording from JapaneseStreamingTests,
synthetic offline JapaneseReplyFixture during0.5 rendering validation. Both
fixture and native renderer were included in released0.5 source ddf8d6a4. The
attachment manifest does not record the exact capture commit; no claim of a
recorded production connection or backend execution is made. Selected continuous
seconds6–12 contain only the native sample reply growing to its formatted table.
The launch/home screen is excluded. No privacy redaction or fabricated UI is
needed. Timing is preserved; audio and metadata are removed.

`prepare-iphone-demo.py` rejects undersized/nonportrait sources and prepares
VP9 WebM plus fast-start H.264 MP4 at804×1748/24fps. Both are six seconds.
WebM is233,468bytes; MP4 is111,535bytes. The1206×2622 WebP poster (quality90,145,802bytes) is a
frame at source second9 inside the selected segment. Original SHA256, output
hashes/dimensions/bytes, public fixture paths and boundaries are retained in
`media-provenance.json`. Repository provenance is not part of the public bundle.

## Visitor behavior

The genuine iPhone screenshot renders first. Watch iPhone demo opens an accessible native browser
dialog labeled as an iPhone sample, with Close/Escape and native video controls.
No video or video poster has a source until the visitor opens it. VP9 is preferred,
MP4 is the playback/error fallback, and the genuine poster stays available if
both fail. Closing pauses and unloads video. Same-origin external JavaScript
keeps the existing CSP. Page wording, palette, icon, routes, legal/pairing pages,
download/feed logic, hosting configuration and app releases are preserved.

## Validation

Build and15existing tests passed. Actual isolated headless Chrome at1440/730/390
CSS pixels and2× confirms no overflow/broken images, evergreen copy, navigation,
focus visibility, and sufficient genuine source pixels for the earlier Mac hero. Media
codec/duration/bytes are measured with ffprobe. Native browser playback, fallback,
initial request cost and dialog keyboard behavior passed in6actual headless Chrome cases under the unchanged production CSP, including Close/Escape,3×mobile, MP4-only browser simulation,404fall back and playback-policy refusal. Safari was not run.
No shared browser profile, foreground app input or display/security settings are
changed by website QA. The only publication lane is the authorized existing
website workflow on the isolated branch; do not merge or push main because that
could trigger an app release. No alternative publisher after an approval denial.


## Phone-first correction

The hero now shows the original native1206×2622 XCTest PNG attachment `Japanese reply
 after completion` from iPhone17Pro Simulator at normal3× device scale. This is
`app.screenshot()`, not a video frame, redraw or enlargement. It is an offline
sample conversation; the attachment manifest does not record the exact capture
commit. The native renderer and DEBUG fixture are in the released0.5 source.

`prepare-iphone-screenshot.py` checks native dimensions,8-bit RGB/RGBA and colour
metadata, encodes without resizing, and requires identical decoded RGBA before
writing. This source has an explicit sRGB tag and no ICC profile. Its103KB WebP
preserves every native pixel. The hero wording describes agents and tools on the
Mac reached remotely from an iPhone; it makes no screen-mirroring claim.

The supporting Mac capture remains a2400×971 wide native window from the existing
1× display with supported textScale2. It is not a new larger/Retina-display
capture. At the smaller supporting size it is a decorative overview; adjacent
text explains the host role. All opaque pixels and alpha values in the native
2400WebP equal the original; one partial-alpha edge pixel's RGB differs.

Actual Chrome checks cover phone-first layout, no overflow, first-viewport native
phone visibility and source pixel supply at2× and3×. A compact header install
button remains visible on mobile, and the phone is smaller on short laptop
screens. WebM, MP4, poster, scripts, icons, legal/pairing pages and download/feed
routes are preserved from the prior public source11ce6e63. Safari is not tested.
