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

## Actual-app acceptance follow-up

The initial inert fixture established the cause; the follow-up executes the **actual
Yorozu iOS app** with `TUIST_SECRETARY_ENABLED=true` and the existing debug-only
`-yorozuShowcase threads` entry point. `Session` returns early with `ShowcaseTransport`,
which seeds synthetic threads and handles sends in process; the showcase also bypasses
notification registration. Dedicated fresh simulators have no pairing/account state.
No provider, relay, real message, login, legacy aggregate, or recovery test was used.

Only `YorozuUITests/HistoryToolbarTests` ran. The final two tests assert:

- Return-header frame ends before the native navigation bar begins; Settings and
  New thread remain hittable.
- Native search receives `Standup` and returns the synthetic Standup notes thread.
- Search dismissal follows the native platform: Close on the phone; clear/sidebar
  behavior on iPad. No hard-coded screen coordinates.
- Existing thread opens with its actual title and composer; phone Back returns to
  the list, while iPad keeps the search/sidebar beside the selected detail.
- Settings opens and dismisses; New thread / regular-width New session opens the
  actual New chat view. Return to Yorozu still works.
- At accessibility XXXL, toolbar geometry, search input/dismissal, Settings and
  return navigation work. This is not a VoiceOver audit.

Results (all iOS 27.0):

| Actual-app run | Result | Private result bundle |
| --- | --- | --- |
| iPhone 17 Pro, light, earlier test revision | 2/2 pass | `phone-tests-v2.xcresult` |
| iPad Pro 11-inch M5, light, final tests | 2/2 pass | `ipad-tests-v3.xcresult` |
| iPhone 17 Pro, dark, final tests | 2/2 pass | `phone-tests-final-dark.xcresult` |

Bundles, logs, exported screenshots/manifests and JSON summaries live under
`/private/tmp/yorozu-toolbar-proof/`. Screenshot directories are `phone-attachments/`,
`ipad-attachments/`, and `phone-dark-attachments/`. Both owned simulators were shut
down; XCTest had already terminated the app. No production app was installed.

Early failed runs exposed test assumptions, not a production patch change: iOS 27
calls phone search dismissal Close rather than Cancel; iPad has no close button and
clearing its search already dismisses the keyboard. Those native behaviors were
observed from the accessibility tree and the test was corrected. Raw failed-run logs
remain. Two optional, prolonged post-failure `simctl diagnose` collectors were stopped
with SIGTERM **after test execution ended**; successful final bundles are unaffected.
Later runs use Xcode's supported `-collect-test-diagnostics never`.

To run this exact safe class, generate the internal project as above, then:

```sh
xcodebuild test -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuUITests \
  -configuration Debug -destination 'platform=iOS Simulator,id=<owned-device>' \
  -derivedDataPath <isolated-derived-data> -resultBundlePath <new-result-bundle> \
  -only-testing:YorozuUITests/HistoryToolbarTests \
  -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES
```

Use `test-without-building` for the second device after building the same final tests.
Do not omit `-only-testing` or run the legacy aggregate harness.

## Remaining acceptance

The actual app also shows a blank native search placeholder at accessibility XXXL
before focus, although the final tests prove search input/dismissal works there.
This appearance issue is **not fixed or claimed resolved** by the toolbar correction;
it is also reproduced by the minimal native composition. No extra UI redesign was
introduced. Physical owner-device/OS, VoiceOver, hardware keyboard/IME, rotation and
other split-width sizes remain unverified. Synthetic transport proves UI interaction,
not live synchronization, provider dispatch, or device delivery.

Read-only iOS delivery assessment: [thread-history-toolbar-delivery.md](thread-history-toolbar-delivery.md).
No release, upload, account access, notarization, push, production installation, or
published asset change was performed by this acceptance follow-up.
