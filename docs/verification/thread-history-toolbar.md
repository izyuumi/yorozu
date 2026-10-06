# Secretary history toolbar clipping — 2026-10-06

## Cause and correction

The secretary history branch in `apps/ios/Sources/YorozuIOS/RootView.swift`
wrapped the entire `historyContent` navigation container in a top `safeAreaInset`.
`ThreadListView` owns its `NavigationStack` / `NavigationSplitView`, native toolbar,
and navigation-drawer search. On the available iOS 27.0 simulator, the outer inset's
opaque return-header background covers the navigation bar: the title disappears,
and only the bottom sliver of the trailing glass toolbar remains above search.

An inert native fixture reproduces that specific geometry without any Yorozu
session or the owner's screenshot/data. Replacing the outer inset with a zero-spacing
`VStack` containing the same header followed by the same history container restores
the full native bar. This is a container proposal correction, not a guessed top
padding, fixed bar height, negative offset, clipping override, or toolbar redesign.

The return button, accessibility identifier, typography, existing header padding,
background, and callback are unchanged. Search, navigation paths, split selection,
settings/new-thread actions, history storage, and all Mac source remain unchanged.
The header remains available while a history conversation is pushed.

## Verification performed

- Base: `5565d469397165ca947c5c385c48a26e5d76d69c` in an isolated worktree.
- Dedicated iPhone 17 Pro simulator, iOS 27.0, UUID
  `3BC52833-EDDA-46CD-924A-89B209AE4CE1` (shut down after verification).
- `scripts/fixtures/thread-history-toolbar.swift` compiled with the installed
  iPhone Simulator SDK; launched only as `to.yumi.fixture.toolbar` on that device.
  No account, provider, pairing, production defaults, or runtime connection.
- `--before` reproduces the clipped trailing two-button pill and hidden title.
  Default composition shows both buttons/title fully, with search beneath them.
- Default-size dark and light captures; light accessibility5 capture verifies the
  return header grows naturally and does not cover the toolbar. The inert fixture's
  search placeholder is blank at accessibility5, so this is **not** complete search
  or accessibility acceptance. No search implementation was changed here.
- Actual iOS application compile succeeded with:

  ```sh
  TUIST_SECRETARY_ENABLED=true tuist generate --no-open --path apps/ios
  xcodebuild -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS \
    -configuration Debug \
    -destination 'platform=iOS Simulator,id=3BC52833-EDDA-46CD-924A-89B209AE4CE1' \
    -derivedDataPath /private/tmp/yorozu-toolbar-proof/DerivedData \
    CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build
  ```

  The first attempt forced `-sdk iphonesimulator` across the scheme, incorrectly
  compiling its watch dependency against iOS (`PhoneLink` WCSessionDelegate error).
  Removing that override allowed Xcode to resolve each platform and the build passed.
  No watch source was modified.
- `git diff --check` passed. No legacy UI aggregate/recovery tests ran.

Local evidence (not published): `/private/tmp/yorozu-toolbar-proof/`:
`before-final.png`, `after-final.png`, `after-light.png`,
`after-light-accessibility5.png`, `build-scoped.log`.

## Reproduce the minimal native fixture

Compile `scripts/fixtures/thread-history-toolbar.swift` as an iOS Simulator app
executable using `xcrun swiftc -parse-as-library -sdk "$(xcrun --sdk iphonesimulator
--show-sdk-path)" -target arm64-apple-ios18.0-simulator`. Supply a standard simulator
app Info.plist with bundle ID `to.yumi.fixture.toolbar`, executable `Fixture`,
`UILaunchScreen`, and phone/tablet device family. Install **only on an isolated
simulator**, never as the production app. Launch with `--before` for the old inset,
without it for the corrected stack. Optional `--light` and `--accessibility` flags.
Capture with `xcrun simctl io <owned-device> screenshot <path>` after launch settles.
The fixture duplicates only the minimal native composition, not the full app.

## Remaining acceptance

This demonstrates the layout cause on one simulator OS; it is not physical-device
proof, an interaction/accessibility audit, an iPad/split-view matrix, or an actual
paired-history end-to-end test. Verify on the owner's device/OS: enter history,
search and cancel, open/back from a thread, return to Yorozu, Settings/New thread,
light/dark, VoiceOver and larger text, plus iPad split view. No release, upload,
notarization, production installation, or published asset change is part of this fix.
