/** Pinned assembled production runtime; synthetic runners and an empty temporary home only. */
import { afterEach, expect, test, vi } from "vitest";
import { mkdtempSync, mkdirSync, realpathSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createConnection } from "node:net";
import { createInterface } from "node:readline";
import { serve, secretaryRunnerDecorator } from "../dist/serve.js";
import { appendThreadEvent, readThreadEvents, createThread, threadHome, setThreadSession, setThreadWorkspace } from "../dist/threads.js";
import type { NativeTurn } from "./native.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const close of cleanups.splice(0)) await close(); vi.unstubAllEnvs(); });

async function fixture(ownership: "harness" | "secretary" = "harness", retainedQueue = false) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-production-review-"))), dir = join(root, "state"), workspace = join(root, "workspace");
  mkdirSync(workspace); vi.stubEnv("HOME", root); vi.stubEnv("YOROZU_STATE_DIR", dir); vi.stubEnv("YOROZU_PROJECTS_DIR", join(root, "projects"));
  vi.stubEnv("PATH", "");
  const turns: NativeTurn[] = [], events: any[] = []; let host: any;
  createThread("Harness person", dir, "person", { agent: "codex", cwd: workspace });
  if (retainedQueue) {
    appendThreadEvent({ id: "retained-request", threadId: "person", agentId: "main", ts: Date.now(), kind: "message", data: { role: "user", text: "retained" } }, dir);
    writeFileSync(join(dir, "native-turn-queue.json"), JSON.stringify([{ threadId: "person", eventId: "retained-request" }]));
  }
  const runner = { run: vi.fn(async (turn: NativeTurn) => {
    turns.push(turn);
    const answer = await turn.approve!("fixture", { command: "synthetic only" }, turn.signal);
    return { text: String(answer), sessionId: "stable-native-session", cessation: "provider-terminal" as const };
  }) };
  const sidecar = serve({ stateDir: dir, relayUrl: "ws://127.0.0.1:9", log() {}, nativeRunners: { codex: runner },
    secretaryHarness: true, secretaryHarnessOwns: id => ownership === "harness" && id === "person",
    secretaryOwnsConversation: id => ownership === "secretary" && id === "person", secretaryThreadWorkspace: id => id === "person" ? workspace : undefined,
    decorateNativeRunners: (runners, selected) => { host = selected; return runners; } });
  const socket = createConnection(join(dir, "local.sock"));
  createInterface({ input: socket }).on("line", line => events.push(JSON.parse(line))).on("error", () => {});
  await new Promise<void>((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
  cleanups.push(async () => { socket.destroy(); await sidecar.close(); rmSync(root, { recursive: true, force: true }); });
  const send = (kind: string, data: any, id: string) => socket.write(JSON.stringify({ id, threadId: "person", agentId: "main", ts: Date.now(), kind, data }) + "\n");
  return { root, dir, workspace, turns, events, host, send, runner };
}

test.each(["harness", "secretary"] as const)("assembled %s-only ownership exempts both new and pending approvals from global YOLO and resumes one session", async ownership => {
  expect(secretaryRunnerDecorator).toBe(true);
  const f = await fixture(ownership);
  f.send("approval_settings", { yolo: true, hours: 1 }, "yolo-first");
  f.send("message", { role: "user", text: "first" }, "first");
  await vi.waitFor(() => expect(f.events.filter(e => e.kind === "approval_card")).toHaveLength(1));
  expect(f.turns[0].bypass).toBe(false);
  f.send("approval_settings", { yolo: false }, "yolo-off");
  f.send("approval_settings", { yolo: true, hours: 1 }, "yolo-on");
  await new Promise(resolve => setTimeout(resolve, 100));
  expect(f.events.filter(e => e.kind === "approval_answer")).toEqual([]);
  const answer = (index: number) => f.send("approval_answer", { actionId: f.events.filter(e => e.kind === "approval_card")[index].data.actionId, answer: "yes" }, `answer-${index}`);
  answer(0);
  await vi.waitFor(() => expect(threadHome("person", f.dir).sessionId).toBe("stable-native-session"));
  f.send("message", { role: "user", text: "second" }, "second");
  await vi.waitFor(() => expect(f.events.filter(e => e.kind === "approval_card")).toHaveLength(2));
  expect(f.turns[1].sessionId).toBe("stable-native-session"); expect(f.turns[1].bypass).toBe(false);
  answer(1);
  await vi.waitFor(() => expect(f.events.some(e => e.id === "native:second:final")).toBe(true));
  const before = f.events.filter(e => e.kind === "thread_list").length;
  f.host.emit({ id: "background-action", threadId: "person", agentId: "main", ts: Date.now(), kind: "harness_action", data: {
    version: 1, requestId: "native-action", origin: { version: 1, agentId: "alice", pluginId: "hermes", conversationId: "person", sessionId: "s", bindingEpoch: "e" },
    kind: "approval", title: "Background approval", state: "pending", choices: [{ id: "yes", label: "Yes" }] } });
  await vi.waitFor(() => expect(f.events.filter(e => e.kind === "thread_list").length).toBeGreaterThan(before));
});

test("workspace changes invalidate only the old workspace session", async () => {
  const f = await fixture(); setThreadSession("person", "old", f.dir);
  setThreadWorkspace("person", f.workspace, f.dir); expect(threadHome("person", f.dir).sessionId).toBe("old");
  const next = join(f.root, "next"); mkdirSync(next); setThreadWorkspace("person", next, f.dir);
  expect(threadHome("person", f.dir)).toEqual({ cwd: next });
});

test("assembled privileged ingress rejects absent/unpaired senders and accepts only authenticated provenance", async () => {
  // Evaluate the exact early privileged routing block, without opening a channel/account.
  const source = readFileSync(new URL("../dist/serve.js", import.meta.url), "utf8");
  const block = source.slice(source.indexOf('if (event.kind === "harness_action_answer")'), source.indexOf('const personControl = event.kind === "person_agent_control"'));
  const action = vi.fn(async () => {}), locals = new Map([["local-device", true]]), devices = new Map([
    ["paired", { compatibility: { state: "compatible", capabilities: ["harness-actions-v1"] } }],
    ["old-peer", { compatibility: { state: "compatible", capabilities: [] } }],
  ]);
  const dispatch = new Function("event", "from", "localDevice", "locals", "devices", "options", "reply", "control", "stopped", "updateGate", block);
  for (const [from, local] of [[undefined, undefined], ["channel-origin", undefined], ["old-peer", undefined], [undefined, "forged-local"]])
    dispatch({ kind: "harness_action_answer" }, from, local, locals, devices, { harnessAction: action }, () => {}, (v: any) => v, false, { status: {} });
  expect(action).not.toHaveBeenCalled();
  for (const [from, local] of [["paired", undefined], [undefined, "local-device"]])
    dispatch({ kind: "harness_action_answer" }, from, local, locals, devices, { harnessAction: action }, () => {}, (v: any) => v, false, { status: {} });
  expect(action).toHaveBeenCalledTimes(2);
});


test("duplicate specialist dispatch is idempotent and emits no false not-started terminal", async () => {
  const f = await fixture();
  appendThreadEvent({ id: "parent-request", threadId: "yorozu-secretary-v1", agentId: "main", ts: Date.now(), kind: "message", data: { role: "user", text: "synthetic task" } }, f.dir);
  const task = { id: "secretary-task-" + "a".repeat(64), requestId: "specialist-request", parentEventId: "parent-request", title: "Fixture", specialty: "fixture", instruction: "Synthetic only" };
  f.host.dispatch(task, []); f.host.dispatch(task, []);
  expect(readThreadEvents(task.id, f.dir).filter(e => e.id === task.requestId)).toHaveLength(1);
  expect(readThreadEvents(task.id, f.dir).filter(e => e.kind === "message" && e.data.text.includes("The task was not started"))).toEqual([]);
});

test("assembled person controls and creation require authenticated local or compatible paired provenance", () => {
  const source = readFileSync(new URL("../dist/serve.js", import.meta.url), "utf8");
  const start = source.indexOf('const personControl = event.kind === "person_agent_control"');
  const block = source.slice(start, source.indexOf('if (options.secretaryOwnsConversation?.(event.threadId)', start));
  const selected = vi.fn(async () => {}), locals = new Map([["local-device", true]]), devices = new Map([
    ["paired", { compatibility: { state: "compatible", capabilities: ["person-agents-v1"] } }],
    ["old-peer", { compatibility: { state: "compatible", capabilities: [] } }],
  ]);
  const dispatch = new Function("event", "from", "localDevice", "locals", "devices", "options", "reply", "control", "broadcast", "threadList", block);
  for (const kind of ["person_agent_control", "thread_create"]) {
    const event = { kind, data: { personAgentId: "alice" } }, options = { personAgentControl: selected, personAgentCreate: selected };
    for (const [from, local] of [[undefined, undefined], ["channel-origin", undefined], ["old-peer", undefined], [undefined, "forged-local"]])
      dispatch(event, from, local, locals, devices, options, () => {}, (v: any) => v, () => {}, () => ({}));
  }
  expect(selected).not.toHaveBeenCalled();
  for (const kind of ["person_agent_control", "thread_create"]) for (const [from, local] of [["paired", undefined], [undefined, "local-device"]])
    dispatch({ kind, data: { personAgentId: "alice" } }, from, local, locals, devices, { personAgentControl: selected, personAgentCreate: selected }, () => {}, (v: any) => v, () => {}, () => ({}));
  expect(selected).toHaveBeenCalledTimes(4);
});

test("a selected person workspace does not overwrite legacy harness-thread metadata", async () => {
  const f = await fixture("harness"), legacy = join(f.root, "legacy"); mkdirSync(legacy);
  setThreadWorkspace("person", legacy, f.dir); setThreadSession("person", "legacy-session", f.dir);
  f.send("message", { role: "user", text: "person workspace" }, "legacy-overlay");
  await vi.waitFor(() => expect(f.turns).toHaveLength(1));
  expect(f.turns[0].cwd).toBe(f.workspace);
  expect(threadHome("person", f.dir)).toEqual({ cwd: legacy, sessionId: "legacy-session" });
});


test("stop-journal write failure is visible and retains independent durable admission fencing", async () => {
  const f = await fixture("secretary");
  mkdirSync(join(f.dir, "stopped-turns.jsonl")); // controlled EISDIR after startup, not a protected recovery injection
  f.runner.run.mockImplementation(async turn => { f.turns.push(turn); return { text: "Synthetic lost receipt", unconfirmed: true } as any; });
  f.send("message", { role: "user", text: "uncertain" }, "uncertain-write");
  await vi.waitFor(() => expect(f.events.some(e => e.kind === "admission_status" && e.data.reason === "secretary-storage-unconfirmed")).toBe(true));
  const { SecretaryAdmissionFence } = await import("../dist/secretary-steering.js");
  expect(new SecretaryAdmissionFence(f.dir).blocked).toBe(true);
  f.send("message", { role: "user", text: "must wait" }, "held-next");
  await new Promise(resolve => setTimeout(resolve, 100)); expect(f.turns).toHaveLength(1);
  expect(readThreadEvents("person", f.dir).some(e => e.kind === "message" && e.data.text.includes("Queued work is held"))).toBe(true);
  rmSync(join(f.dir, "stopped-turns.jsonl"), { recursive: true });
});

test("retained harness queue publishes a durable visible hold and never submits it", async () => {
  const f = await fixture("harness", true);
  await vi.waitFor(() => expect(f.events.some(e => e.kind === "thread_list" && e.data.threads.some((t: any) => t.id === "person" && t.turnState === "stopped-unconfirmed"))).toBe(true));
  const notices = readThreadEvents("person", f.dir).filter(e => e.id === "harness-queue-held:retained-request");
  expect(notices).toHaveLength(1); expect(notices[0].data.text).toContain("not automatically resent");
  expect(f.turns).toEqual([]);
  expect(JSON.parse(readFileSync(join(f.dir, "native-turn-queue.json"), "utf8"))).toEqual([{ threadId: "person", eventId: "retained-request" }]);
});

test("a persisted uncertain stop transfers its hold without poisoning unrelated admission", async () => {
  const f = await fixture("secretary");
  f.runner.run.mockImplementation(async turn => { f.turns.push(turn); return { text: "Synthetic lost receipt", unconfirmed: true } as any; });
  f.send("message", { role: "user", text: "uncertain" }, "persisted-unknown");
  // No interrupt request was sent, so no correlated stop_status receipt exists.
  await vi.waitFor(() => expect(f.events.some(e => e.id === "native:persisted-unknown:final" && e.data.text.includes("Queued work is held"))).toBe(true));
  expect(readFileSync(join(f.dir, "stopped-turns.jsonl"), "utf8")).toContain('"targetEventId":"persisted-unknown"');
  const { SecretaryAdmissionFence } = await import("../dist/secretary-steering.js");
  expect(new SecretaryAdmissionFence(f.dir).blocked).toBe(false);
  f.send("message", { role: "user", text: "same thread must still wait" }, "held-next");
  await new Promise(resolve => setTimeout(resolve, 100)); expect(f.turns).toHaveLength(1);
  expect(f.events.some(e => e.kind === "thread_list" && e.data.threads.some((t: any) => t.id === "person" && t.turnState === "stopped-unconfirmed"))).toBe(true);
});

test("Stop still reaches an active runner when stop-journal persistence fails", async () => {
  const f = await fixture("secretary"), stopped = vi.fn();
  f.runner.run.mockImplementation(async turn => {
    f.turns.push(turn);
    return await new Promise<any>(resolve => turn.signal.addEventListener("abort", () => {
      stopped(); resolve({ text: "Synthetic positive cessation", cessation: "provider-terminal" });
    }, { once: true }));
  });
  f.send("message", { role: "user", text: "active" }, "active-with-stop");
  await vi.waitFor(() => expect(f.turns).toHaveLength(1));
  mkdirSync(join(f.dir, "stopped-turns.jsonl"));
  f.send("interrupt", { targetEventId: "active-with-stop" }, "stop-with-storage-failure");
  await vi.waitFor(() => expect(stopped).toHaveBeenCalledOnce());
  const { SecretaryAdmissionFence } = await import("../dist/secretary-steering.js");
  expect(new SecretaryAdmissionFence(f.dir).blocked).toBe(true);
  rmSync(join(f.dir, "stopped-turns.jsonl"), { recursive: true });
});
