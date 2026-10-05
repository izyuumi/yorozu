/** Durable real host journal; callbacks are synthetic native transport, not live harness proof. */
import { afterEach, expect, test, vi } from "vitest";
import { mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { HarnessActionData, HarnessOrigin, YorozuEvent } from "@yorozu/shared";
import { HarnessPlatformStore, exchangeThreadId } from "./harness-platform-store.js";
const roots: string[] = [];
afterEach(() => { for (const dir of roots.splice(0)) rmSync(dir, { recursive: true, force: true }); });
const origin: HarnessOrigin = { version: 1, agentId: "alice", pluginId: "hermes", conversationId: "alice-main", sessionId: "session-opaque", bindingEpoch: "epoch-a", workId: "work-a" };
const action: HarnessActionData = { version: 1, requestId: "approval-1", origin, kind: "approval", title: "Native approval", choices: [{ id: "once", label: "Allow once" }, { id: "deny", label: "Deny" }], state: "pending" };
const response = (operationId = "answer-1", patch = {}): YorozuEvent => ({ id: operationId, threadId: origin.conversationId, ts: 1000, agentId: "client",
  kind: "harness_action_answer", data: { version: 1, requestId: action.requestId, origin, choiceId: "once", ...patch } });
function fixture() {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-platform-store-"))); roots.push(dir);
  const events: YorozuEvent[] = [], store = new HarnessPlatformStore(dir); store.bind(e => events.push(e));
  return { dir, store, events };
}
test("an exact native choice reaches the harness once only after durable host intent", async () => {
  const f = fixture(), respond = vi.fn(async () => {
    expect(readFileSync(join(f.store.root, "journal.json"), "utf8")).toContain('"status":"requested"');
    return { status: "applied" as const };
  });
  f.store.openAction(action, respond, () => true);
  const reordered = Object.fromEntries(Object.entries(origin).reverse());
  await f.store.answer(response("__proto__", { origin: reordered })); await f.store.answer(response("__proto__"));
  expect(respond).toHaveBeenCalledTimes(1);
  expect(f.events.filter(e => e.kind === "harness_action_status").at(-1)?.data).toMatchObject({ status: "applied", origin });
  expect(f.events.filter(e => e.kind === "message")).toEqual([]);
});
test("foreign choices, altered session/epoch and no-longer-current owners never grant approval", async () => {
  const f = fixture(), respond = vi.fn(async () => ({ status: "applied" as const }));
  f.store.openAction(action, respond, () => false);
  await f.store.answer(response("stale"));
  await f.store.answer(response("foreign-choice", { choiceId: "always" }));
  await expect(f.store.answer(response("wrong-epoch", { origin: { ...origin, bindingEpoch: "epoch-b" } }))).rejects.toThrow("Unknown");
  expect(respond).not.toHaveBeenCalled();
  expect(f.events.filter(e => e.kind === "harness_action_status").map(e => e.data.status)).toContain("no-longer-needed");
});
test("projection failures cannot reject durable custody or skip an admitted native answer", async () => {
  const f = fixture(), respond = vi.fn(async () => ({ status: "applied" as const }));
  f.store.bind(() => { throw new Error("display transport unavailable"); });
  f.store.openAction(action, respond, () => true);
  await f.store.answer(response()); expect(respond).toHaveBeenCalledTimes(1);
  const message = f.store.acceptMessage(origin, "projection-gap", "bob", "Retained despite display loss");
  const recovered = new HarnessPlatformStore(f.dir), projected: YorozuEvent[] = [];
  recovered.bind(event => projected.push(event));
  expect(recovered.pendingFor("bob")).toEqual([message]);
  expect(projected.find(e => e.kind === "harness_action_status")?.data.status).toBe("applied");
  expect(projected.find(e => e.kind === "agent_exchange")?.data.text).toBe(message.text);
});
test("a lost answer receipt fences every later operation and recovered actions cannot re-raise", async () => {
  const f = fixture(), respond = vi.fn(async () => { throw new Error("lost adapter receipt"); });
  f.store.openAction(action, respond, () => true);
  await f.store.answer(response()); await f.store.answer(response("answer-2"));
  expect(respond).toHaveBeenCalledTimes(1);
  const recovered = new HarnessPlatformStore(f.dir), next = vi.fn(async () => ({ status: "applied" as const }));
  recovered.bind(e => f.events.push(e)); recovered.openAction(action, next, () => true);
  await recovered.answer(response("answer-after-restart")); expect(next).not.toHaveBeenCalled();
  expect(f.events.filter(e => e.kind === "harness_action").at(-1)?.data.state).toBe("cancelled");
});
test("an operation ID cannot change native choice and cancelled work cannot be answered", async () => {
  const f = fixture(), respond = vi.fn(async () => ({ status: "rejected" as const }));
  f.store.openAction(action, respond, () => true); await f.store.answer(response());
  await expect(f.store.answer(response("answer-1", { choiceId: "deny" }))).rejects.toThrow("identity conflict");
  f.store.cancelAction(origin, action.requestId); await f.store.answer(response("cancelled-answer"));
  expect(respond).toHaveBeenCalledTimes(1);
});
test("a peer message is retained separately and duplicate sender IDs cannot alter content or origin", () => {
  const f = fixture(), message = f.store.acceptMessage(origin, "native-message", "bob", "Explicit peer data");
  expect(f.store.acceptMessage(origin, "native-message", "bob", "Explicit peer data")).toEqual(message);
  expect(() => f.store.acceptMessage(origin, "native-message", "bob", "Changed data")).toThrow("conflict");
  expect(f.store.pendingFor("bob")).toEqual([message]);
  expect(f.events.filter(e => e.kind === "agent_exchange")).toHaveLength(1);
  expect(f.events.every(e => e.threadId === exchangeThreadId(message.exchangeId))).toBe(true);
  const recovered = new HarnessPlatformStore(f.dir);
  expect(recovered.pendingFor("bob")).toEqual([message]);
});
test("crash after native inbox handoff is unknown and never silently resent", () => {
  const f = fixture(), message = f.store.acceptMessage(origin, "message-crash", "bob", "Retain me");
  const attempt = f.store.beginDelivery(message.messageId); expect(attempt).toBeTruthy();
  const recovered = new HarnessPlatformStore(f.dir), events: YorozuEvent[] = []; recovered.bind(e => events.push(e));
  expect(recovered.pendingFor("bob")).toEqual([]);
  expect(events.find(e => e.kind === "agent_exchange_status")?.data).toMatchObject({ delivery: "unknown", execution: "unknown", attemptId: attempt });
  expect(readFileSync(join(recovered.root, "journal.json"), "utf8")).toContain("Retain me");
});
test("busy/not-submitted can wait safely; inbox delivery is distinct from native execution", () => {
  const f = fixture(), message = f.store.acceptMessage(origin, "message-busy", "bob", "Native decides when to read");
  const first = f.store.beginDelivery(message.messageId);
  f.store.settleDelivery(message.messageId, first, "accepted", "Native inbox full", true);
  expect(f.store.pendingFor("bob")).toEqual([message]);
  const second = f.store.beginDelivery(message.messageId); expect(second).not.toBe(first);
  f.store.settleDelivery(message.messageId, second, "delivered");
  expect(f.events.filter(e => e.kind === "agent_exchange_status").at(-1)?.data).toMatchObject({ delivery: "delivered", execution: "unknown" });
  expect(new HarnessPlatformStore(f.dir).pendingFor("bob")).toEqual([]);
});
test("reply exchanges are bound to the same two configured identities", () => {
  const f = fixture(), message = f.store.acceptMessage(origin, "question", "bob", "Question");
  const bob = { ...origin, agentId: "bob", pluginId: "openclaw" as const, conversationId: "bob-main", sessionId: "bob-session" };
  expect(f.store.acceptMessage(bob, "reply", "alice", "Reply", message.exchangeId).exchangeId).toBe(message.exchangeId);
  expect(() => f.store.acceptMessage({ ...origin, agentId: "carol" }, "foreign", "alice", "Spoofed reply", message.exchangeId)).toThrow("Unknown peer");
});


test("message idempotency survives sender epoch/session/work rotation without redelivery", () => {
  const f = fixture(), message = f.store.acceptMessage(origin, "stable-native-id", "bob", "same payload");
  const attempt = f.store.beginDelivery(message.messageId);
  f.store.settleDelivery(message.messageId, attempt, "delivered");
  const recovered = new HarnessPlatformStore(f.dir);
  expect(recovered.acceptMessage({ ...origin, bindingEpoch: "new-epoch", sessionId: "new-session", workId: "new-work" },
    "stable-native-id", "bob", "same payload")).toEqual(message);
  expect(recovered.pendingFor("bob")).toEqual([]);
});

test("UI navigation neither answers nor fences a subsequent explicit choice, including restart", async () => {
  const f = fixture(), respond = vi.fn(async (answer: any) => ({ status: answer.uiTargetId ? "requested" as const : "applied" as const }));
  const withUI = { ...action, ui: { targetId: "native-ui", label: "Open harness UI" } };
  f.store.openAction(withUI, respond, () => true);
  await f.store.answer(response("open-ui", { choiceId: undefined, uiTargetId: "native-ui" }));
  expect(f.store.hasUnconfirmedActions("alice")).toBe(false);
  expect(new HarnessPlatformStore(f.dir).hasUnconfirmedActions("alice")).toBe(false);
  await f.store.answer(response("explicit-choice"));
  expect(respond).toHaveBeenCalledTimes(2);
  expect(respond.mock.calls.filter(([a]) => a.choiceId)).toHaveLength(1);
  f.store.cancelAction(origin, action.requestId);
  expect(f.store.hasUnconfirmedActions("alice")).toBe(false);
});

test("crash during a pending UI opener cannot manufacture an unknown native answer", async () => {
  const f = fixture(); let release!: (result: { status: "requested" }) => void;
  const respond = vi.fn(() => new Promise<{ status: "requested" }>(resolve => { release = resolve; }));
  f.store.openAction({ ...action, ui: { targetId: "native-ui", label: "Open" } }, respond, () => true);
  const opening = f.store.answer(response("pending-ui", { choiceId: undefined, uiTargetId: "native-ui" }));
  expect(respond).toHaveBeenCalledOnce();
  const recovered = new HarnessPlatformStore(f.dir);
  expect(recovered.hasUnconfirmedActions("alice")).toBe(false);
  release({ status: "requested" }); await opening;
  expect(f.store.hasUnconfirmedActions("alice")).toBe(false);
});
