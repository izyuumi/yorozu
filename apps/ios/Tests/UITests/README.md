# Composer keyboard regression

Japanese reply glyph geometry runs in `YorozuRenderingTests` on iOS, because the Mac
package tests use SwiftUI instead of the phone's selectable TextKit reply. After generating
the workspace, use `xcodebuild test -workspace apps/ios/Yorozu.xcworkspace
-scheme YorozuRenderingTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
The UI-test script runs it at normal and maximum accessibility text size. Its matrix covers
all reply fonts, 180/280-point proposals, long Japanese, mixed Latin/emoji/inline code,
explicit line breaks, headings, ordered/unordered lists, tables, code blocks, and rules.
Core Text glyph outlines must fit inside the measured reply without intersecting adjacent
lines. The pre-fix block separator uses an unstyled newline and fails this check.

For real Simulator captures without a host/account, launch with `-yorozuShowcase japanese`
or `-yorozuShowcase japanese-streaming`. These are synthetic offline messages; the streaming
fixture holds an unfinished reply for inspecting wrapping and the completion handoff.
Add `-yorozuFinishJapanese on -followUpBehavior steer` and send `Continue`, then `Finish`,
to deliver growing and completed replies through the offline transport. `JapaneseStreamingTests`
drives those messages through the real composer, checks the table appears during growth,
and verifies the completed reply becomes selectable without losing its Markdown blocks.

Generate with `tuist generate --no-open --path apps/ios`, then run:

```sh
env -u SDKROOT xcodebuild test \
  -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Also run on an iPad simulator. These tests use the debug offline chat showcase: no pairing,
account, network, or real message. Keep the simulator software keyboard enabled. Assertions
cover keyboard presence while the model and effort card opens, model/effort changes, draft
preservation and continued typing after selection, and no keyboard appearing when initially unfocused.
A retained screenshot shows the card and keyboard together. Real-device keyboard/IME and
hardware-keyboard behavior still require device validation; these are not proven by compilation.

`PairingFlowTests` uses the offline pairing showcases and never writes pairing keys or contacts
a relay. Run it on a small iPhone simulator with:

```sh
env -u SDKROOT xcodebuild test \
  -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuUITests \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' \
  -only-testing:YorozuUITests/PairingFlowTests
```

These tests cover accepted manual input dismissing before an asynchronous failure, invalid
input staying editable, scanner-to-manual recovery, disabled actions while connecting, and
the largest accessibility text size in landscape. Simulator scanner fallback is covered;
actual camera permission denial and scanning hardware still require device validation.

Picker regressions also open New thread from the list and New session from a chat, verify an
immediate Yorozu draft, type a prompt, and choose an inline agent row from the conversation. They then
deliver an agent reply and unread thread-list update through the offline transport. Delivery
starts when the folder step appears, so no timing guess is needed. They assert the picker keeps
that step, stays interactive, preserves the current agent and draft on Cancel, and dismisses when a
folder is selected without losing draft text. Coding choices then expose their project row inline.

`ProgressFooterTests` seeds a generating turn with no work rows, plus pending and failed messages. Native
element frames must place the fallback progress label below the latest queued message.

`ConnectionTests` and `ShowcaseFlowTests` need no flags of their own. The connection tests pair
the app with the real relay and Mac sidecar behind a fault proxy
(`packages/runtime/test-support/wire-harness.mjs`), so run the suite through the script that
starts it; without it they skip:

```sh
apps/ios/e2e/ui-tests.sh    # add -only-testing:YorozuUITests/ConnectionTests for one class
```

It builds, runs on a throwaway iPhone simulator, and keeps the result bundle, harness log and,
on failure, the app's device log in `apps/ios/e2e/.ui`. CI runs the same script nightly and
before every release candidate (`.github/workflows/ui-tests.yml`).
