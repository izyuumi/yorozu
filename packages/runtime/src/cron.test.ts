import { expect, test } from "vitest";
import { matchesCron, parseCron } from "./cron.js";

/** Local time: cron fields are matched against the wall clock the Mac shows. */
const at = (iso: string) => new Date(iso);

const cases: [string, string, boolean][] = [
  // every minute
  ["* * * * *", "2026-09-12T03:00:00", true],
  // the nightly consolidation job
  ["0 3 * * *", "2026-09-12T03:00:00", true],
  ["0 3 * * *", "2026-09-12T03:01:00", false],
  ["0 3 * * *", "2026-09-12T04:00:00", false],
  // steps
  ["*/15 * * * *", "2026-09-12T10:30:00", true],
  ["*/15 * * * *", "2026-09-12T10:31:00", false],
  ["0 */6 * * *", "2026-09-12T18:00:00", true],
  ["0 */6 * * *", "2026-09-12T19:00:00", false],
  ["5/15 * * * *", "2026-09-12T10:35:00", true],
  ["5/15 * * * *", "2026-09-12T10:30:00", false],
  // lists and ranges
  ["0 9,17 * * *", "2026-09-12T17:00:00", true],
  ["0 9,17 * * *", "2026-09-12T18:00:00", false],
  ["30 9-11 * * *", "2026-09-12T10:30:00", true],
  ["30 9-11 * * *", "2026-09-12T12:30:00", false],
  ["0 0-23/12 * * *", "2026-09-12T12:00:00", true],
  // month and day-of-month
  ["0 0 1 * *", "2026-10-01T00:00:00", true],
  ["0 0 1 * *", "2026-10-02T00:00:00", false],
  ["0 0 25 12 *", "2026-12-25T00:00:00", true],
  ["0 0 25 12 *", "2026-11-25T00:00:00", false],
  // day-of-week: 2026-09-12 is a Saturday, 2026-09-14 a Monday
  ["0 8 * * 1-5", "2026-09-14T08:00:00", true],
  ["0 8 * * 1-5", "2026-09-12T08:00:00", false],
  ["0 8 * * 6", "2026-09-12T08:00:00", true],
  // Sunday is both 0 and 7
  ["0 8 * * 7", "2026-09-13T08:00:00", true],
  ["0 8 * * 0", "2026-09-13T08:00:00", true],
  // both day fields restricted: Vixie cron ORs them
  ["0 0 12 * 1", "2026-09-12T00:00:00", true],
  ["0 0 12 * 1", "2026-09-14T00:00:00", true],
  ["0 0 12 * 1", "2026-09-15T00:00:00", false],
];

test.each(cases)("%s matches %s: %s", (expression, iso, expected) => {
  expect(matchesCron(expression, at(iso))).toBe(expected);
});

test("seconds are ignored: a match covers the whole minute", () => {
  expect(matchesCron("0 3 * * *", at("2026-09-12T03:00:59"))).toBe(true);
});

test.each([
  ["0 3 * *", "5 fields"],
  ["0 3 * * * *", "5 fields"],
  ["60 3 * * *", "field"],
  ["0 24 * * *", "field"],
  ["0 0 0 * *", "field"],
  ["0 0 * 13 *", "field"],
  ["0 0 * * 8", "field"],
  ["11-9 3 * * *", "field"],
  ["*/0 * * * *", "step"],
  ["*/x * * * *", "step"],
  ["a * * * *", "field"],
  ["1-2-3 * * * *", "range"],
  ["", "5 fields"],
])("rejects %s", (expression, reason) => {
  expect(() => parseCron(expression)).toThrow(reason);
});

test("surrounding and repeated whitespace is not part of the expression", () => {
  expect(matchesCron("  0   3 * * *  ", at("2026-09-12T03:00:00"))).toBe(true);
  expect(matchesCron("0\t3 * * *", at("2026-09-12T03:00:00"))).toBe(true);
});

test("both ends of every field are inside the bounds", () => {
  expect(matchesCron("0 0 1 1 *", at("2026-01-01T00:00:00"))).toBe(true);
  expect(matchesCron("59 23 31 12 *", at("2026-12-31T23:59:00"))).toBe(true);
});

/** 29 February parses in any year; it simply never matches in one that does not have it. */
test("a date that only exists in leap years still parses and matches", () => {
  expect(matchesCron("0 0 29 2 *", at("2028-02-29T00:00:00"))).toBe(true);
  expect(matchesCron("0 0 29 2 *", at("2026-03-01T00:00:00"))).toBe(false);
});

test("parsing once and reusing the result matches the same instants", () => {
  const cron = parseCron("*/30 9-17 * * 1-5");
  expect(matchesCron(cron, at("2026-09-14T09:30:00"))).toBe(true);
  expect(matchesCron(cron, at("2026-09-14T09:15:00"))).toBe(false);
  expect(matchesCron(cron, at("2026-09-13T09:30:00"))).toBe(false);
});
