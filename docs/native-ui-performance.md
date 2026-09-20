# Native UI performance evidence — 2026-09-20

The reported stutter has a reproducible cause in shared SwiftUI state handling. A sync page of 200 × 4 KB events synchronously encoded, encrypted and atomically wrote the growing thread 200 times. The original debug test measured **269 ms** on the main actor and failed its 150 ms regression ceiling. Batching to one snapshot per thread reduced the same workload to **15 ms**. Cache encoding/encryption/writes now run on ordered utility tasks; outbox durability stays synchronous. Background drains and iOS suspension await pending cache writes.

Each thread now owns its observable timeline. A regression test failed before the change because an unrelated thread invalidated the open thread’s reactions; it now passes. Unchanged timelines reuse grouped rows. The grouping benchmark measured **173 ms raw versus 0.047 ms cached** for 100 repetitions of 1,000 events. Equal event replays do not rewrite the timeline. The UIKit bridge avoids unchanged diffable snapshots and quadratic membership scans.

Native SwiftUI Menu/Pickers replace the custom model/effort overlay on iOS and macOS. Work details use DisclosureGroup. Removed approval-card entrance motion, live-work animation, and broad composer animations; remaining chat motion respects Reduce Motion. Screenshot inspection exposed a black-on-black macOS secondary approval button; native bordered button styling fixes it.

## Measurements and limits

- Final offscreen harness: 20 sync pages; median **13.35 ms**, p95 **13.58 ms**, maximum **13.58 ms**.
- Instruments Time Profiler: 300 pages, median **12.27 ms**, p95 **13.61 ms**, maximum **20.04 ms**; 6,339 CPU samples; **zero potential-hang records** at the 250 ms threshold. ThreadCache.write stacks occur on worker threads. Trace: `/tmp/yorozu-ui-profile.trace`; exports `/tmp/yorozu-time-samples.xml`, `/tmp/yorozu-hangs.xml`.
- Measurements use a debug executable on this Mac, not iPhone frame-rate measurements. Screenshot rendering uses actual AppKit-hosted SwiftUI controls without a window or app bundle. A 390-point image is a narrow-layout check, not an iOS screenshot. Interrupted buttons in the scene are illustrative; approval, question and work views are production components.
- Four inspected screenshots: [narrow light](screens/native-bridge/native-390-light.png), [narrow dark](screens/native-bridge/native-390-dark.png), [wide light](screens/native-bridge/native-900-light.png), [wide dark](screens/native-bridge/native-900-dark.png).
- iOS keyboard/model-menu interaction tests compile, but were not launched: this session prohibits alternate app bundles. Physical iPhone/iPad keyboard, IME, VoiceOver, Reduce Motion and sustained streaming/scrolling still need device verification. No claim of a complete real-device stutter fix.

## Reproduce without launching an app bundle

```sh
env -u SDKROOT swift test --package-path packages/shared-swift
env -u SDKROOT swift run --package-path packages/shared-swift YorozuUIHarness /tmp/yorozu-ui-evidence
xcrun xctrace record --template 'Time Profiler' --time-limit 10s \
  --output /tmp/yorozu-ui-profile.trace --no-prompt --launch -- \
  "$PWD/packages/shared-swift/.build/out/Products/Debug/YorozuUIHarness" \
  /tmp/yorozu-ui-profile --profile
```

Regression coverage: `cachedSyncPageDoesNotBlockTheMainActorForAFrameBurst`, `backgroundThreadEventsDoNotInvalidateTheOpenThreadsReactions`, `unchangedTimelineReusesGroupingAndInvalidatesForResultsAndRunningState`, existing burst/paced streaming tests, and the keyboard UI harness. Sync-page timing starts at the first applied event, excluding scheduler delay from unrelated concurrent tests. The outbox retry test checks stable IDs rather than exactly-once transport delivery: reconnect may resend before receipt, and runtime deduplication is the contract.
