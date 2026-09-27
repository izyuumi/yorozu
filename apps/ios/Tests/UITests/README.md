# Composer keyboard regression

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

Picker regressions also open New thread from the list and New session from a chat, then
deliver an agent reply and unread thread-list update through the offline transport. Delivery
starts when the folder step appears, so no timing guess is needed. They assert the picker keeps
that step, stays interactive, and dismisses when a folder starts the new draft.

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
