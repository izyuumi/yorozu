# Mac Send rendering stalls

Investigated on 2026-10-03 after reports of intermittent Mac freezes when sending,
including short plain-text messages. Installed Yorozu was 0.5.0 build 10262; the
candidate manifest identifies source `ddf8d6a4d11c68a36da782a8c4f3d1a66dfb7a7d`.
The installed app was idle during observation. No live installed-app hang was
captured, and it was not restarted or modified.

## Reproduction and cause

The existing native `YorozuUIHarness` now has a synthetic Send fixture: 1,000
alternating user/agent messages containing Japanese prose, no attachments or
URLs, five 16-character drafts, an offline transport, and a private cache.
It mounts the shipping `ChatView` in an AppKit window and calls the shipping
`ChatModel.send`. A 10 ms main-actor heartbeat measures pauses during submission
and the ensuing render. Reopening the model must recover all five outbox messages
and the cleared draft before a timing result can pass.

A bounded sample of the original fixture captured these main-thread computations:

- `MessageBubble.body` repeatedly called `firstLink`, constructing
  `NSDataDetector` and tokenizing unchanged CJK replies during view updates.
  The detector also ran before the old `!streaming` condition was evaluated.
- `ChatModel.canWithdraw` searched the whole visible transcript for every user
  row, producing repeated history scans during rendering.

The patch computes preview URLs outside the main actor only when finished reply
text changes. The view associates the result with its text, so a changed or
streaming reply cannot show a stale preview. `ThreadTimeline` now indexes terminal
replies and stops once per timeline change; Remove keeps its previous outbox,
stop, completion-ID and legacy suffix behavior.

Representative runs on the authorized Mac mini (macOS 27.2, Xcode 27.0):

| Source | Worst UI heartbeat gap | Submission |
| --- | ---: | ---: |
| Original 0.5 source | 662 ms | 3–9 ms |
| Link detection fix alone | 326 ms | about 4 ms |
| Both fixes | 183 ms | about 4 ms |
| Original source, repeated final control | 608 ms | about 4 ms |
| Both fixes, repeated final run | 178 ms | 4–5 ms |

A 20-message history control passed on both versions: worst gaps were 51 ms
before and 40 ms after. Short drafts alone do not require a stall; retained
history is the workload in this reproduction. The user's history size is unknown.

These are rendering stalls with short drafts; no reply or network round trip is
required to reproduce them. They demonstrate two sources of brief UI stalls,
without proving that every reported freeze has the same cause.

## Regression and validation

Run the opt-in timing regression on a Mac with a fresh output directory:

```sh
swift run -c release --package-path packages/shared-swift \
  --scratch-path /tmp/yorozu-send-build YorozuUIHarness \
  /tmp/yorozu-send-run --send-freeze --verify-send
```

`--verify-send` requires offline durability and a worst heartbeat gap below
250 ms. It fails against archived, unmodified 0.5 production source and passes
with the patch. `YOROZU_SEND_HISTORY_COUNT` allows smaller-history controls.
The budget is a local performance regression guard, not a portable CI benchmark.

Validation also passed 441 shared Swift tests, 16 Mac tests, native thread-opening
and streaming checks, interrupted-send and reconnect recovery, Mac multi-host and
startup checks, and Mac/iOS Simulator compilation. The new Remove regression
checks legacy IDs containing colons, unrelated replies, exact completions,
terminal versus pending stops, and cache invalidation after timeline updates/deletion.

Native button/Return input is not claimed by this fixture. An attempted local
AppKit input sequence delivered no messages and failed the durability guard;
its low heartbeat gaps were discarded. Those failed controls and the original
profile remain local evidence outside the repository. No scroll feedback loop
was demonstrated, so no scroll behavior was changed. Installed profiles, logs,
history, connections and update feeds were preserved; no build was installed.
