import { expect, test } from "vitest";
import { notifyFor, NOTIFY_BODY } from "./notify.js";
import { threadRef } from "./crypto.js";
import type { YorozuEvent } from "./events.js";

const event = (payload: Partial<YorozuEvent> & Pick<YorozuEvent, "kind" | "data">): YorozuEvent =>
  ({ id: "e", threadId: "t", ts: 1, agentId: "main", ...payload }) as YorozuEvent;

test("a finished main-agent reply is a reply, and a silent one is a completion", () => {
  expect(notifyFor(event({ kind: "message", data: { role: "agent", text: "hi", done: true } })))
    .toEqual({ class: "reply", status: "done" });
  expect(notifyFor(event({ kind: "message", data: { role: "agent", text: "  ", done: true } })))
    .toEqual({ class: "done", status: "done" });
});

test("deltas, delegated finals and tool traffic only move the activity", () => {
  expect(notifyFor(event({ kind: "message", data: { role: "agent", text: "par" } })))
    .toEqual({ class: "activity", status: "working" });
  // A specialist finishing is one step of the turn, not the end of it.
  expect(
    notifyFor(
      event({
        kind: "message",
        data: { role: "agent", text: "done", done: true },
        parentAgentId: "main",
      }),
    ),
  ).toEqual({ class: "activity", status: "working" });
  expect(notifyFor(event({ kind: "tool_call", data: { callId: "c", name: "n", args: {} } })))
    .toEqual({ class: "activity", status: "working" });
});

test("cards are the class worth interrupting someone for, and a stop is a failure", () => {
  expect(notifyFor(event({ kind: "approval_card", data: { actionId: "a", actionClass: "send", target: "x" } })))
    .toEqual({ class: "approval", status: "needsApproval" });
  expect(notifyFor(event({ kind: "question_card", data: { questionId: "q", question: "?", options: [] } })))
    .toEqual({ class: "approval", status: "needsApproval" });
  expect(notifyFor(event({ kind: "interrupt", data: {} }))).toEqual({
    class: "failed",
    status: "failed",
  });
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
