import { expect, test } from "vitest";
import {
  approvalCardSummary,
  decodeNotificationPreview,
  encodeNotificationPreview,
  notificationPreviewBody,
  notifyFor,
  NOTIFY_BODY,
  NOTIFY_PREVIEW_BYTES,
} from "./notify.js";
import { threadRef } from "./crypto.js";
import type { YorozuEvent } from "./events.js";

const event = (payload: Partial<YorozuEvent> & Pick<YorozuEvent, "kind" | "data">): YorozuEvent =>
  ({ id: "e", threadId: "t", ts: 1, agentId: "main", ...payload }) as YorozuEvent;

test("a finished main-agent reply is a reply, and a silent one is a completion", () => {
  expect(notifyFor(event({ kind: "message", data: { role: "agent", text: "hi", done: true } })))
    .toBe("reply");
  expect(notifyFor(event({ kind: "message", data: { role: "agent", text: "  ", done: true } })))
    .toBe("done");
});

test("deltas, delegated finals and tool traffic wake nobody", () => {
  expect(notifyFor(event({ kind: "message", data: { role: "agent", text: "par" } }))).toBeNull();
  // A specialist finishing is one step of the turn, not the end of it.
  expect(
    notifyFor(
      event({
        kind: "message",
        data: { role: "agent", text: "done", done: true },
        parentAgentId: "main",
      }),
    ),
  ).toBeNull();
  expect(notifyFor(event({ kind: "tool_call", data: { callId: "c", name: "n", args: {} } })))
    .toBeNull();
  expect(notifyFor(event({ kind: "thought", data: { text: "hm" } }))).toBeNull();
  // A tool result, cut or whole, is never a notification: nothing of it reaches a lock screen.
  const cut = event({ kind: "tool_result", data: { callId: "c", ok: true, output: "x".repeat(4096), truncated: true } });
  expect(notifyFor(cut)).toBeNull();
  expect(notificationPreviewBody(cut)).toBeNull();
});

test("cards are the class worth interrupting someone for, and a stop is a failure", () => {
  expect(notifyFor(event({ kind: "approval_card", data: { actionId: "a", actionClass: "send", target: "x" } })))
    .toBe("approval");
  expect(notifyFor(event({ kind: "question_card", data: { questionId: "q", question: "?", options: [] } })))
    .toBe("approval");
  expect(notifyFor(event({ kind: "interrupt", data: {} }))).toBe("failed");
});

test("a phone's own message and the control frames are not news", () => {
  expect(notifyFor(event({ kind: "message", data: { role: "user", text: "hello" } }))).toBeNull();
  expect(notifyFor(event({ kind: "thread_list", data: { threads: [] } }))).toBeNull();
  expect(notifyFor(event({ kind: "rule_list", data: { rules: [] } }))).toBeNull();
  expect(notifyFor(event({ kind: "device_list", data: { devices: [] } }))).toBeNull();
  expect(notifyFor(event({ kind: "sync_delta", data: { events: [] } }))).toBeNull();
});

test("no notification body can carry anything from the event", () => {
  // The whole vocabulary, fixed. Nothing here is assembled, so nothing here can leak.
  expect(Object.values(NOTIFY_BODY)).toEqual([
    "Yorozu replied.",
    "Yorozu needs your approval.",
    "Yorozu finished.",
    "Yorozu stopped.",
  ]);
});

test("a thread reference is short, stable, and says nothing about the thread", () => {
  const id = "3f8a1c2e-0b44-4d9a-9f21-7c6e5a0d1b83";
  expect(threadRef(id)).toBe(threadRef(id));
  expect(threadRef(id)).toHaveLength(8);
  expect(threadRef(id)).not.toContain(id.slice(0, 4));
  expect(threadRef(id)).not.toBe(threadRef("other"));
  expect(threadRef(id)).toMatch(/^[A-Za-z0-9_-]{8}$/);
});

test("a completed reply and a card get a byte-bounded preview body; nothing else does", () => {
  expect(notificationPreviewBody(event({ kind: "message", data: { role: "agent", text: "  hello  ", done: true } })))
    .toBe("hello");
  expect(notificationPreviewBody(event({ kind: "message", data: { role: "agent", text: "partial" } })))
    .toBeNull();
  expect(notificationPreviewBody(event({ kind: "message", data: { role: "agent", text: "  ", done: true } })))
    .toBeNull();
  expect(notificationPreviewBody(event({ kind: "interrupt", data: {} }))).toBeNull();
  const preview = notificationPreviewBody(event({
    kind: "message",
    data: { role: "agent", text: "界".repeat(200), done: true },
  }))!;
  expect(Buffer.byteLength(preview)).toBeLessThanOrEqual(NOTIFY_PREVIEW_BYTES);
  expect(preview.endsWith("�")).toBe(false);

  // A card's line is what it wants to do and to what, so "Allow?" has a subject.
  expect(notificationPreviewBody(event({
    kind: "approval_card",
    data: { actionId: "a", actionClass: "run-command", target: "  echo   hi\n" },
  }))).toBe("Run a command: echo hi");
  expect(notificationPreviewBody(event({
    kind: "question_card",
    data: { questionId: "q", question: "Which one? ", options: ["a"] },
  }))).toBe("Which one?");
  const long = notificationPreviewBody(event({
    kind: "approval_card",
    data: { actionId: "a", actionClass: "edit-file", target: "界".repeat(200) },
  }))!;
  expect(Buffer.byteLength(long)).toBeLessThanOrEqual(NOTIFY_PREVIEW_BYTES);
});

test("a card summary speaks the card's verb, or the tool a native agent named", () => {
  expect(approvalCardSummary({ actionId: "a", actionClass: "send-message", target: "bob@example.com" }))
    .toBe("Send a message: bob@example.com");
  expect(approvalCardSummary({ actionId: "a", actionClass: "read-page", target: "" })).toBe("Read page");
  expect(approvalCardSummary({ actionId: "a", actionClass: "Bash", target: '{ "command": "pwd" }', nativeAgent: "claude-code" }))
    .toBe('Bash: { "command": "pwd" }');
});

test("a preview's plaintext is a versioned object, and decodes back to what was put in", () => {
  const content = { body: "Run a command: echo hi", event: "6s82CDjb", quick: true };
  const plaintext = encodeNotificationPreview(content);
  expect(JSON.parse(plaintext)).toEqual({ v: 1, body: "Run a command: echo hi", event: "6s82CDjb", quick: true });
  expect(decodeNotificationPreview(plaintext)).toEqual(content);
  // A reply is about nothing answerable, and says so in both fields.
  expect(decodeNotificationPreview(encodeNotificationPreview({ body: "hi", event: null, quick: false })))
    .toEqual({ body: "hi", event: null, quick: false });
  // Only a boolean true is quick; only a non-empty string is an event; an empty body is no preview.
  expect(decodeNotificationPreview('{"v":1,"body":"x","event":"","quick":"true"}'))
    .toEqual({ body: "x", event: null, quick: false });
  expect(decodeNotificationPreview('{"v":1,"body":"","event":"e","quick":true}')).toBeNull();
  expect(decodeNotificationPreview('{"v":1,"event":"e","quick":true}')).toBeNull();
});

test("a preview carries the thread title, and fits the relay's box whatever the body", () => {
  const titled = { body: "hi", event: "e", quick: false, title: "Trip plans" };
  expect(decodeNotificationPreview(encodeNotificationPreview(titled))).toEqual(titled);
  // The relay refuses a box over 256 plaintext bytes, so a long reply is cut to fit, not dropped.
  for (const body of ["a".repeat(256), "é".repeat(128), '"\\n'.repeat(100)]) {
    const plaintext = encodeNotificationPreview({ body, event: "6s82CDjb", quick: false, title: "t".repeat(200) });
    expect(Buffer.byteLength(plaintext)).toBeLessThanOrEqual(NOTIFY_PREVIEW_BYTES);
    expect(body.startsWith(decodeNotificationPreview(plaintext)!.body)).toBe(true);
  }
});

test("a plaintext from before the object was a bare body, and permits no button", () => {
  expect(decodeNotificationPreview("the secret reply")).toEqual({ body: "the secret reply", event: null, quick: false });
  // JSON, but not the object: still the words as they are.
  expect(decodeNotificationPreview('"quoted"')).toEqual({ body: '"quoted"', event: null, quick: false });
  expect(decodeNotificationPreview("[1]")).toEqual({ body: "[1]", event: null, quick: false });
  expect(decodeNotificationPreview('{"body":"no version","quick":true}'))
    .toEqual({ body: '{"body":"no version","quick":true}', event: null, quick: false });
  expect(decodeNotificationPreview("")).toBeNull();
});
