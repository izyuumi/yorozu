# Website screenshots

Use real native app captures with isolated demo state. Never use personal chats,
files, accounts, desktop icons, or notifications. Preserve the site's availability
wording when refreshing images.

## iPhone 18 Pro

Use the **iPhone 18 Pro** simulator, portrait, for both `iphone-chat.webp` and
`iphone-approval.webp`. Capture at 1206 × 2622 and optimize to 804 × 1748. Use
9:41, full battery and signal, and the light appearance. The real Debug showcase
uses a local no-op transport, so the approval never sends a message.

Apple's **iPhone 18 Pro – Burgundy – Portrait** PNG comes from
[Apple Design Resources](https://developer.apple.com/design/resources/),
[official download](https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-18.dmg).
The original bezel is 1350 × 2760; its transparent 1206 × 2622 screen starts at
(72, 69). `iphone-18-pro-bezel.webp` preserves the full artwork and alpha. CSS
places each native screenshot behind it, with no added device shadow or tilt.
The project owner's September 24, 2026 license authorization covers this resource.

Use temporary `ChatModel` showcase fixtures, restoring source after capture:

- Pinned thread: **Moon picnic club**, preview “Snacks packed. Telescope optional.”
- Other threads: “Emergency snack council” / “The biscuits have a quorum.”,
  “Name the houseplants” / “Fern needs a surname.”, and “Weekend side quest” /
  “Find the best neighborhood bakery.”
- Chat (`-yorozuShowcase chat`): “Plan a moon-viewing picnic for four. Tiny budget,
  big moon energy.” Reply starts “**Moon picnic: launch plan.** No rocket required.”
  Use a Cargo/Budget table: Rice balls × 4 / ¥800, Dango to share / ¥500,
  Warm tea / ¥300. Follow with “**Total: ¥1,600.** The moon provides the lighting
  for free.” and three bullets: “Meet at the park at 18:30.”, “Bring a blanket and
  four mugs.”, “Cloudy? Indoor planetarium: one lamp, one biscuit.” The final user
  message is “Add one emergency cookie per person.”
- Approval (`-yorozuShowcase approval`): “Invite the Moon Picnic Club. Tell them to
  bring a mug and their best moon joke.” Use a `send-message` card targeting
  “Moon Picnic Club”, operation `send`, content “Saturday, 18:30 at the park.
  Bring a mug and a moon joke. We have dango. The moon has no snacks.”,
  consequence “Sends one message to the group.” Never approve the fixture.

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
