import { EventEmitter } from "node:events";
import { mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import type { GatewayClientOptions } from "@openclaw/gateway-client";
import type { YorozuEvent } from "@yorozu/shared";
import { describe, expect, test, vi } from "vitest";
import { OpenClawRunner } from "./openclaw.js";

const stored = {
  identity: { deviceId: "device", publicKeyPem: "public", privateKeyPem: "private" },
  token: "device-token",
  scopes: ["operator.read", "operator.write"],
};

function harness() {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-openclaw-"));
  writeFileSync(join(dir, "openclaw-gateway.json"), JSON.stringify(stored));
  let options!: GatewayClientOptions;
  const request = vi.fn(async (method: string) => method === "chat.send" ? { runId: "run-1" } : {});
  const clientFactory = vi.fn((value: GatewayClientOptions) => {
    options = value;
    return { start: () => options.onHelloOk?.({ auth: {} } as never), stop: vi.fn(), request };
  });
  return {
    dir,
    request,
    clientFactory,
    hello: () => options.onHelloOk?.({ auth: {} } as never),
    event: (payload: object, event = "chat") => options.onEvent?.({ type: "event", event, payload } as never),
  };
}

describe("OpenClawRunner", () => {
  test("admission writes ledger before logs and replays either crash side idempotently", () => {
    const gateway = harness();
    const runner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    const turn = { threadId: "atomic", text: "once", userEventId: "user-1" };
    expect(() => runner.admitUserTurn(turn, () => { throw new Error("log crash"); })).toThrow("log crash");
    expect(runner.pendingTurns()).toHaveLength(1);
    let repairs = 0;
    const replayed = runner.admitUserTurn(turn, () => { repairs += 1; });
    expect(repairs).toBe(1);
    expect(runner.pendingTurns()).toHaveLength(1);
    expect(replayed.runId).toBe(runner.pendingTurns()[0]!.runId);

    const blocked = join(gateway.dir, "not-a-directory");
    writeFileSync(blocked, "file");
    let accepted = false;
    expect(() => new OpenClawRunner({ stateDir: blocked }).admitUserTurn(
      { threadId: "atomic", text: "never", userEventId: "user-2" },
      () => { accepted = true; },
    )).toThrow();
    expect(accepted).toBe(false);
  });

  test.each(["{damaged", "[{}]", '[{"threadId":"first","sessionKey":"s","runId":"r","startedAt":1}]'])(
    "damaged pending ledger blocks new admission: %s", (damaged) => {
    const gateway = harness();
    const ledger = join(gateway.dir, "openclaw-pending.json");
    const runner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    runner.admitUserTurn({ threadId: "first", text: "keep", userEventId: "first-id" }, () => {});
    writeFileSync(ledger, damaged);
    let accepted = false;
    expect(() => runner.admitUserTurn({ threadId: "second", text: "do not accept", userEventId: "second-id" },
      () => { accepted = true; })).toThrow();
    expect(accepted).toBe(false);
    expect(readFileSync(ledger, "utf8")).toBe(damaged);
    });

  test("same user event ID cannot admit different input", () => {
    const gateway = harness();
    const runner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    runner.admitUserTurn({ threadId: "atomic", text: "first", userEventId: "same",
      attachments: [{ name: "a.txt", mime: "text/plain", data: "YQ==" }] }, () => {});
    let accepted = false;
    expect(() => runner.admitUserTurn({ threadId: "atomic", text: "changed", userEventId: "same",
      attachments: [{ name: "a.txt", mime: "text/plain", data: "YQ==" }] },
    () => { accepted = true; })).toThrow("conflicting user event ID");
    expect(() => runner.admitUserTurn({ threadId: "other", text: "first", userEventId: "same",
      attachments: [{ name: "a.txt", mime: "text/plain", data: "YQ==" }] }, () => {}))
      .toThrow("conflicting user event ID");
    expect(() => runner.admitUserTurn({ threadId: "atomic", text: "first", userEventId: "same",
      attachments: [{ name: "a.txt", mime: "text/plain", data: "Yg==" }] }, () => {}))
      .toThrow("conflicting user event ID");
    expect(runner.admitUserTurn({ threadId: "atomic", text: "first", userEventId: "same",
      attachments: [{ data: "YQ==", mime: "text/plain", name: "a.txt" }] }, () => {}))
      .toMatchObject({ userEventId: "same" });
    expect(accepted).toBe(false);
    expect(runner.pendingTurns()).toHaveLength(1);
  });

  test("archives and restores the canonical Gateway session without starting a turn", async () => {
    const gateway = harness();
    gateway.request.mockImplementation(async (method) => method === "sessions.describe"
      ? { session: { sessionId: "observed-session", archived: false } } : {});
    const runner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    await runner.setArchived("A1B2-C3D4", true);
    await runner.setArchived("A1B2-C3D4", false);
    expect(gateway.request.mock.calls).toEqual([
      ["sessions.describe", { key: "agent:main:yorozu:a1b2-c3d4" }],
      ["sessions.patch", { key: "agent:main:yorozu:a1b2-c3d4", archived: true, expectedSessionId: "observed-session" }],
      ["sessions.describe", { key: "agent:main:yorozu:a1b2-c3d4" }],
      ["sessions.patch", { key: "agent:main:yorozu:a1b2-c3d4", archived: false, expectedSessionId: "observed-session" }],
    ]);
    gateway.request.mockImplementation(async (method) => {
      if (method === "sessions.patch") throw new Error("Session is still active; retry the archive.");
      return { session: { sessionId: "observed-session", archived: false } };
    });
    await expect(runner.setArchived("A1B2-C3D4", true)).rejects.toThrow("still active");
  });

  test("archive skips absent sessions and reconciles a committed-but-rejected patch without replay", async () => {
    const gateway = harness();
    const runner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    gateway.request.mockResolvedValueOnce({ session: null });
    await runner.setArchived("empty", true);
    expect(gateway.request).toHaveBeenCalledTimes(1);
    gateway.request.mockReset();
    gateway.request.mockResolvedValueOnce({ session: { sessionId: "same", archived: false } })
      .mockRejectedValueOnce(new Error("Session archived, but worktree cleanup did not finish"))
      .mockResolvedValueOnce({ session: { sessionId: "same", archived: true } });
    await expect(runner.setArchived("one", true)).resolves.toBeUndefined();
    expect(gateway.request.mock.calls.map(([method]) => method)).toEqual(["sessions.describe", "sessions.patch", "sessions.describe"]);
    gateway.request.mockReset();
    gateway.request.mockResolvedValueOnce({ session: { sessionId: "old", archived: false } })
      .mockRejectedValueOnce(new Error("Session changed before patch"))
      .mockResolvedValueOnce({ session: { sessionId: "replacement", archived: true } });
    await expect(runner.setArchived("one", true)).rejects.toThrow("Session changed");
  });

  test("streams scoped, bounded tool activity with stable IDs before the final reply", async () => {
    const gateway = harness();
    const events: YorozuEvent[] = [];
    const result = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "one", text: "inspect", onEvent: (event) => events.push(event),
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    expect(gateway.clientFactory.mock.calls[0]![0].caps).toContain("tool-events");
    const tool = { sessionKey: "agent:main:yorozu:one", runId: "run-1", stream: "tool", seq: 1,
      data: { phase: "start", toolCallId: "call-1", name: "exec", args: { command: "echo hello", token: "fixture-secret" } } };
    gateway.event({ ...tool, runId: "old-run" }, "agent");
    gateway.event({ ...tool, sessionKey: "agent:main:other" }, "agent");
    gateway.event(tool, "agent");
    gateway.event(tool, "agent");
    gateway.event({ ...tool, seq: 2, data: { ...tool.data, phase: "result", isError: true,
      result: { text: "failed password=fixture-secret", screenshot: "base64-private", huge: "x".repeat(100_000) } } }, "agent");
    expect(events.map((event) => event.kind)).toEqual(["thought", "tool_call", "tool_result"]);
    expect(events[0]).toMatchObject({ data: { text: "Starting OpenClaw…", transient: true } });
    expect(events[1]).toMatchObject({ data: { callId: "run-1:call-1", args: { token: "[redacted]" } } });
    expect(events[2]).toMatchObject({ data: { callId: "run-1:call-1", ok: false } });
    expect(JSON.stringify(events)).not.toContain("fixture-secret");
    expect(JSON.stringify(events)).not.toContain("base64-private");
    expect(JSON.stringify(events).length).toBeLessThan(16_000);
    gateway.event({ state: "final", sessionKey: tool.sessionKey, runId: "run-1", seq: 3 });
    await result;
    gateway.event({ ...tool, data: { ...tool.data, toolCallId: "after-final" } }, "agent");
    expect(events).toHaveLength(3);
  });

  test("reconnect restores missed progress once and resumes tool results without resending", async () => {
    const gateway = harness();
    const events: YorozuEvent[] = [];
    const result = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "one", text: "inspect", onEvent: (event) => events.push(event),
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    const tool = { sessionKey: "agent:main:yorozu:one", runId: "run-1", stream: "tool", seq: 1,
      data: { phase: "start", toolCallId: "call-1", name: "read", args: {} } };
    gateway.request.mockImplementation(async (method) => method === "chat.history" ? {
      inFlightRun: { runId: "run-1", events: [tool], text: "" },
    } : {});
    gateway.hello();
    await vi.waitFor(() => expect(events.filter((event) => event.kind === "tool_call")).toHaveLength(1));
    gateway.event(tool, "session.tool");
    gateway.event({ ...tool, seq: 2, data: { ...tool.data, phase: "result", result: "file contents" } }, "session.tool");
    expect(events.map((event) => event.kind)).toEqual(["thought", "tool_call", "tool_result"]);
    expect(gateway.request.mock.calls.filter(([method]) => method === "chat.send")).toHaveLength(1);
    expect(gateway.request).toHaveBeenCalledWith("sessions.subscribe", {});
    gateway.event({ state: "final", sessionKey: tool.sessionKey, runId: "run-1", seq: 3 });
    await result;
  });

  test("progress_card calls raise the card with their narrative, which later plan updates keep", async () => {
    const gateway = harness();
    const events: YorozuEvent[] = [];
    const result = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "one", text: "release", onEvent: (event) => events.push(event),
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    const sessionKey = "agent:main:yorozu:one";
    const plan = [{ step: "Test", status: "completed" }, { step: "Ship", status: "in_progress" }];
    gateway.event({ sessionKey, runId: "run-1", stream: "tool", seq: 1, data: {
      phase: "start", toolCallId: "p1", name: "progress_card", args: { markdown: "Tests **green**.", plan },
    } }, "agent");
    // The plan stream that follows the call has no narrative of its own; it keeps the call's.
    gateway.event({ sessionKey, runId: "run-1", stream: "plan", seq: 2, data: { steps: plan } }, "agent");
    const cards = events.filter((event) => event.kind === "progress_card");
    expect(cards.map((event) => event.data)).toEqual([0, 1].map(() => ({
      cardId: "openclaw-plan:run-1", title: "Progress", note: "Tests **green**.",
      steps: [{ label: "Test", state: "done" }, { label: "Ship", state: "running" }],
    })));
    gateway.event({ state: "final", sessionKey, runId: "run-1", seq: 3 });
    await result;
  });

  test("publishes real task-summary completion and ignores previous-turn tasks", async () => {
    const gateway = harness();
    const events: YorozuEvent[] = [];
    const result = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "one", text: "delegate", onEvent: (event) => events.push(event),
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    const task = { id: "task-row", runId: "child-run", title: "Research", sessionKey: "agent:main:yorozu:one", status: "running", deliveryStatus: "pending", createdAt: Date.now() };
    gateway.event({ action: "upserted", task: { ...task, createdAt: 1 } }, "task");
    gateway.event({ action: "upserted", task }, "task");
    gateway.event({ action: "upserted", task: { ...task, status: "completed" } }, "task");
    expect(events.slice(1).map((event) => event.kind)).toEqual(["thought", "message"]);
    expect(events[2]).toMatchObject({ parentAgentId: "main", data: { done: true } });
    gateway.event({ state: "final", sessionKey: task.sessionKey, runId: "run-1", seq: 1 });
    gateway.event({ state: "final", sessionKey: task.sessionKey, runId: "announce:requester-settle:child-run", seq: 1, message: { content: "Done" } });
    await expect(result).resolves.toBe("Done");
  });

  test("reattaches after sidecar replacement without resending the OpenClaw turn", async () => {
    const gateway = harness();
    void new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "release", text: "install the update",
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.objectContaining({ message: "install the update" })));
    const tool = { sessionKey: "agent:main:yorozu:release", runId: "run-1", stream: "tool", seq: 2,
      data: { phase: "result", toolCallId: "exec-1", name: "bash", result: "installed" } };
    gateway.request.mockImplementation(async (method) => method === "chat.history" ? {
      inFlightRun: { runId: "run-1", events: [tool], text: "Update installed." },
    } : {});

    const events: YorozuEvent[] = [];
    const updates: string[] = [];
    const replacement = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    expect(replacement.pendingTurns().map((turn) => turn.threadId)).toEqual(["release"]);
    const resumed = replacement.resume({
      threadId: "release", onEvent: (event) => events.push(event), onUpdate: (text) => updates.push(text),
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.history", {
      sessionKey: "agent:main:yorozu:release", limit: 1000, inputRunIds: ["run-1"],
    }));
    expect(gateway.request.mock.calls.filter(([method]) => method === "chat.send")).toHaveLength(1);
    await vi.waitFor(() => expect(updates).toEqual(["Update installed."]));
    expect(events.map((event) => event.kind)).toEqual(["tool_call", "tool_result"]);
    gateway.event({ state: "final", sessionKey: tool.sessionKey, runId: "run-1", seq: 3,
      message: { content: "Update installed." } });
    await expect(resumed).resolves.toBe("Update installed.");
    expect(replacement.pendingTurns().map((turn) => turn.threadId)).toEqual(["release"]);
    replacement.acknowledge("release", replacement.pendingTurns()[0]!.completionId);
    expect(replacement.pendingTurns()).toEqual([]);
  });
  test("keeps recovery ownership until durable-final acknowledgment", async () => {
    const gateway = harness();
    const runner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    const result = runner.run({ threadId: "ack", text: "update", completionId: "final-ack", userEventId: "user-ack" });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    gateway.event({ state: "final", sessionKey: "agent:main:yorozu:ack", runId: "run-1", seq: 1, message: { content: "done" } });
    await expect(result).resolves.toBe("done");
    expect(runner.pendingTurns()).toMatchObject([{ completionId: "final-ack", userEventId: "user-ack" }]);
    runner.acknowledge("ack", "wrong");
    expect(runner.pendingTurns()).toHaveLength(1);
    runner.acknowledge("ack", "final-ack");
    expect(runner.pendingTurns()).toEqual([]);
  });

  test("late completed and aborted replays never rerun without bounded tombstones", async () => {
    const gateway = harness();
    const runner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    const turn = { threadId: "once", text: "release", userEventId: "user-once", completionId: "openclaw:user-once:final" };
    runner.admitUserTurn(turn, () => {});
    const result = runner.run(turn);
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    gateway.event({ state: "final", sessionKey: "agent:main:yorozu:once", runId: "run-1", seq: 1,
      message: { content: "done" } });
    await expect(result).resolves.toBe("done");
    runner.acknowledge("once", "openclaw:user-once:final");
    let repaired = 0;
    expect(runner.admitUserTurn(turn, () => { repaired += 1; }, () => true)).toBeUndefined();
    expect(repaired).toBe(1);
    expect(gateway.request.mock.calls.filter(([method]) => method === "chat.send")).toHaveLength(1);
    expect(runner.pendingTurns()).toEqual([]);

    for (let index = 0; index < 300; index += 1) {
      expect(runner.admitUserTurn({ threadId: "old", text: "old", userEventId: `old-${index}` },
        () => {}, () => true)).toBeUndefined();
    }
    expect(runner.admitUserTurn({ threadId: "aborted", text: "stop", userEventId: "aborted-user" },
      () => {}, () => true)).toBeUndefined();
    expect(gateway.request.mock.calls.filter(([method]) => method === "chat.send")).toHaveLength(1);
  });

  test("abort during pending chat.send aborts before and after response", async () => {
    const gateway = harness();
    const sent = Promise.withResolvers<{ runId: string }>();
    gateway.request.mockImplementation(async (method) => method === "chat.send" ? sent.promise : {});
    const runner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    const controller = new AbortController();
    const result = runner.run({ threadId: "send-abort", text: "stop", signal: controller.signal });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    const submitted = gateway.request.mock.calls.find(([method]) => method === "chat.send")![1] as { idempotencyKey: string };
    controller.abort();
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.abort", {
      sessionKey: "agent:main:yorozu:send-abort", runId: submitted.idempotencyKey,
    }));
    sent.resolve({ runId: "accepted-run" });
    await expect(result).resolves.toBe("");
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.abort", {
      sessionKey: "agent:main:yorozu:send-abort", runId: "accepted-run",
    }));
  });

  test("abort during connect or session patch never dispatches chat.send", async () => {
    let connected!: () => void;
    const connectRequest = vi.fn(async () => ({}));
    const connectFactory = vi.fn((options: GatewayClientOptions) => ({
      start: () => { connected = () => options.onHelloOk?.({ auth: {} } as never); },
      stop: vi.fn(), request: connectRequest,
    }));
    const connectDir = harness().dir;
    const connectRunner = new OpenClawRunner({ stateDir: connectDir, clientFactory: connectFactory });
    const connectAbort = new AbortController();
    const connecting = connectRunner.run({ threadId: "connect-abort", text: "never", signal: connectAbort.signal });
    await vi.waitFor(() => expect(connected).toBeTypeOf("function"));
    connectAbort.abort();
    connected();
    await expect(connecting).resolves.toBe("");
    expect(connectRequest).not.toHaveBeenCalledWith("chat.send", expect.anything());

    const gateway = harness();
    const patchReady = Promise.withResolvers<void>();
    gateway.request.mockImplementation(async (method) => {
      if (method === "sessions.patch") await patchReady.promise;
      return {};
    });
    const patchRunner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    const patchAbort = new AbortController();
    const patching = patchRunner.run({ threadId: "patch-abort", text: "never", model: "openai/model", signal: patchAbort.signal });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("sessions.patch", expect.anything()));
    patchAbort.abort();
    patchReady.resolve();
    await expect(patching).resolves.toBe("");
    expect(gateway.request).not.toHaveBeenCalledWith("chat.send", expect.anything());
  });

  test("abort during recovery session patch prevents stored resend", async () => {
    const gateway = harness();
    const first = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    void first.run({ threadId: "recover-patch-abort", text: "never", model: "openai/model",
      userEventId: "recover-patch-user" });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    gateway.request.mockClear();
    const patchReady = Promise.withResolvers<void>();
    gateway.request.mockImplementation(async (method) => {
      if (method === "chat.history") return { messages: [] };
      if (method === "sessions.patch") await patchReady.promise;
      return {};
    });
    const replacement = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory,
      recoveryDelayMs: 1 });
    const controller = new AbortController();
    const resumed = replacement.resume({ threadId: "recover-patch-abort", signal: controller.signal });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("sessions.patch", expect.anything()));
    controller.abort();
    patchReady.resolve();
    await expect(resumed).resolves.toBe("");
    expect(gateway.request).not.toHaveBeenCalledWith("chat.send", expect.anything());
  });

  test("abort during recovery chat.send aborts returned run without resurrecting ledger", async () => {
    const gateway = harness();
    const first = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    void first.run({ threadId: "recover-send-abort", text: "never", userEventId: "recover-send-user" });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    gateway.request.mockClear();
    const sent = Promise.withResolvers<{ runId: string }>();
    gateway.request.mockImplementation(async (method) => {
      if (method === "chat.history") return { messages: [] };
      if (method === "chat.send") return sent.promise;
      return {};
    });
    const replacement = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory,
      recoveryDelayMs: 1 });
    const controller = new AbortController();
    const resumed = replacement.resume({ threadId: "recover-send-abort", signal: controller.signal });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    controller.abort();
    sent.resolve({ runId: "accepted-recovery-run" });
    await expect(resumed).resolves.toBe("");
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.abort", {
      sessionKey: "agent:main:yorozu:recover-send-abort", runId: "accepted-recovery-run",
    }));
    expect(replacement.pendingTurns()).toEqual([]);
  });

  test("retries transient history failure in-process without releasing recovery ownership", async () => {
    const gateway = harness();
    const first = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    void first.run({ threadId: "failure", text: "update", completionId: "final-failure" });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    let histories = 0;
    gateway.request.mockImplementation(async (method) => {
      if (method !== "chat.history") return {};
      if (++histories === 1) throw new Error("history unavailable");
      return { messages: [{ role: "assistant", content: "recovered", stopReason: "stop",
        __openclaw: { runId: "run-1", idempotencyKey: "provider-scoped-key" } }] };
    });
    const replacement = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory, recoveryDelayMs: 1 });
    await expect(replacement.resume({ threadId: "failure" })).resolves.toBe("recovered");
    expect(histories).toBe(2);
    expect(replacement.pendingTurns()).toHaveLength(1);
  });

  test("retries startup connection failure while recovery keeps queue ownership", async () => {
    const gateway = harness();
    void new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "connect-retry", text: "update",
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    let attempts = 0;
    const request = vi.fn(async (method: string) => method === "chat.history" ? { messages: [
      { role: "assistant", content: "recovered", stopReason: "stop", __openclaw: { runId: "run-1" } },
    ] } : {});
    const clientFactory = vi.fn((options: GatewayClientOptions) => ({
      start: () => {
        attempts += 1;
        if (attempts === 1) options.onConnectError?.(new Error("gateway starting"));
        else options.onHelloOk?.({ auth: {} } as never);
      },
      stop: vi.fn(),
      request,
    }));
    const replacement = new OpenClawRunner({
      stateDir: gateway.dir, clientFactory, recoveryDelayMs: 1,
    });
    await expect(replacement.resume({ threadId: "connect-retry" })).resolves.toBe("recovered");
    expect(attempts).toBe(2);
  });

  test("resume honors pre-abort and abort removes only active ledger head", async () => {
    const gateway = harness();
    const first = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    const head = { threadId: "abort-resume", text: "head", userEventId: "head-user" };
    first.admitUserTurn(head, () => {});
    first.admitUserTurn({ threadId: "abort-resume", text: "next", userEventId: "next-user" }, () => {});
    void first.run(head);
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));

    const stopped = new AbortController();
    stopped.abort();
    const neverFactory = vi.fn();
    await expect(new OpenClawRunner({ stateDir: gateway.dir, clientFactory: neverFactory }).resume({
      threadId: "abort-resume", signal: stopped.signal,
    })).resolves.toBe("");
    expect(neverFactory).not.toHaveBeenCalled();
    expect(first.pendingTurns()).toMatchObject([{ userEventId: "next-user", state: "queued" }]);

    gateway.request.mockImplementation(async () => ({}));
    first.admitUserTurn({ threadId: "abort-resume", text: "third", userEventId: "third-user" }, () => {});
    void first.run({ threadId: "abort-resume", text: "next", userEventId: "next-user" });
    await vi.waitFor(() => expect(gateway.request.mock.calls.filter(([method]) => method === "chat.send")).toHaveLength(2));
    const replacement = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory, recoveryDelayMs: 1 });
    const controller = new AbortController();
    const resumed = replacement.resume({ threadId: "abort-resume", signal: controller.signal });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.history", expect.anything()));
    controller.abort();
    await expect(resumed).resolves.toBe("");
    expect(replacement.pendingTurns()).toMatchObject([{ userEventId: "third-user", state: "queued" }]);
  });

  test("restores delegated completion wait and dedupes persisted activity", async () => {
    const gateway = harness();
    const first = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    void first.run({ threadId: "delegated-restart", text: "delegate" });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    gateway.event({ action: "upserted", task: { id: "task-row", runId: "child-run", createdAt: Date.now(), sessionKey: "agent:main:yorozu:delegated-restart", status: "running", deliveryStatus: "pending" } }, "task");
    expect(first.pendingTurns()[0]?.awaitsAnnouncement).toBe(true);
    const tool = { sessionKey: "agent:main:yorozu:delegated-restart", runId: "run-1", stream: "tool", seq: 2,
      data: { phase: "result", toolCallId: "exec-1", name: "bash", result: "done" } };
    gateway.request.mockImplementation(async (method) => method === "chat.history" ? {
      inFlightRun: { runId: "run-1", events: [tool], text: "" },
    } : {});
    const events: YorozuEvent[] = [];
    const replacement = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    const waiting = replacement.resume({
      threadId: "delegated-restart",
      seenEventIds: ["openclaw:run-1:call:exec-1", "openclaw:run-1:result:exec-1"],
      onEvent: (event) => events.push(event),
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.history", expect.anything()));
    expect(events).toEqual([]);
    gateway.event({ state: "final", sessionKey: "agent:main:yorozu:delegated-restart", runId: "run-1", seq: 3 });
    await expect(Promise.race([waiting, Promise.resolve("waiting")])).resolves.toBe("waiting");
    gateway.event({ state: "final", sessionKey: "agent:main:yorozu:delegated-restart", runId: "announce:requester-settle:child-run", seq: 1, message: { content: "delegated done" } });
    await expect(waiting).resolves.toBe("delegated done");
  });

  test("recovers exact delegated announcement completed while sidecar was down", async () => {
    const gateway = harness();
    const first = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    void first.run({ threadId: "delegated-down", text: "delegate" });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    gateway.event({ action: "upserted", task: { id: "task-row-7", runId: "child-run-7", createdAt: Date.now(),
      sessionKey: "agent:main:yorozu:delegated-down", status: "running", deliveryStatus: "pending" } }, "task");
    gateway.request.mockImplementation(async (method) => method === "chat.history" ? { messages: [
      { role: "assistant", content: "preliminary", __openclaw: { runId: "run-1", idempotencyKey: "provider-parent" } },
      { role: "assistant", content: "wrong child", stopReason: "stop", __openclaw: {
        runId: "announce:requester-settle:child-run-8", idempotencyKey: "provider-wrong" } },
      { role: "assistant", content: "delegated result", stopReason: "stop", __openclaw: {
        runId: "announce:requester-settle:child-run-7", idempotencyKey: "provider-child" } },
    ] } : {});
    const replacement = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory, recoveryDelayMs: 1 });
    await expect(replacement.resume({ threadId: "delegated-down" })).resolves.toBe("delegated result");
  });

  test("ambiguous accepted chat.send loss recovers by receipt without duplicate send", async () => {
    const gateway = harness();
    let runId = "";
    let histories = 0;
    gateway.request.mockImplementation(async (method, params) => {
      if (method === "chat.send") {
        runId = (params as { idempotencyKey: string }).idempotencyKey;
        throw new Error("response lost");
      }
      if (method === "chat.history") return ++histories === 1
        ? { inputReceipts: [{ runId, state: "accepted" }] }
        : { inputReceipts: [{ runId, state: "accepted" }], messages: [
          { role: "assistant", content: "done", stopReason: "stop", __openclaw: { runId: runId } },
        ] };
      return {};
    });
    const runner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory, recoveryDelayMs: 1 });
    const result = runner.run({ threadId: "ambiguous", text: "once" });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.history", expect.anything()));
    await expect(result).resolves.toBe("done");
    expect(gateway.request.mock.calls.filter(([method]) => method === "chat.send")).toHaveLength(1);
  });

  test("persists and idempotently resends full input envelope when no receipt exists", async () => {
    const gateway = harness();
    let sends = 0;
    gateway.request.mockImplementation(async (method) => {
      if (method === "chat.send") {
        sends += 1;
        if (sends === 1) throw new Error("response lost before acceptance");
        return { runId: "same-run" };
      }
      if (method === "chat.history") return sends === 1 ? { inputReceipts: [] } : {
        inFlightRun: { runId: "same-run", events: [], text: "" },
      };
      return {};
    });
    const attachment = { id: "a", name: "proof.txt", mime: "text/plain", data: "cHJvb2Y=" };
    const runner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory, recoveryDelayMs: 1 });
    void runner.run({ threadId: "envelope", text: "exact prompt", model: "openai/m", effort: "high", attachments: [attachment] });
    await vi.waitFor(() => expect(sends).toBe(2));
    expect(runner.pendingTurns()[0]).toMatchObject({
      input: { text: "exact prompt", model: "openai/m", effort: "high", attachments: [attachment] },
    });
    expect(gateway.request).toHaveBeenCalledWith("sessions.patch", { key: "agent:main:yorozu:envelope", model: "openai/m", thinkingLevel: "high" });
    const calls = gateway.request.mock.calls.filter(([method]) => method === "chat.send");
    expect(calls[1]?.[1]).toMatchObject({
      message: "exact prompt", thinking: "high", idempotencyKey: calls[0]?.[1].idempotencyKey,
      attachments: [{ fileName: "proof.txt", content: "cHJvb2Y=" }],
    });
  });

  test("first dispatch retries transient patch and uses only admitted envelope", async () => {
    const gateway = harness();
    let patches = 0;
    gateway.request.mockImplementation(async (method) => {
      if (method === "sessions.patch" && ++patches === 1) throw Object.assign(new Error("offline"), { retryable: true });
      if (method === "chat.send") return { runId: "stored-run" };
      return { inFlightRun: { runId: "stored-run", events: [], text: "" } };
    });
    const runner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory, recoveryDelayMs: 1 });
    runner.admitUserTurn({ threadId: "stored", text: "stored text", model: "openai/stored", effort: "high",
      attachments: [], userEventId: "stored-user" }, () => {});
    void runner.run({ threadId: "stored", text: "live text", model: "openai/live", effort: "low",
      userEventId: "stored-user" });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.objectContaining({ message: "stored text", thinking: "high" })));
    expect(gateway.request).toHaveBeenCalledWith("sessions.patch", {
      key: "agent:main:yorozu:stored", model: "openai/stored", thinkingLevel: "high",
    });
    expect(patches).toBe(2);
  });

  test("replays actual chat.history toolCall and top-level toolResult shapes beyond 80 rows", async () => {
    const gateway = harness();
    void new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "history-events", text: "delegate",
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    gateway.request.mockImplementation(async (method) => method === "chat.history" ? { messages: [
      ...Array.from({ length: 81 }, (_, index) => ({ role: "assistant", content: `old-${index}` })),
      { role: "user", content: "delegate", __openclaw: { runId: "run-1" } },
      { role: "assistant", content: [
        { type: "toolCall", id: "spawn-1", name: "sessions_spawn", arguments: { task: "work" } },
        { type: "toolCall", id: "card-1", name: "progress_card",
          arguments: { markdown: "Spawned.", plan: [{ step: "Spawn", status: "completed" }] } },
      ] },
      { role: "toolResult", toolCallId: "spawn-1", name: "sessions_spawn", content: { status: "accepted" } },
      { role: "assistant", content: "done", stopReason: "stop", __openclaw: { runId: "run-1" } },
    ] } : {});
    const events: YorozuEvent[] = [];
    const replacement = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory, recoveryDelayMs: 1 });
    await expect(replacement.resume({ threadId: "history-events", onEvent: (event) => events.push(event) })).resolves.toBe("done");
    expect(events.map((event) => event.kind)).toEqual(["tool_call", "tool_call", "progress_card", "tool_result"]);
    // History carries no plan stream, so the card's last state comes from the call itself.
    expect(events[2]!.data).toMatchObject({ note: "Spawned.", steps: [{ label: "Spawn", state: "done" }] });
  });

  test("authoritative Gateway rejection terminalizes durably before acknowledgment", async () => {
    const gateway = harness();
    gateway.request.mockImplementation(async (method) => {
      if (method === "chat.send") throw Object.assign(new Error("forbidden"), { code: "FORBIDDEN", retryable: false });
      return {};
    });
    const runner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    await expect(runner.run({ threadId: "rejected", text: "bad" })).resolves.toBe("OpenClaw turn failed: forbidden");
    expect(runner.pendingTurns()).toHaveLength(1);
    runner.acknowledge("rejected", runner.pendingTurns()[0]!.completionId);
    expect(runner.pendingTurns()).toEqual([]);
  });

  test("ignores uncorrelated and preliminary history rows, but accepts exact empty terminal", async () => {
    const gateway = harness();
    const first = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    void first.run({ threadId: "exact", text: "quiet" });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    let histories = 0;
    gateway.request.mockImplementation(async (method) => method === "chat.history" ? (++histories === 1 ? { messages: [
      { role: "assistant", content: "wrong latest", timestamp: Date.now() },
      { role: "assistant", content: "commentary", __openclaw: { runId: "other-run" } },
    ] } : { messages: [
      { role: "assistant", content: "NO_REPLY", stopReason: "stop", __openclaw: { runId: "run-1" } },
    ] }) : {});
    const replacement = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory, recoveryDelayMs: 1 });
    await expect(replacement.resume({ threadId: "exact" })).resolves.toBe("");
    expect(histories).toBe(2);
  });

  test("live and recovered terminal errors produce the same durable reply", async () => {
    const liveGateway = harness();
    const liveRunner = new OpenClawRunner({ stateDir: liveGateway.dir, clientFactory: liveGateway.clientFactory });
    const live = liveRunner.run({ threadId: "live-error", text: "fail" });
    await vi.waitFor(() => expect(liveGateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    liveGateway.event({ state: "error", sessionKey: "agent:main:yorozu:live-error", runId: "run-1", seq: 1, errorMessage: "boom" });
    await expect(live).resolves.toBe("OpenClaw turn failed: boom");

    const gateway = harness();
    void new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({ threadId: "recovered-error", text: "fail" });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    gateway.request.mockImplementation(async (method) => method === "chat.history" ? { messages: [
      { role: "assistant", content: "boom", stopReason: "error", __openclaw: { runId: "run-1" } },
    ] } : {});
    const replacement = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory, recoveryDelayMs: 1 });
    await expect(replacement.resume({ threadId: "recovered-error" })).resolves.toBe("OpenClaw turn failed: boom");
  });

  test("lists available Gateway models in Yorozu's picker shape", async () => {
    const gateway = harness();
    gateway.request.mockImplementation(async (method: string) => method === "models.list" ? {
      models: [
        { id: "claude-fable-5-1", provider: "anthropic", available: true, tags: ["fallback#1", "configured"] },
        { id: "claude-sonnet-5", provider: "anthropic", available: true, tags: ["configured"] },
        { id: "gpt-6-luna", provider: "openai", available: true },
        { id: "gpt-6-astra", provider: "openai", alias: "Astra", available: true, tags: ["default", "configured"] },
        { id: "offline", provider: "local", available: false },
        { provider: "broken" },
      ],
    } : {});
    const efforts = ["low", "medium", "high"];
    await expect(new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).listModels()).resolves.toEqual([
      { id: "openai/gpt-6-astra", label: "Astra", providerLabel: "openai", efforts },
      { id: "openai/gpt-6-luna", label: "gpt-6-luna", providerLabel: "openai", efforts },
      { id: "anthropic/claude-fable-5-1", label: "claude-fable-5-1", providerLabel: "anthropic", efforts },
      { id: "anthropic/claude-sonnet-5", label: "claude-sonnet-5", providerLabel: "anthropic", efforts },
    ]);
    expect(gateway.request).toHaveBeenCalledWith("models.list", {});
  });

  test("sends through Gateway and publishes streaming deltas", async () => {
    const gateway = harness();
    const updates: string[] = [];
    const result = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "one",
      text: "private text",
      attachments: [{ name: "note.txt", mime: "text/plain", data: Buffer.from("hello").toString("base64") }],
      onUpdate: (text) => updates.push(text),
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.objectContaining({
      sessionKey: "agent:main:yorozu:one",
      message: "private text",
      deliver: false,
      attachments: [{ type: "file", mimeType: "text/plain", fileName: "note.txt", content: "aGVsbG8=", sizeBytes: 5 }],
    })));
    gateway.event({ state: "delta", sessionKey: "agent:main:yorozu:one", runId: "run-1", seq: 1, deltaText: "new" });
    gateway.event({ state: "delta", sessionKey: "agent:main:yorozu:one", runId: "run-1", seq: 2, deltaText: " answer" });
    expect(updates).toEqual(["new", "new answer"]);
    gateway.event({ state: "final", sessionKey: "agent:main:yorozu:one", runId: "run-1", seq: 3 });
    await expect(result).resolves.toBe("new answer");
  });

  test("delivers Gateway-hosted images the agent sent as inline agent messages", async () => {
    const gateway = harness();
    const png = Buffer.from("png-bytes");
    gateway.request.mockImplementation(async (method: string) => {
      if (method === "chat.send") return { runId: "run-1" };
      if (method === "chat.history") return { messages: [
        { role: "assistant", runId: "other", stopReason: "stop", content: [{ type: "image", artifactId: "artifact_managed_image_x" }] },
        { role: "assistant", runId: "run-1", stopReason: "stop", content: [
          { type: "text", text: "Mac screen now" },
          { type: "image", artifactId: "artifact_managed_image_a1", mimeType: "image/png", alt: "screen.png", url: "/api/chat/media/outgoing/k/a1/full" },
        ] },
      ] };
      if (method === "artifacts.download") return { url: "/api/chat/media/outgoing/k/a1/full?mediaTicket=v1.t" };
      return {};
    });
    const fetchMock = vi.fn(async () => new Response(png, { headers: { "content-type": "image/png" } }));
    const events: YorozuEvent[] = [];
    const result = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory, fetch: fetchMock }).run({
      threadId: "shot", text: "screenshot please", onEvent: (event) => events.push(event),
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    gateway.event({ state: "final", sessionKey: "agent:main:yorozu:shot", runId: "run-1", seq: 1, message: { role: "assistant", content: [{ type: "text", text: "Mac screen now" }] } });
    await expect(result).resolves.toBe("Mac screen now");
    expect(gateway.request).toHaveBeenCalledWith("artifacts.download", { sessionKey: "agent:main:yorozu:shot", artifactId: "artifact_managed_image_a1" });
    expect(String(fetchMock.mock.calls[0]![0])).toBe("http://127.0.0.1:18789/api/chat/media/outgoing/k/a1/full?mediaTicket=v1.t");
    expect(events.filter((event) => event.kind === "message")).toEqual([expect.objectContaining({
      id: "openclaw:run-1:image:artifact_managed_image_a1", threadId: "shot", agentId: "main", kind: "message",
      data: { role: "agent", text: "", attachments: [{ name: "screen.png", mime: "image/png", data: png.toString("base64") }] },
    })]);
  });

  test("matches Gateway events after session key case normalization", async () => {
    const gateway = harness();
    const updates: string[] = [];
    const result = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "5A235B7C-1B10-4197-A533-FEA8CB2A9D4B",
      text: "hello",
      onUpdate: (text) => updates.push(text),
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.objectContaining({
      sessionKey: "agent:main:yorozu:5a235b7c-1b10-4197-a533-fea8cb2a9d4b",
    })));
    gateway.event({ state: "delta", sessionKey: "agent:main:yorozu:5a235b7c-1b10-4197-a533-fea8cb2a9d4b", runId: "run-1", seq: 1, deltaText: "done" });
    gateway.event({ state: "final", sessionKey: "agent:main:yorozu:5a235b7c-1b10-4197-a533-fea8cb2a9d4b", runId: "run-1", seq: 2 });
    expect(updates).toEqual(["done"]);
    await expect(result).resolves.toBe("done");
  });

  test("patches model and effort before sending", async () => {
    const gateway = harness();
    const result = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "two", text: "hello", model: "openai/gpt-6-astra", effort: "high",
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("sessions.patch", {
      key: "agent:main:yorozu:two", model: "openai/gpt-6-astra", thinkingLevel: "high",
    }));
    gateway.event({ state: "final", sessionKey: "agent:main:yorozu:two", runId: "run-1", seq: 1, message: { content: [{ type: "text", text: "done" }] } });
    await expect(result).resolves.toBe("done");
  });

  test("waits for a delegated requester-settle announcement after an empty parent final", async () => {
    const gateway = harness();
    const runner = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    const result = runner.run({ threadId: "delegated", text: "what is on my calendar?" });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    gateway.event({
      action: "upserted",
      task: {
        id: "child",
        runId: "child-run",
        createdAt: Date.now(),
        sessionKey: "agent:main:yorozu:delegated",
        status: "running",
        deliveryStatus: "pending",
      },
    }, "task");
    gateway.event({
      state: "final", sessionKey: "agent:main:yorozu:delegated", runId: "run-1", seq: 1,
    });
    await expect(Promise.race([result, Promise.resolve("still-pending")])).resolves.toBe("still-pending");
    gateway.event({
      state: "final",
      sessionKey: "agent:main:yorozu:delegated",
      runId: "announce:requester-settle:child-run",
      seq: 1,
      message: { content: [{ type: "text", text: "Tomorrow at 10am." }] },
    });
    await expect(result).resolves.toBe("Tomorrow at 10am.");
  });

  test("finishes an intentional empty turn when it did not delegate", async () => {
    const gateway = harness();
    const result = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "silent", text: "perform a side effect",
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    gateway.event({ state: "final", sessionKey: "agent:main:yorozu:silent", runId: "run-1", seq: 1 });
    await expect(result).resolves.toBe("");
  });

  test("finishes an empty turn after a fire-and-forget task", async () => {
    const gateway = harness();
    const result = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "quiet", text: "start this in the background without a completion message",
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.anything()));
    gateway.event({
      action: "upserted",
      task: {
        id: "child",
        createdAt: Date.now(),
        sessionKey: "agent:main:yorozu:quiet",
        status: "running",
        deliveryStatus: "not_applicable",
      },
    }, "task");
    gateway.event({ state: "final", sessionKey: "agent:main:yorozu:quiet", runId: "run-1", seq: 1 });
    await expect(result).resolves.toBe("");
  });

  test("persists bootstrap device credentials with owner-only permissions", async () => {
    const dir = mkdtempSync(join(tmpdir(), "yorozu-openclaw-bootstrap-"));
    const payload = Buffer.from(JSON.stringify({ url: "ws://127.0.0.1:18789", bootstrapToken: "bootstrap" })).toString("base64url");
    const spawnProcess = vi.fn(() => {
      const child = Object.assign(new EventEmitter(), { stdout: new PassThrough(), stderr: new PassThrough() });
      queueMicrotask(() => { child.stdout.end(`oc-pair://${payload}`); child.emit("close", 0); });
      return child;
    }) as never;
    let options!: GatewayClientOptions;
    const clientFactory = (value: GatewayClientOptions) => {
      options = value;
      return {
        start: () => {
          value.hostDeps?.storeDeviceAuthToken?.({ deviceId: value.deviceIdentity!.deviceId, role: "operator", token: "issued", scopes: ["operator.read", "operator.write"] });
          value.onHelloOk?.({ auth: {} } as never);
        },
        stop: vi.fn(),
        request: vi.fn(async () => ({ runId: "run-1" })),
      };
    };
    const result = new OpenClawRunner({ stateDir: dir, spawnProcess, clientFactory }).run({ threadId: "new", text: "hi" });
    await vi.waitFor(() => expect(options.bootstrapToken).toBe("bootstrap"));
    options.onEvent?.({ type: "event", event: "chat", payload: { state: "final", sessionKey: "agent:main:yorozu:new", runId: "run-1", seq: 1 } } as never);
    await result;
    const file = join(dir, "openclaw-gateway.json");
    expect(JSON.parse(readFileSync(file, "utf8")).token).toBe("issued");
    expect(statSync(file).mode & 0o777).toBe(0o600);
  });
});
