# Website screenshots

Use real native app captures with isolated demo state. Never use personal chats,
files, accounts, desktop icons, or notifications. Preserve the site's availability
wording when refreshing images.

## Mac

`mac-demo-light.webp` and `mac-demo-dark.webp` show the same fictional conversation.
Use the existing `-yorozuShowcase threads -yorozuScene plain` harness with
`-yorozuAppearance light|dark -yorozuWindowSize 820x540` and a throwaway
`YOROZU_STATE_DIR`. Build a separate Debug bundle with a unique bundle identifier.
Temporary capture fixtures must not change the shipped application.

Pinned thread: **Operation: touch grass**. Preview: “A tiny adventure. Home by nap time.”
Other fictional threads include “Emergency snack council” (“The biscuits have a
quorum.”), “Name the houseplants” (“Fern definitely needs a surname.”), and
“Weekend side quest” (“Find the best neighborhood bakery.”).

Prompt: “Plan a tiny Saturday adventure. Budget: ¥2,000. Energy: house cat.”

Reply:

> **Operation: touch grass.** A very small expedition.
>
> | Time | Mission | Budget |
> | --- | --- | --- |
> | 10:00 | Coffee and a pastry | ¥700 |
> | 10:30 | Park stroll. Inspect one duck. | Free |
> | 11:30 | Noodles before heading home | ¥900 |
>
> **Total: ¥1,600.** ¥400 held in the emergency snack fund.
>
> Rain plan: swap the park for a bookstore. Same adventure, fewer wet socks.

The backdrop is the actual macOS default wallpaper, sourced on macOS 27.2 from
`/System/Library/CoreServices/DefaultDesktop.heic`, resolving to
`/System/Library/Wallpapers/.default/DefaultAerial.heic` (Golden Gate).
`mac-default-wallpaper.webp` is a 1440px-wide optimized copy. CSS places the native
window over it with 7% padding; the user's desktop is never captured.

## iPhone Duo

Capture fully open landscape with two columns, keyboard dismissed, and New session
at lower right. Use the same fictional dinner plan in light and dark. Current
native capture is 2853 × 2007, optimized to 1440 × 1013. Build with Xcode 27.1 or
newer so the Duo-specific toolbar placement is represented correctly.

`iphone-duo-bezel.webp` is Apple's **iPhone Duo – Night Sky – Inner Open Landscape**
PNG from [Apple Design Resources](https://developer.apple.com/design/resources/),
[official download](https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-Duo.dmg).
The project owner accepted the Apple Design Resources license on September 24,
2026. The original bezel is 3093 × 2247 with a transparent 2853 × 2007 screen at
(120, 120). Preserve its proportions. CSS aligns the screenshot behind the bezel;
do not redraw, crop, add shadows to, or otherwise modify the device artwork.

## Refresh and verify

Refresh every screenshot referenced by the website after a newly merged release,
including the iPhone chat and approval captures. Reuse the existing showcase
harnesses. Optimize WebP files, retain image dimensions and descriptive alt text,
then inspect desktop/mobile and light/dark. Run `node --test apps/web/tests/*.test.mjs`.
The local Codex automation checks every six hours, skips unchanged releases, and
publishes only after checks pass. Release v0.4.0 is its initial baseline.
