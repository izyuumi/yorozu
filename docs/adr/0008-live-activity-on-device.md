# 0008. The Live Activity on the device

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

The app has one Live Activity that shows running turns, approvals that need the owner, and voice recording and transcription. ActivityKit only lets an app start an activity while it is in front, and anything in the activity's state may be pushed through the relay, so the state must reveal nothing.

## Decision

- One activity (`YorozuActivityAttributes`), opt-in: the switch in Settings › Live Activities is off until the owner turns it on. It lives in the app's standard defaults, so only the app reads it; the extensions compile `LiveActivitySetting` but never call it. The old on-by-default switch (`legacyKey`) is dropped at launch and never read.
- Started in the app, updated by the app and, with a host that supports it, by counts-only relay pushes ([0009](0009-live-activity-host-pushes.md)).
- Jobs, from any source:
  - Turns follow `model.awaitingReply` with the tool step count. In the app the conversation shows a turn, so turns alone start the activity only at `leaving()`, and `returned()` ends it.
  - Recording and transcription: `upsert(YorozuJob(kind: .recording, startedAt:), convId:)` when recording starts, `upsert` the same token as `.transcribing` when it stops, then `finish(id:state: .done, alert: .transcriptReady)` with the transcript, `.recordingCap` when the length limit stopped it, or `finish(id:state: .failed, alert: .localFailure)`. They start the activity in the app and keep it on return, because they are not on screen in the app. Background audio keeps the app, and so the updates, alive while recording.
- Lifecycle:
  - Until the app can start the activity, jobs wait in memory.
  - Leaving the foreground (still in front, in the scene phase handler) is the last moment ActivityKit lets it start one.
  - Back in the app, the conversation shows turns and approvals, so only recording and transcription stay.
  - Finished jobs linger `YorozuJobs.linger` as tap targets, then go. No jobs, no activity.
  - A timer clears a finished row once it lingered while the app still runs; `staleDate` covers the rest.
  - Leaving with nothing running still ends the activity, so the system dismisses it after the linger. With `endWhenIdle` (nobody left to run a timer) and nothing running, `show` ends it too. `show` returns false when the activity ended.
  - Turning the switch off ends the activity now, drops its jobs and tells the host to forget the push token. `turns` is cleared in `disable()`, not in the queue, because `syncTurns` writes it outside the queue: a turn tracked after the switch came back on must not be wiped by a `disable` still waiting in the queue.
- Reports to the host:
  - With a host listing `liveActivityPush`, the activity takes an ActivityKit push token, and the app reports it with every change of its jobs and each turn's conversation over the encrypted session (`ActivityReport`). The host then pushes counts-only states while the app is suspended, and forgets the token when told it ended. With any other host the activity has no push token.
  - The report carries the jobs as the wire carries them, times in epoch milliseconds, and `turns` (job token → convId) for each running turn. Recording and transcription go along unchanged: the host keeps them as they are in every push, so a push never wipes a job only this device knows.
  - `reported` holds the last report the host got and whether the host may hold a token of ours to forget (at launch: maybe one from before, whose activity `start` just ended).
  - Before the app suspends, it waits until the push token, if ActivityKit hands it over in time, reaches the host.
  - `AppModel.sessionsOpened` counts opened sessions. Each new session reports again, since the host may have restarted and forgotten the activity, or still hold an ended one.
- State and privacy:
  - `YorozuActivityState` is the whole content state; a push replaces it outright. Nothing is static.
  - The state is opaque job tokens, kinds, states, step counts and times, plus `updatedAt` (when the app built it; the relay's pushes carry none).
  - A job is keyed by an opaque random token, never by a conversation. What a row is about lives only in the device's `ActivityLabels`, next to the widget snapshot: the conversation to open and, only while message previews are on, its title. With previews off, no title stays stored. A pushed state carries no conversation, title, text or tool name.
  - Steps are tool calls since the owner's last message, a count only, never names or arguments.
  - Only events no push already announces alert (`JobEvent`).
- Presentation (`YorozuActivityWidget`): one line per job, at most three, then "+N more", each opening its conversation. Only needs-you takes the accent. When stale, timers hide and a line says when it last updated. Labels come from `ActivityLabels`, never from the state; titles only while previews are on. The timer column is 64 pt, wide enough for "1:02:14", so a timer never stretches its row.
- Decoding: the plugin's counts-only state, as the relay forwards it in `content-state`, decodes the way ActivityKit decodes it: the default `JSONDecoder`, dates as seconds since 2001. The shared test fixture is built at 2027-01-15T08:00:00Z.

## Consequences

- Relay pushes can update the activity without revealing what any conversation is about.
- The notification service never touches the activity ([0010](0010-widgets-and-notification-service.md)).

## Where in the code

- `apps/ios/Sources/YorozuIOS/YorozuActivities.swift` — `YorozuActivities`, `leaving()`, `returned()`, `disable()`, `apply(_:label:alert:)`, `scheduleExpiry(_:)`, `reported`, `waitUntilReported(limit:)`, `reportAgain()`, `steps(_:)`
- `apps/ios/Sources/YorozuIOS/Root.swift` — scene phase handler
- `apps/ios/Sources/WidgetShared/Model/YorozuActivityAttributes.swift` — `YorozuActivityAttributes`, `show` (`endWhenIdle`)
- `apps/ios/Sources/WidgetShared/Model/YorozuActivity.swift` — `YorozuJob`, `YorozuJob.steps`, `YorozuActivityState`, `JobEvent`, `YorozuJobs.keepsActivityInApp`, `ActivityLabels`, `ActivityLabels.redact(previews:)`
- `apps/ios/Sources/WidgetShared/Model/LiveActivitySetting.swift` — `LiveActivitySetting`, `legacyKey`
- `apps/ios/Sources/YorozuWidgets/YorozuActivityWidget.swift` — `YorozuActivityWidget`, timer width
- `apps/ios/Sources/Client/ActivityReports.swift` — `ActivityReport.init(pushToken:activity:turns:)`
- `apps/ios/Sources/Client/AppModel.swift` — `sessionsOpened`
- `apps/ios/Tests/ActivityReportTests.swift` — `t0`, `pluginContentStateDecodes()`
- `apps/ios/Project.swift` — `NSSupportsLiveActivities`
