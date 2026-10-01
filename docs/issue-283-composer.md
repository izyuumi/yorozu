# Issue 283: native composer and draft recovery

This is the first functional slice of [issue 283](https://github.com/izyuumi/yorozu/issues/283),
based on main `7439598` and the merged [continuous chat design](design/continuous-chat-memory-v0.0.md).
The native chat owns the user's unsent text and attachments throughout acquisition and recovery.
This slice does not implement the design's new task store, PAIOS memory service, or scheduling API.

## Delivered behavior

- The rounded native composer keeps its existing multiline editing and keyboard behavior, with
  the attachment menu inside. Images show their content without cropping; file labels allow two lines.
- User-initiated Paste supports images, PDF, Office documents and other file representations.
  Native iOS Paste retains separately provided text, including Japanese text, alongside the files.
  Plain text and web links retain native editing behavior. Opening the attachment menu does not read
  clipboard contents. macOS keyboard interception checks pasteboard metadata only.
- Photos, camera, Files, file drops and pasted files use the existing staging/transport pipeline.
  File reads reject directories and non-file URLs, and read at most 25 MiB plus one sentinel byte.
  Acquisition attempts at most ten sources and retains at most 50 MiB of raw data per batch.
  Existing transport limits remain 5 MiB per attachment, ten attachments and 20 MiB per message.
  Large images can be reduced before transport validation. Provider data fallback APIs may allocate
  their supplied buffer before its size can be checked; the retained-data cap is not a provider RSS cap.
- Clipboard provider work has a finite 30-second deadline, cancellation, loading feedback and a
  recovery message. Switching or leaving a conversation cancels its paste intent; a late callback
  cannot stage into another draft. Readable files survive partial failure. An import failure does
  not clear text or existing attachments. The user can remove individual attachments and send files
  with an empty text field.
- Creating a stash is removed. Existing encrypted composer autosave remains in place. A toolbar
  recovery menu appears only when that conversation already contains legacy saved drafts.
  Recovery copies text and attachments into a separate draft with a stable ID and preserves the
  current draft and original saved copy. Repeated recovery opens the same draft and preserves edits.
  The source copy remains available through interrupted writes of the two encrypted cache records.
  Host changes retain the saved drafts with their owning composer.
- New recovery and paste text has English source and Japanese localization in both native catalogs.

## Validation

Run with the repository's locked Node/pnpm and current Xcode; build outputs below belong in a
fresh scratch directory. No real pairings, user conversations, permissions or clipboard-monitoring
services are needed for these checks.

```sh
pnpm install --frozen-lockfile
pnpm --filter '!@yorozu/web' -r build
env -u SDKROOT swift test --package-path packages/shared-swift --build-system native --scratch-path /tmp/yorozu-shared-check
env -u SDKROOT swift test --package-path apps/mac --build-system native --scratch-path /tmp/yorozu-mac-check
tuist generate --no-open --path apps/ios
xcodebuild build -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/yorozu-ios-check \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES
node scripts/check-localizations.mjs
```

Validated on Xcode 27.0 (27A266a), with an iOS 27.0 iPhone 17 Pro simulator. Mixed native Paste
used a separate synthetic source app: PNG, PDF, DOCX, XLSX and PPTX plus Japanese text. The existing
draft remained editable. Removing the PDF preserved the other four files. Clearing only text and
sending produced one attachment-only queued message with the expected four files and cleared the
composer. This uses the production views in their existing DEBUG showcase; queued display is not
evidence of provider execution or document-content extraction.

Regression tests read actual pre-upgrade encrypted cache fixtures, including text-only, file-only,
combined drafts, repeated launches, interrupted record writes and host transfer. Import tests
exercise cancellation, failure recovery, bounded reads, count limits and retained-byte limits.
The count-limit test fails against the original unbounded acquisition loop (eleven reads and
eleven successful picks), and passes with the bounded loop.

The existing runtime serve suite passes 210 tests. Native macOS package tests pass 16 tests.
The final shared suite passes 447 tests. Three focused native UI tests also pass: native message
copy/text selection, history and draft restoration after relaunch, and messages sent into a dead
link confirmed exactly once when it returns. The latter two use the real relay/sidecar harness.
The final iPad image-grid and composer layout was inspected on iPad Pro 11-inch (4th generation),
iOS 27.0; this does not establish hardware camera or folding-device behavior.
Compiler-extracted shared UI strings pass English/Japanese coverage for both catalogs.
The installed runtimes are iOS 27.0/27.1; the separate release gate on iOS 26.5 remains unverified.

## Remaining issue scope

| Slice | Required next behavior |
| --- | --- |
| Chat ownership | Implement the Yorozu-owned durable message/task records and explicit context contracts from design v0.0 before presenting one continuous chat as production behavior. |
| Reply composition | Delivered for negotiated assistant-channel conversations in the [reply slice](issue-283-replies.md). Direct-agent context and the new continuous-chat task store remain separate contracts. |
| Native navigation | Implement Chat, Schedules and Settings tabs against real models. The approved prototype's schedules are in-memory examples, not a production scheduler. |
| Connection/readiness | Present independently confirmed link, adapter and execution readiness; preserve honest unknown/offline states and actionable diagnostics/permission requests. |
| Adapter migration | Keep existing direct-agent/model/workspace capabilities until replacements and recovery exist. Removing controls speculatively would strand current work. |
| Memory | Verify a real PAIOS contract for full memory ownership, provenance, scoped retrieval and writes. Design documentation does not establish that an API exists. |

## Smallest real scheduling slice

Production runtime initialization intentionally does not start the dormant legacy scheduler
(`packages/runtime/src/serve.ts`). Its `assign-cron` CLI is not a schedule-management API.
The current channel protocol in `packages/shared/src/channel.ts` provides message/run boundaries,
not durable schedule CRUD. Do not populate the Schedules tab from an in-memory replacement.

The smallest useful next step is read-only schedule visibility with explicit capability negotiation:
choose the owning host, resolve its actual supported schedule list API, return stable IDs, timezone,
enabled state, next-run time and last outcome, and persist the last successful snapshot with a
visible stale/offline state. A native tab may expose creation only after the write API is verified.
For an OpenClaw-owned scheduler, bridge its real gateway API through the authenticated host/channel;
verify the installed API contract and routing before implementing the bridge. For a Yorozu-owned
scheduler, first add a durable schedule store and idempotent dispatch into the new task model.
These are different ownership choices and must be reconciled with design v0.0, not mixed silently.

After read-only visibility, implement one daily schedule with an explicit timezone, durable create
ID, edit/pause/delete acknowledgments and host reconciliation. Test response loss after creation,
restart/offline recovery, timezone/DST boundaries, duplicate deliveries and execution cancellation
before broad recurrence controls. User-visible success must follow a durable host acknowledgment.

No push, pull request, merge, beta build upload or release is included in this slice.
