import { expect, test } from "vitest";
import {
  decodeQrPayload,
  encodeQrPayload,
  type EventKind,
  type QrPayload,
  type YorozuEvent,
} from "./index.js";

const base = { id: "e1", threadId: "home", ts: 1_757_640_000_000, agentId: "main" };

test("an event narrows its data from its kind", () => {
  const event: YorozuEvent = { ...base, kind: "message", data: { role: "user", text: "hi" } };
  if (event.kind !== "message") throw new Error("unreachable");
  expect(event.data.text).toBe("hi");
});

test("subagent events carry a parent", () => {
  const event: YorozuEvent = {
    ...base,
    agentId: "researcher",
    parentAgentId: "main",
    kind: "thought",
    data: { text: "checking the catalog" },
  };
  expect(event.parentAgentId).toBe("main");
});

test("sync_delta nests events", () => {
  const inner: YorozuEvent = { ...base, kind: "thread_archive", data: {} };
  const event: YorozuEvent = { ...base, kind: "sync_delta", data: { events: [inner] } };
  if (event.kind !== "sync_delta") throw new Error("unreachable");
  expect(event.data.events[0]?.kind).toBe("thread_archive");
});

test("every spec'd kind exists", () => {
  const kinds: EventKind[] = [
    "message",
    "thought",
    "tool_call",
    "tool_result",
    "approval_card",
    "approval_answer",
    "thread_create",
    "thread_list",
    "thread_archive",
    "sync_request",
    "sync_delta",
  ];
  expect(kinds).toHaveLength(11);
});

test("QR payloads round-trip and untrusted input is rejected", () => {
  const qr: QrPayload = { v: 1, relayUrl: "wss://relay.yumi.to", macPubkey: "AAA", token: "t" };
  expect(decodeQrPayload(encodeQrPayload(qr))).toEqual(qr);
  expect(() => decodeQrPayload('{"v":2}')).toThrow();
  expect(() => decodeQrPayload("null")).toThrow();
  expect(() => decodeQrPayload("not json")).toThrow();
});
