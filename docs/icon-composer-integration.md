# Existing Yorozu Icon Composer mark

The saved Yorozu mark is the chosen app identity for 0.6 and later unless the user changes
that choice. The 0.6 candidate uses the document from signed commit
`970801337a25d47dc39e1c107f41985715edd9f3` (draft PR 301). The authoritative document is
`apps/ios/Resources/AppIcon.icon`: its four layers use twelve saved appearance SVGs,
with crossed loops and a vermilion center. This integration copies the document and
selected compiled assets directly from that Git object. It creates no new artwork and
does not regenerate the SVG geometry.

| Consumer | Existing source or output | Candidate use |
| --- | --- | --- |
| iPhone and iPad app | `apps/ios/Resources/AppIcon.icon` | Tuist includes the document; Xcode compiles `AppIcon` for iOS 18+ |
| Apple Watch app | The same `.icon`, with watchOS circle support | The Watch target compiles `AppIcon` for watchOS 11+ |
| Mac app | `apps/mac/Resources/Yorozu.icns` | Shipping and development bundle scripts copy the exact native-compiled ICNS from the selected commit |
| Pairing screen and widget | `apps/ios/Resources/Assets.xcassets/AppIconImage.imageset/icon-1024.png` | The exact default native artwork raster from the selected commit |
| Default/dark/mono reference images | `docs/icon-light.png`, `icon-dark.png`, `icon-tinted.png` | Exact selected appearance artwork references, distinct from fresh platform compilation evidence |

`scripts/icon-render.sh` now uses the saved `.icon` as its only artwork input. Temporary
copies select its existing appearance layers for reference exports; default Mac ICNS and
the pairing/widget raster come from Apple's native `actool` output. The old gold-art
generator is removed. This scoped renderer writes no website/public assets. Version files,
0.5/public release branches, tags and update feeds are unchanged.

The default native compiler outputs can verify the actual saved artwork at small and large
Mac/iOS sizes. Dark and mono reference PNGs are static appearance artwork; they do not
prove every system-selected tint or installed-device treatment. The `.icon` contains
declared dark/tinted layer specializations and square/watch circle platform support.

The authorized task-9 receipt records that the Icon Composer computer-use connection
closed during saving. This work therefore does not claim the final interactive
Default/Dark/Mono review or Composer save completed. A bounded native open-and-Save attempt
on 2026-10-05 timed out during opening, before document identity verification or Save. The
editable document and exports remain byte-identical to the selected source afterward.
Filesystem save and native compiler verification are established separately from
interactive Composer Save. Installed Mac/iPhone/Watch appearance and arbitrary system tints
remain device acceptance work. This integration makes no trademark or original-art
clearance claim.

The source document tree at the selected commit is
`d9ed6b6c3d267206a5b1e5a9fc34f14645e164cf`. Its thirteen files are readable and identical
to both that Git object and the authorized task-9 `YorozuMark.icon` document. The exact
selected exports have these SHA-256 hashes:

| Saved export | SHA-256 |
| --- | --- |
| `apps/mac/Resources/Yorozu.icns` | `2603a970be516734cd779768e50fae2e4716a8df3be4385b129d5841a9ba7219` |
| `AppIconImage.imageset/icon-1024.png` and `docs/icon-light.png` | `9e72b449b456cd3479fa04da23052debd62912cf1310d5df974e8519bdd9e0eb` |
| `docs/icon-dark.png` | `3b475b66c711844bb128b22be68225abd069eec5a186d12afd0a2491364096dc` |
| `docs/icon-tinted.png` | `0eab18874ed397465c85c7970064eee9f22a64331347f943ba6bd47b6d43c54a` |

Fresh Xcode 27 native compilation passes for macOS 15, iOS 18 and watchOS 11 deployment
targets. The fresh Mac ICNS is byte-identical to the selected export. Catalog inspection
records default/dark/tintable layers for Mac and iOS, and a default Watch icon stack;
this is compiler evidence, not interactive Composer Save or installed-system appearance
evidence. Local build receipts live in the task's ignored `.build/icon-proof` directory.
