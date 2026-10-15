import { expect, test } from "vitest";
import { configured, gone } from "./apns.js";

/**
 * The parts of the APNs client that are decisions rather than network: whether there is a key
 * to sign with at all, and whether Apple's answer means the token is dead.
 */

test("a room without a complete apple key is not configured, and wakes nobody", () => {
  expect(configured({})).toBe(false);
  expect(configured({ APNS_KEY_ID: "k" })).toBe(false);
  expect(configured({ APNS_KEY_ID: "k", APNS_TEAM_ID: "t" })).toBe(false);
  expect(configured({ APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_KEY_P8: "pem" })).toBe(true);
});

test("only an unregistered token is dead", () => {
  // A generic 400 also covers bad payloads, topics and priorities. Deleting a valid token for
  // one of those server-side mistakes silently disables every later notification.
  expect(gone(410)).toBe(true);
  expect(gone(400)).toBe(false);
  // Everything else is either fine or worth keeping the token for.
  expect(gone(200)).toBe(false);
  expect(gone(429)).toBe(false);
  expect(gone(500)).toBe(false);
});
