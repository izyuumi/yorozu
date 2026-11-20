# 0022. Cron schedule text

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

The plugin describes cron schedules in English words. The app wants to name them in the device's own language, so both sides must agree on which schedules can be named.

## Decision

- `CronSchedule` covers the schedules the plugin's `describeSchedule` names in words, so the app can name them in its own language.
- Weekly `weekday` 0 is Sunday.
- The hour belongs to the schedule's own time zone, so the app formats it in GMT to keep the device's zone out of it.
- The plugin's `describeCron` uses the same ranges as `CronSchedule.cron` in the app. The app shows the plugin's text exactly when it declined a schedule.
- `cron-text.ts` reads only the cron schedule fields it needs (`ScheduleLike`) and imports nothing from OpenClaw.
- The plugin tests use the shapes of `CronScheduleTests.cronShapes` with the text the plugin has always sent, and mirror `CronScheduleTests.unsupportedCronFallsBack`.

## Consequences

- Changing either side's ranges requires changing both, and the tests on both sides.

## Where in the code

- `apps/ios/Sources/Client/CronSchedule.swift` — `CronSchedule`, `Kind.weekly`, `time(_:_:)`
- `plugins/openclaw-yorozu/src/cron-text.ts` — `ScheduleLike`, `describeCron`
- `plugins/openclaw-yorozu/test/cron-text.test.ts`
