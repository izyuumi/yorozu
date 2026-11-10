import assert from "node:assert/strict";
import { test } from "node:test";
import { describeSchedule } from "../src/cron-text.ts";

const cron = (expr: string, tz?: string) => describeSchedule({ kind: "cron", expr, ...(tz !== undefined && { tz }) });
const every = (everyMs: number) => describeSchedule({ kind: "every", everyMs });

// The shapes of `CronScheduleTests.cronShapes` in apps/ios, with the text the plugin has always sent.
test("names the cron shapes the client also names", () => {
  assert.equal(cron("*/15 * * * *"), "Every 15 minutes");
  assert.equal(cron("5 * * * *"), "Hourly at :05");
  assert.equal(cron("0 9 * * *"), "Daily at 09:00");
  assert.equal(cron("  30 8 * * 1-5 "), "Weekdays at 08:30");
  assert.equal(cron("30 8 * * MON-FRI"), "Weekdays at 08:30");
  assert.equal(cron("0 10 * * 3"), "Wednesdays at 10:00");
  assert.equal(cron("0 7 15 * *"), "Monthly on day 15 at 07:00");
});

test("the edges of each range are still named", () => {
  assert.equal(cron("59 * * * *"), "Hourly at :59");
  assert.equal(cron("59 23 * * *"), "Daily at 23:59");
  assert.equal(cron("0 0 * * *"), "Daily at 00:00");
  assert.equal(cron("0 9 1 * *"), "Monthly on day 1 at 09:00");
  assert.equal(cron("0 9 31 * *"), "Monthly on day 31 at 09:00");
  assert.equal(cron("*/1 * * * *"), "Every 1 minutes");
});

test("0 and 7 are both Sunday", () => {
  assert.equal(cron("0 9 * * 0"), "Sundays at 09:00");
  assert.equal(cron("0 9 * * 7"), "Sundays at 09:00");
});

test("the time zone follows the text", () => {
  assert.equal(cron("0 9 * * *", "Asia/Tokyo"), "Daily at 09:00 (Asia/Tokyo)");
  assert.equal(cron("0 9 * * *", ""), "Daily at 09:00");
  assert.equal(cron("0 24 * * *", "Asia/Tokyo"), "Cron 0 24 * * * (Asia/Tokyo)");
});

// `CronScheduleTests.unsupportedCronFallsBack`: the client shows this text exactly when it declined the schedule.
for (const expr of ["0 24 * * *", "60 * * * *", "0 9 0 * *", "0 9 32 * *", "*/0 * * * *", "60 9 * * *", "60 9 * * 1-5", "0 24 * * 3", "0 24 15 * *"]) {
  test(`out of range is named by its expression: ${expr}`, () => assert.equal(cron(expr), `Cron ${expr}`));
}

for (const expr of ["0 9 * * 1,3", "0 9 1 1 *", "0 9 1 * 1", "0 */2 * * *", "*/5 9 * * *", "0 9 * *", "0 9 * * * *", "123 9 * * *", "0 9 * * 8", "@daily"]) {
  test(`an unsupported shape is named by its expression: ${expr}`, () => assert.equal(cron(expr), `Cron ${expr}`));
}

test("every-N units", () => {
  assert.equal(every(86_400_000), "Every day");
  assert.equal(every(172_800_000), "Every 2 days");
  assert.equal(every(3_600_000), "Every hour");
  assert.equal(every(7_200_000), "Every 2 hours");
  assert.equal(every(60_000), "Every minute");
  assert.equal(every(900_000), "Every 15 minutes");
  assert.equal(every(1_000), "Every second");
  assert.equal(every(30_000), "Every 30 seconds");
  assert.equal(every(1_500), "Every 1500 ms");
});

test("an interval that is not positive is Custom", () => {
  assert.equal(every(0), "Custom");
  assert.equal(every(-86_400_000), "Custom");
  assert.equal(every(Number.NaN), "Custom");
  assert.equal(describeSchedule({ kind: "every" }), "Custom");
});

test("an interval that is not a whole number of milliseconds is Custom", () => {
  assert.equal(every(Number.POSITIVE_INFINITY), "Custom");
  assert.equal(every(Number.NEGATIVE_INFINITY), "Custom");
  assert.equal(every(0.5), "Custom");
  assert.equal(every(1_500.5), "Custom");
});

test("a huge interval is named up to the largest safe integer, and Custom past it", () => {
  assert.equal(every(Number.MAX_SAFE_INTEGER), "Every 9007199254740991 ms");
  assert.equal(every(104_249_991 * 86_400_000), "Every 104249991 days");
  assert.equal(every(Number.MAX_SAFE_INTEGER + 1), "Custom");
  assert.equal(every(1e21), "Custom");
  assert.equal(every(Number.MAX_VALUE), "Custom");
});

test("the other kinds", () => {
  assert.equal(describeSchedule({ kind: "at" }), "Once");
  assert.equal(describeSchedule({ kind: "on-exit" }), "When a command exits");
  assert.equal(describeSchedule({ kind: "stream" }), "On command output");
  assert.equal(describeSchedule({ kind: "webhook" }), "Custom");
});
