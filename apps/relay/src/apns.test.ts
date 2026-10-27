import { expect, test } from "vitest";
import { configured, gone } from "./apns.js";

test("a room without a complete apple key is not configured, and wakes nobody", () => {
  expect(configured({})).toBe(false);
  expect(configured({ APNS_KEY_ID: "k" })).toBe(false);
  expect(configured({ APNS_KEY_ID: "k", APNS_TEAM_ID: "t" })).toBe(false);
  expect(configured({ APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_KEY_P8: "pem" })).toBe(true);
});

test("only an unregistered token is dead", () => {
  expect(gone(410)).toBe(true);
  expect(gone(400)).toBe(false);
  expect(gone(200)).toBe(false);
  expect(gone(429)).toBe(false);
  expect(gone(500)).toBe(false);
});
