import { expect, test } from "vitest";
import { acceptsSeq, decodeEnvelope, encodeEnvelope, isSeq, MAX_DEVICES, MAX_SEQ } from "./channel.js";
import type { YorozuEvent } from "./events.js";

const event: YorozuEvent = {
  id: "e1",
  threadId: "t1",
  ts: 1,
  agentId: "phone",
  kind: "message",
  data: { role: "user", text: "ping" },
};

test("an envelope round-trips and is plain JSON both languages read", () => {
  const bytes = encodeEnvelope(7, event);
  expect(JSON.parse(Buffer.from(bytes).toString())).toEqual({ seq: 7, event });
  expect(decodeEnvelope(bytes)).toEqual({ seq: 7, event });
});

test.each([
  ["no seq", JSON.stringify({ event })],
  ["seq 0", JSON.stringify({ seq: 0, event })],
  ["negative seq", JSON.stringify({ seq: -3, event })],
  ["fractional seq", JSON.stringify({ seq: 1.5, event })],
  ["string seq", JSON.stringify({ seq: "1", event })],
  // 2^53 is an integer to `Number.isInteger`, but not one every value up to it can be told apart at.
  ["unsafe seq", JSON.stringify({ seq: 2 ** 53, event })],
  ["huge seq", "{\"seq\":1e300,\"event\":" + JSON.stringify(event) + "}"],
  ["no event", JSON.stringify({ seq: 1 })],
  ["a bare event", JSON.stringify(event)],
  ["an event with no kind", JSON.stringify({ seq: 1, event: { ...event, kind: undefined } })],
  ["an event with no data", JSON.stringify({ seq: 1, event: { ...event, data: undefined } })],
  ["an event with a string id missing", JSON.stringify({ seq: 1, event: { ...event, id: 7 } })],
  ["a string event", JSON.stringify({ seq: 1, event: "hi" })],
  ["not an object", "null"],
  ["an array", "[1]"],
])("a malformed envelope (%s) is refused", (_name, text) => {
  expect(() => decodeEnvelope(Buffer.from(text))).toThrow();
});

test("extra envelope fields are ignored, not refused", () => {
  const text = JSON.stringify({ seq: 3, event, later: "field" });
  expect(decodeEnvelope(Buffer.from(text))).toEqual({ seq: 3, event });
});

test("a seq is a safe non-negative integer", () => {
  expect(isSeq(0)).toBe(true);
  expect(isSeq(MAX_SEQ)).toBe(true);
  expect(isSeq(MAX_SEQ + 1)).toBe(false);
  expect(isSeq(-1)).toBe(false);
  expect(isSeq(1.5)).toBe(false);
  expect(isSeq("1")).toBe(false);
  expect(isSeq(Number.NaN)).toBe(false);
});

test("only a seq above the last accepted one is fresh", () => {
  expect(acceptsSeq(5, 5)).toBe(false);
  expect(acceptsSeq(5, 4)).toBe(false);
  expect(acceptsSeq(5, 1)).toBe(false);
  expect(acceptsSeq(5, 6)).toBe(true);
  // A gap is not a replay: the other end may have restarted and skipped a reserved block.
  expect(acceptsSeq(5, 5_000)).toBe(true);
});

/** The counter as a peer keeps it: advanced on accept, and carried across a restart as JSON. */
test("a counter carried across a simulated restart keeps rejecting what was already taken", () => {
  let counters = { recvSeq: 0 };
  const receive = (seq: number): boolean => {
    if (!acceptsSeq(counters.recvSeq, seq)) return false;
    counters = { recvSeq: seq };
    return true;
  };
  expect(receive(1)).toBe(true);
  expect(receive(2)).toBe(true);
  expect(receive(2)).toBe(false);

  // Restart: the only thing that survives is what was written.
  const stored = JSON.stringify(counters);
  counters = JSON.parse(stored) as typeof counters;
  expect(receive(1)).toBe(false);
  expect(receive(2)).toBe(false);
  expect(receive(3)).toBe(true);
});

test("the device cap is the relay's: sixteen phones per Mac", () => {
  expect(MAX_DEVICES).toBe(16);
});
