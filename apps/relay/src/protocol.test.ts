import { expect, test } from "vitest";
import {
  alertPayload,
  allowFrame,
  BUFFER_CAP_BYTES,
  BUFFER_TTL_MS,
  dropCount,
  evictions,
  FRAMES_PER_SEC,
  MAX_DEVICES,
  newBucket,
  NOTIFY_BODY,
  NOTIFY_CLASSES,
  parseFrame,
  parseJoin,
  parseNotify,
  parsePush,
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
  // A rejoin carries no token; a non-string one is still a malformed join.
  expect(parseJoin({ roomId: "r", phonePubkey: "p", sig: "s" })).toMatchObject({ roomId: "r" });
  expect(parseJoin({ roomId: "r", phonePubkey: "p", sig: "s" })?.token).toBeUndefined();
  expect(parseJoin({ roomId: "r", token: 1, phonePubkey: "p", sig: "s" })).toBeNull();

  expect(parseFrame({ payload: "p", sig: "s" })).toMatchObject({ payload: "p" });
  expect(parseFrame({ payload: "p" })).toBeNull();
  expect(parseFrame({ payload: null, sig: "s" })).toBeNull();
});

test("known devices are capped, and a device already known evicts nobody", () => {
  const known = Array.from({ length: MAX_DEVICES }, (_, i): [string, number] => [`k${i}`, i]);
  expect(evictions(known, "k3")).toEqual([]);
  expect(evictions(known.slice(0, 3), "new")).toEqual([]);
  // Full, so the least recently paired one makes way for the newcomer.
  expect(evictions(known, "new")).toEqual(["k0"]);
  // Shrinking the cap sheds every device over it in one go, oldest first.
  expect(evictions(known, "new", 3)).toEqual(["k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7", "k8",
    "k9", "k10", "k11", "k12", "k13"]);
});

test("push registrations are accepted only in the shape the relay stores", () => {
  expect(parsePush({ deviceToken: "abc" })).toEqual({ deviceToken: "abc" });
  expect(parsePush({})).toBeNull();
  expect(parsePush({ deviceToken: 1 })).toBeNull();
});

test("a notify is a known class and an opaque reference, or it is nothing", () => {
  expect(parseNotify({ class: "reply", threadRef: "r" })).toEqual({ class: "reply", threadRef: "r" });
  expect(parseNotify({ class: "gossip", threadRef: "r" })).toBeNull();
  expect(parseNotify({ class: "reply" })).toBeNull();
  expect(parseNotify({ class: "reply", threadRef: "" })).toBeNull();
  expect(parseNotify({ class: "approval", threadRef: "r", eventRef: "e" })).toEqual({
    class: "approval",
    threadRef: "r",
    eventRef: "e",
  });
  expect(parseNotify({ class: "approval", threadRef: "r", eventRef: "" })).toBeNull();
  // Nothing else on the message survives into what the relay acts on.
  expect(parseNotify({ class: "reply", threadRef: "r", text: "the secret" })).toEqual({
    class: "reply",
    threadRef: "r",
  });
});

test("an alert carries a fixed phrase and an opaque reference, and nothing else", () => {
  const payload = alertPayload("approval", "Ab3-_x9Z", "Ev3-_x9Z") as any;
  expect(payload.aps.alert).toEqual({ title: "Yorozu", body: NOTIFY_BODY.approval });
  expect(payload.ref).toBe("Ab3-_x9Z");
  expect(payload.cls).toBe("approval");
  expect(payload.event).toBe("Ev3-_x9Z");
  // Every string anywhere in it is either the fixed vocabulary or the opaque reference.
  const strings = JSON.stringify(payload).match(/"[^"]*"/g) ?? [];
  const allowed = new Set([
    ...Object.values(NOTIFY_BODY),
    ...NOTIFY_CLASSES,
    "Yorozu",
    "Ab3-_x9Z",
    "Ev3-_x9Z",
    "aps",
    "alert",
    "title",
    "body",
    "sound",
    "default",
    "thread-id",
    "ref",
    "cls",
    "event",
  ]);
  for (const quoted of strings) expect(allowed).toContain(quoted.slice(1, -1));
});
