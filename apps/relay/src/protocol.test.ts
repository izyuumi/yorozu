import { expect, test } from "vitest";
import {
  allowFrame,
  BUFFER_CAP_BYTES,
  BUFFER_TTL_MS,
  dropCount,
  FRAMES_PER_SEC,
  newBucket,
  parseFrame,
  parseJoin,
  parseRegister,
} from "./protocol.js";

test("the bucket allows a one-second burst and then refuses", () => {
  const bucket = newBucket(0);
  for (let i = 0; i < FRAMES_PER_SEC; i++) expect(allowFrame(bucket, 0)).toBe(true);
  expect(allowFrame(bucket, 0)).toBe(false);
});

test("the bucket refills at the sustained rate and never above the burst", () => {
  const bucket = newBucket(0);
  for (let i = 0; i < FRAMES_PER_SEC; i++) allowFrame(bucket, 0);
  expect(allowFrame(bucket, 500)).toBe(true); // half a second buys 30
  for (let i = 0; i < 29; i++) expect(allowFrame(bucket, 500)).toBe(true);
  expect(allowFrame(bucket, 500)).toBe(false);

  // An hour idle still only buys one second of burst.
  for (let i = 0; i < FRAMES_PER_SEC; i++) expect(allowFrame(bucket, 3_600_000)).toBe(true);
  expect(allowFrame(bucket, 3_600_000)).toBe(false);
});

const entry = (bytes: number, at: number) => ({ bytes, at });

test("nothing is dropped from a buffer inside both limits", () => {
  expect(dropCount([entry(10, 0), entry(10, 1)], 1)).toBe(0);
  expect(dropCount([], 0)).toBe(0);
});

test("entries past the TTL are dropped from the front", () => {
  const now = BUFFER_TTL_MS * 2;
  const entries = [entry(1, now - BUFFER_TTL_MS - 1), entry(1, now - BUFFER_TTL_MS), entry(1, now)];
  // Strictly older than the TTL goes; exactly at it stays.
  expect(dropCount(entries, now)).toBe(1);
});

test("the oldest entries are dropped until the byte cap is met", () => {
  const entries = [entry(4, 0), entry(4, 0), entry(4, 0)];
  expect(dropCount(entries, 0, 12)).toBe(0);
  expect(dropCount(entries, 0, 11)).toBe(1);
  expect(dropCount(entries, 0, 4)).toBe(2);
  // A single entry over the cap leaves an empty buffer rather than an over-cap one.
  expect(dropCount(entries, 0, 1)).toBe(3);
});

test("the TTL and the cap are applied together", () => {
  const now = BUFFER_TTL_MS + 10;
  const entries = [entry(8, 0), entry(8, now), entry(8, now)];
  // The first goes on age, then one more to fit 16 bytes into a 9 byte cap.
  expect(dropCount(entries, now, 9)).toBe(2);
});

test("the real cap is 5 MB over 24 hours", () => {
  expect(BUFFER_CAP_BYTES).toBe(5 * 1024 * 1024);
  expect(BUFFER_TTL_MS).toBe(86_400_000);
  expect(dropCount([entry(BUFFER_CAP_BYTES, 0)], 0)).toBe(0);
  expect(dropCount([entry(BUFFER_CAP_BYTES + 1, 0)], 0)).toBe(1);
});

test("envelopes are accepted only when every field is a string", () => {
  expect(parseRegister({ pubkey: "a", nonceSig: "b" })).toMatchObject({ pubkey: "a" });
  expect(parseRegister({ pubkey: "a" })).toBeNull();
  expect(parseRegister({ pubkey: "a", nonceSig: 1 })).toBeNull();

  expect(parseJoin({ roomId: "r", token: "t", phonePubkey: "p", sig: "s" })).toMatchObject({
    token: "t",
  });
  expect(parseJoin({ roomId: "r", token: "t", phonePubkey: "p" })).toBeNull();

  expect(parseFrame({ payload: "p", sig: "s" })).toMatchObject({ payload: "p" });
  expect(parseFrame({ payload: "p" })).toBeNull();
  expect(parseFrame({ payload: null, sig: "s" })).toBeNull();
});
