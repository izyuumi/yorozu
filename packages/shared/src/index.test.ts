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
    "thread_read",
    "thread_set_model",
    "thread_set_effort",
    "model_list",
    "approval_settings",
    "sync_request",
    "sync_delta",
    "device_list",
    "device_remove",
    "receipt",
  ];
  expect(kinds).toHaveLength(21);
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

test("a thread carries the model it runs on, and setting it is a spec or null", () => {
  const listed: YorozuEvent = {
    ...base,
    threadId: "",
    kind: "thread_list",
    data: {
      threads: [
        {
          id: "t1",
          title: "Kyoto in April",
          archived: false,
          lastActivity: 1,
          model: "claude/claude-opus-5",
          effort: "high",
        },
      ],
    },
  };
  if (listed.kind !== "thread_list") throw new Error("unreachable");
  expect(listed.data.threads[0]?.model).toBe("claude/claude-opus-5");
  expect(listed.data.threads[0]?.effort).toBe("high");

  const set: YorozuEvent = {
    ...base,
    kind: "thread_set_model",
    data: { model: "claude/claude-opus-5" },
  };
  if (set.kind !== "thread_set_model") throw new Error("unreachable");
  expect(set.data.model).toBe("claude/claude-opus-5");

  // Back to the configured chain, as null or as the absent field a Swift client encodes.
  for (const data of [{ model: null }, {}]) {
    const back: YorozuEvent = { ...base, kind: "thread_set_model", data };
    if (back.kind !== "thread_set_model") throw new Error("unreachable");
    expect(back.data.model ?? null).toBeNull();
  }
});

test("reasoning effort and YOLO settings cross the device wire", () => {
  const effort: YorozuEvent = { ...base, kind: "thread_set_effort", data: { effort: "medium" } };
  const settings: YorozuEvent = { ...base, kind: "approval_settings", data: { yolo: true } };
  if (effort.kind !== "thread_set_effort" || settings.kind !== "approval_settings") {
    throw new Error("unreachable");
  }
  expect(effort.data.effort).toBe("medium");
  expect(settings.data.yolo).toBe(true);
});

test("YOLO on carries an expiry and hours", () => {
  // Old payloads stay valid: every new field is optional.
  const bare: YorozuEvent = { ...base, kind: "approval_settings", data: { yolo: false } };
  const report: YorozuEvent = { ...base, kind: "approval_settings", data: { yolo: true, yoloUntil: 1_757_640_000_000 } };
  const on: YorozuEvent = { ...base, kind: "approval_settings", data: { yolo: true, hours: 8 } };
  if (bare.kind !== "approval_settings" || report.kind !== "approval_settings") throw new Error("unreachable");
  if (on.kind !== "approval_settings") throw new Error("unreachable");
  expect(bare.data.yoloUntil).toBeUndefined();
  expect(report.data.yoloUntil).toBe(1_757_640_000_000);
  expect(on.data).toEqual({ yolo: true, hours: 8 });
});

test("the model list names every spec a thread can be put on", () => {
  const event: YorozuEvent = {
    ...base,
    threadId: "",
    kind: "model_list",
    data: {
      models: [{ id: "claude/claude-opus-5", label: "claude-opus-5", providerLabel: "Claude" }],
    },
  };
  if (event.kind !== "model_list") throw new Error("unreachable");
  expect(event.data.models[0]?.providerLabel).toBe("Claude");
  expect(JSON.parse(JSON.stringify(event))).toEqual(event);
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
  expect(() => decodeQrPayload(JSON.stringify(qr))).toThrow();
  const { roomId, ...noRoom } = qr;
  expect(decodePairingString(encodePairingString(noRoom))).toEqual(noRoom);
  // The pairing secret rides along when the Mac minted one, and is checked like the keys.
  const withSecret = { ...qr, secret: "s3cr3t" };
  expect(decodePairingString(encodePairingString(withSecret))).toEqual(withSecret);
  expect(() => decodePairingString(`${encodePairingString(qr)}&secret=not+base64url`)).toThrow();

  const bad = (query: string) => () => decodePairingString(`yorozu://pair?${query}`);
  expect(bad("v=1&relay=ws://r&token=t")).toThrow(); // missing key
  expect(bad("v=1&key=AAA&token=t")).toThrow(); // missing relay
  expect(bad("v=1&relay=ws://r&key=AAA")).toThrow(); // missing token
  expect(bad("v=2&relay=ws://r&key=AAA&token=t")).toThrow(); // wrong version
  expect(bad("v=1&relay=ws://r&key=not+base64!&token=t")).toThrow();
  expect(() => decodePairingString("nonsense")).toThrow();
});

test("a message can carry attachments, and the cap is the same 5 MB Swift enforces", () => {
  const event: YorozuEvent = {
    ...base,
    agentId: "phone",
    kind: "message",
    data: {
      role: "user",
      text: "what is this?",
      attachments: [{ name: "receipt.png", mime: "image/png", data: "aGk=" }],
    },
  };
  if (event.kind !== "message") throw new Error("unreachable");
  expect(event.data.attachments?.[0]?.name).toBe("receipt.png");
  // The wire shape is the JSON both languages write, so it round-trips unchanged.
  expect(JSON.parse(JSON.stringify(event))).toEqual(event);
  expect(ATTACHMENT_MAX_BYTES).toBe(5 * 1024 * 1024);
});

test("messages carry multiple mixed attachments", () => {
  const image = { name: "one.png", mime: "image/png", data: "MQ==" };
  const pdf = { name: "two.pdf", mime: "application/pdf", data: "Mg==" };
  const event: YorozuEvent = { ...base, kind: "message", data: { role: "user", text: "", attachments: [image, pdf] } };
  if (event.kind !== "message") throw new Error("unreachable");
  expect(event.data.attachments).toEqual([image, pdf]);
});
