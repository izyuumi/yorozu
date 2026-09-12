import { expect, test } from "vitest";
import {
  ATTACHMENT_MAX_BYTES,
  decodeQrPayload,
  decodePairingString,
  encodePairingString,
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

test("a delegated agent's last message flags the delegation done", () => {
  const event: YorozuEvent = {
    ...base,
    agentId: "calendar",
    parentAgentId: "main",
    kind: "message",
    data: { role: "agent", text: "booked", done: true },
  };
  if (event.kind !== "message") throw new Error("unreachable");
  expect(event.data.done).toBe(true);
  // Absent everywhere else, so the flag means exactly one thing.
  const plain: YorozuEvent = { ...base, kind: "message", data: { role: "agent", text: "hi" } };
  if (plain.kind !== "message") throw new Error("unreachable");
  expect(plain.data.done).toBeUndefined();
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
    "thread_rename",
    "thread_pin",
    "sync_request",
    "sync_delta",
    "device_list",
    "device_remove",
  ];
  expect(kinds).toHaveLength(15);
});

test("a thread summary carries what a list row draws", () => {
  const event: YorozuEvent = {
    ...base,
    threadId: "",
    kind: "thread_list",
    data: {
      threads: [
        {
          id: "t1",
          title: "Groceries",
          archived: false,
          lastActivity: 1_757_640_000_000,
          lastMessage: "and eggs",
          pinned: true,
        },
      ],
    },
  };
  if (event.kind !== "thread_list") throw new Error("unreachable");
  expect(JSON.parse(JSON.stringify(event.data.threads[0]))).toEqual(event.data.threads[0]);
  expect(event.data.threads[0]?.lastMessage).toBe("and eggs");

  // Both are optional: a v1 summary, with neither, is still a summary.
  const v1: YorozuEvent = {
    ...base,
    kind: "thread_list",
    data: { threads: [{ id: "t1", title: "", archived: false, lastActivity: 1 }] },
  };
  if (v1.kind !== "thread_list") throw new Error("unreachable");
  expect(v1.data.threads[0]?.pinned).toBeUndefined();
});

test("archiving carries an optional flag, and pinning a required one", () => {
  // `{}` is what a phone older than unarchiving sends, and it still means archive.
  const legacy: YorozuEvent = { ...base, kind: "thread_archive", data: {} };
  if (legacy.kind !== "thread_archive") throw new Error("unreachable");
  expect(legacy.data.archived).toBeUndefined();

  const back: YorozuEvent = { ...base, kind: "thread_archive", data: { archived: false } };
  if (back.kind !== "thread_archive") throw new Error("unreachable");
  expect(back.data.archived).toBe(false);

  const pin: YorozuEvent = { ...base, kind: "thread_pin", data: { pinned: true } };
  if (pin.kind !== "thread_pin") throw new Error("unreachable");
  expect(pin.data.pinned).toBe(true);
});

test("a device list carries what the Settings window draws", () => {
  const event: YorozuEvent = {
    ...base,
    threadId: "",
    kind: "device_list",
    data: {
      devices: [{ pub: "k1", signingPub: "s1", via: "relay", lastSeen: 1, online: true }],
    },
  };
  if (event.kind !== "device_list") throw new Error("unreachable");
  expect(event.data.devices[0]?.via).toBe("relay");
  const removal: YorozuEvent = { ...base, kind: "device_remove", data: { pub: "k1" } };
  if (removal.kind !== "device_remove") throw new Error("unreachable");
  expect(removal.data.pub).toBe("k1");
});

test("pairing strings round-trip and untrusted input is rejected", () => {
  const qr: QrPayload = {
    v: 1,
    relayUrl: "ws://127.0.0.1:8791",
    macPubkey: "AAA",
    token: "t-_",
    roomId: "r",
  };
  const code = encodePairingString(qr);
  expect(code.startsWith("yorozu://pair?")).toBe(true);
  expect(decodePairingString(code)).toEqual(qr);
  // The QR carries the same string, so one parser serves the scanner and the paste field.
  expect(decodeQrPayload(code)).toEqual(qr);
  const { roomId, ...noRoom } = qr;
  expect(decodePairingString(encodePairingString(noRoom))).toEqual(noRoom);

  const bad = (query: string) => () => decodePairingString(`yorozu://pair?${query}`);
  expect(bad("v=1&relay=ws://r&token=t")).toThrow(); // missing key
  expect(bad("v=1&key=AAA&token=t")).toThrow(); // missing relay
  expect(bad("v=1&relay=ws://r&key=AAA")).toThrow(); // missing token
  expect(bad("v=2&relay=ws://r&key=AAA&token=t")).toThrow(); // wrong version
  expect(bad("v=1&relay=ws://r&key=not+base64!&token=t")).toThrow();
  expect(() => decodePairingString("nonsense")).toThrow();
});

test("the JSON QR form older codes carried still decodes", () => {
  const qr: QrPayload = { v: 1, relayUrl: "wss://relay.yumi.to", macPubkey: "AAA", token: "t" };
  expect(decodeQrPayload(JSON.stringify(qr))).toEqual(qr);
  expect(() => decodeQrPayload(JSON.stringify({ ...qr, roomId: 1 }))).toThrow();
  expect(() => decodeQrPayload('{"v":2}')).toThrow();
  expect(() => decodeQrPayload("null")).toThrow();
  expect(() => decodeQrPayload("not json")).toThrow();
});

test("a message can carry one attachment, and the cap is the same 5 MB Swift enforces", () => {
  const event: YorozuEvent = {
    ...base,
    agentId: "phone",
    kind: "message",
    data: {
      role: "user",
      text: "what is this?",
      attachment: { name: "receipt.png", mime: "image/png", data: "aGk=" },
    },
  };
  if (event.kind !== "message") throw new Error("unreachable");
  expect(event.data.attachment?.name).toBe("receipt.png");
  // The wire shape is the JSON both languages write, so it round-trips unchanged.
  expect(JSON.parse(JSON.stringify(event))).toEqual(event);
  expect(ATTACHMENT_MAX_BYTES).toBe(5 * 1024 * 1024);
});
