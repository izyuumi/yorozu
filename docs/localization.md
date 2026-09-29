# Native localization

English is the source language; every shipped, translatable UI key has Japanese text.
Agent replies, user messages, project paths, host names, and provider-supplied descriptions
remain their original content. System locale selects UI text and native date, duration,
and number formats.

The iOS and Mac app catalogs own shared UI text. Shared Swift views use the app's main
bundle, not the provider-mark resource bundle. iOS embeds its catalog in the main app,
widget, share extension, and notification extension. Watch has its own catalog. The Mac
bundle scripts compile both `Localizable.xcstrings` and `InfoPlist.xcstrings` into
`Contents/Resources`, where Foundation and macOS find the localized UI and privacy text.

Use literal `LocalizedStringKey` values in SwiftUI. Use `String(localized:)` when a helper,
status, error, ternary expression, notification, or AppKit API needs a `String`. Keep
interpolation inside the localized expression so Japanese can change argument order.
Do not concatenate English nouns or assume English plural rules. Keep all interpolated
argument types intact in translations; `%2$@` can move the second string argument first.

Run the catalog guard with no dependencies:

```sh
node scripts/check-localizations.mjs
```

The guard also accepts a catalog and Swift compiler extraction directory to check actual
compiled UI keys, including typed interpolation. For shared Swift:

```sh
swift build --build-system native -j 2 --package-path packages/shared-swift \
  --target YorozuShared -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc /tmp/yorozu-localized-strings
node scripts/check-localizations.mjs apps/ios/Resources/Localizable.xcstrings /tmp/yorozu-localized-strings
node scripts/check-localizations.mjs apps/mac/Resources/Localizable.xcstrings /tmp/yorozu-localized-strings
```

For native iOS builds enable `SWIFT_EMIT_LOC_STRINGS=YES` and check each target's generated
`.stringsdata` against the catalog that target packages. Verify English and Japanese in
the built app; catalog coverage alone cannot catch a wrong bundle or a nonlocalized
dynamic `String`. Check narrow containers, Dynamic Type, accessibility labels, and
Japanese Markdown tables when changing layout.
