# Composer keyboard regression

Generate with `tuist generate --no-open --path apps/ios`, then run:

```sh
env -u SDKROOT xcodebuild test \
  -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuKeyboardUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Also run on an iPad simulator. These tests use the debug offline chat showcase: no pairing,
account, network, or real message. Keep the simulator software keyboard enabled. Assertions
cover keyboard presence while the panel opens, model/effort changes and scrolling, draft
preservation and continued typing after Done, and no keyboard appearing when initially unfocused.
A retained screenshot shows the panel and keyboard together. Real-device keyboard/IME and
hardware-keyboard behavior still require device validation; these are not proven by compilation.
