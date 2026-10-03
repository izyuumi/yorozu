/** Real Rust/Node/official-adapter boundary, with a local protocol peer instead of live Codex. */
import { expect, test, vi } from "vitest";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { execFileSync, spawnSync } from "node:child_process";
import { createConnection } from "node:net";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { serveSecretary } from "../dist/secretary-serve.js";
import { dirname, join } from "node:path";
import { secretaryRunner, SECRETARY_THREAD_ID } from "../dist/secretary-runner.js";
import { appendThreadEvent, createThread, listThreads, setNativeTurn, setThreadSession, threadHome } from "../dist/threads.js";
import type { NativeTurn } from "./native.js";

// The lifecycle regression must never launch the SDK's bundled Claude executable.
vi.mock("@anthropic-ai/claude-agent-sdk", () => ({ query: () => { throw new Error("Claude is absent from this fixture"); }, createSdkMcpServer: () => ({}) }));

const peer = `#!${process.execPath}
const fs = require('node:fs');
if (process.argv[2] === 'login') { console.log('Logged in using fixture'); process.exit(0); }
const lines = require('node:readline').createInterface({ input: process.stdin });
const send = value => process.stdout.write(JSON.stringify(value) + '\\n');
const log = value => fs.appendFileSync(process.env.CODEX_FIXTURE_LOG, JSON.stringify(value) + '\\n');
const session = 'fixture-native-session';
let mode = '';
lines.on('line', line => {
  const frame = JSON.parse(line);
  if (frame.method) log({ method: frame.method, params: frame.params, pid: process.pid });
  if (frame.method === 'initialize') send({ id: frame.id, result: {} });
  if (frame.method === 'skills/list') send({ id: frame.id, result: { data: [] } });
  if (frame.method === 'model/list') {
    const reply = () => send({ id: frame.id, result: { data: [{ model: 'fixture-model', displayName: 'Fixture', isDefault: true }] } });
    if (!process.env.CODEX_FIXTURE_MODELS_RELEASE) reply();
    else {
      const timer = setInterval(() => {
        if (fs.existsSync(process.env.CODEX_FIXTURE_MODELS_RELEASE)) { clearInterval(timer); reply(); }
      }, 20);
    }
  }
  if (['thread/start', 'thread/resume'].includes(frame.method)) send({ id: frame.id, result: { thread: { id: session } } });
  if (frame.method === 'turn/start') {
    const records = JSON.parse(fs.readFileSync(process.env.CODEX_FIXTURE_STATE + '/threads.json', 'utf8'));
    log({ persistedBeforeStart: records.find(t => t.id === 'yorozu-secretary-v1').nativeSessionId === session });
    mode = frame.params.input[0].text;
    send({ id: frame.id, result: { turn: { id: 'fixture-turn' } } });
    if (mode === 'FAIL') { process.exit(8); return; }
    if (mode === 'FAIL_TERMINAL' || mode === 'INTERRUPTED_TERMINAL') {
      send({ method: 'turn/completed', params: { threadId: session, turn: { id: 'fixture-turn', status: mode === 'FAIL_TERMINAL' ? 'failed' : 'interrupted', error: { message: 'Fixture provider failed' } } } });
      return;
    }
    if (mode === 'STOP') return;
    if (mode === 'STOP_UNCONFIRMED') {
      process.on('SIGTERM', () => {});
      setInterval(() => {}, 1000);
      return;
    }
    send({ id: 'approval', method: 'item/commandExecution/requestApproval', params: { threadId: session, turnId: 'fixture-turn', command: 'fixture command' } });
  }
  if (frame.id === 'approval' && frame.result) {
    log({ approval: frame.result });
    send({ id: 'question', method: 'item/tool/requestUserInput', params: { threadId: session, turnId: 'fixture-turn', questions: [{ id: 'choice', question: 'Which fixture?', options: [{ label: 'One' }, { label: 'Two' }] }] } });
  }
  if (frame.id === 'question' && frame.result) {
    log({ question: frame.result });
    send({ method: 'item/agentMessage/delta', params: { threadId: session, itemId: 'reply', delta: 'Hello from fixture' } });
    send({ method: 'item/completed', params: { threadId: session, item: { id: 'command', type: 'commandExecution', status: 'completed', aggregatedOutput: 'fixture result' } } });
    send({ method: 'item/completed', params: { threadId: session, item: { id: 'reply', type: 'agentMessage', text: 'Hello from fixture' } } });
    send({ method: 'turn/completed', params: { threadId: session, turn: { id: 'fixture-turn', status: 'completed' } } });
  }
  if (frame.method === 'turn/interrupt') {
    if (mode === 'STOP_UNCONFIRMED') return;
    send({ id: frame.id, result: {} });
    send({ method: 'turn/completed', params: { threadId: session, turn: { id: 'fixture-turn', status: 'interrupted' } } });
  }
});
`;

function fixture() {
  const temp = realpathSync(mkdtempSync(join(tmpdir(), "ys-wire-")));
  const state = join(temp, "state");
  const bin = join(temp, "bin");
  mkdirSync(bin);
  writeFileSync(join(bin, "codex"), peer);
  chmodSync(join(bin, "codex"), 0o700);
  vi.stubEnv("YOROZU_STATE_DIR", state);
  vi.stubEnv("YOROZU_PROJECTS_DIR", join(temp, "projects"));
  vi.stubEnv("PATH", `${bin}:${dirname(process.execPath)}`);
  vi.stubEnv("HOME", temp);
  vi.stubEnv("CODEX_FIXTURE_STATE", state);
  vi.stubEnv("CODEX_FIXTURE_LOG", join(temp, "protocol.jsonl"));
  const rows = (): any[] => readFileSync(join(temp, "protocol.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
  return { temp, state, rows };
}

test("secretary preserves legacy data, durable replay, session continuity and native controls", async () => {
  const { temp, state, rows } = fixture();
  try {
    createThread("Existing thread", state, "legacy-thread", { agent: "codex", cwd: temp });
    setThreadSession("legacy-thread", "keep-native-session", state);
    appendThreadEvent({ id: "legacy-event", threadId: "legacy-thread", agentId: "main", ts: 1, kind: "message", data: { role: "user", text: "keep history" } }, state);
    const legacyRecord = listThreads(state).find((thread) => thread.id === "legacy-thread");
    const legacyBytes = readFileSync(join(state, "threads", "legacy-thread.jsonl"));
    const ordinary = { run: vi.fn(async () => ({ text: "ordinary result" })) };
    let runner = secretaryRunner(state, ordinary);
    const home = threadHome(SECRETARY_THREAD_ID, state);
    const invoke = async (eventId: string, text: string, extra: Partial<NativeTurn> = {}) => {
      appendThreadEvent({ id: eventId, threadId: SECRETARY_THREAD_ID, agentId: "main", ts: Date.now(), kind: "message", data: { role: "user", text } }, state);
      setNativeTurn(SECRETARY_THREAD_ID, { id: `native:${eventId}:final`, userEventId: eventId, state: "running" }, state);
      return runner.run({ threadId: SECRETARY_THREAD_ID, cwd: home.cwd!, text, signal: new AbortController().signal,
        sessionId: threadHome(SECRETARY_THREAD_ID, state).sessionId,
        onSession: (id) => { setThreadSession(SECRETARY_THREAD_ID, id, state); }, ...extra });
    };
    const approve = vi.fn(async () => false);
    const ask = vi.fn(async () => "Two");
    const update = vi.fn();
    const activity = vi.fn();
    const onSteer = vi.fn();
    const imagePath = join(temp, "image.png");
    writeFileSync(imagePath, "fixture image path only");
    expect(await invoke("first", "RUN", { model: "selected-model", effort: "high", approve, ask, onUpdate: update, onActivity: activity, onSteer,
      attachments: [{ name: "image.png", mime: "image/png", path: imagePath }] })).toMatchObject({ text: "Hello from fixture", completed: true, cessation: "provider-terminal" });
    expect(approve).toHaveBeenCalledTimes(1);
    expect(ask).toHaveBeenCalledWith("Which fixture?", ["One", "Two"], expect.any(AbortSignal));
    expect(update).toHaveBeenCalledWith("Hello from fixture");
    expect(activity.mock.calls[0][1]).toMatchObject({ kind: "tool_result", data: { output: "fixture result" } });
    expect(await onSteer.mock.calls[0][0]("later", [])).toBe(false);
    expect(rows().find((row) => row.approval)?.approval.decision).toBe("decline");
    expect(rows().find((row) => row.question)?.question.answers.choice.answers).toEqual(["Two"]);
    expect(rows().find((row) => row.method === "turn/start")?.params).toMatchObject({ model: "selected-model", effort: "high", input: [{ type: "text", text: "RUN" }, { type: "localImage", path: imagePath }] });
    expect(rows().filter((row) => "persistedBeforeStart" in row)).toEqual([{ persistedBeforeStart: true }]);
    runner = secretaryRunner(state, ordinary);
    expect(await runner.run({ threadId: SECRETARY_THREAD_ID, cwd: home.cwd!, text: "recovery text must not reissue", signal: new AbortController().signal })).toMatchObject({ text: "Hello from fixture", completed: true });
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(1);
    expect(await invoke("second", "RUN", { approve, ask })).toMatchObject({ completed: true });
    expect(rows().filter((row) => row.method === "thread/resume")).toHaveLength(1);
    const failed = await invoke("uncertain", "FAIL");
    expect(failed.text).toMatch(/unconfirmed|without confirmed completion/);
    expect(failed.completed).not.toBe(true);
    expect(failed.unconfirmed).toBe(true);
    const starts = rows().filter((row) => row.method === "turn/start").length;
    runner = secretaryRunner(state, ordinary);
    expect((await runner.run({ threadId: SECRETARY_THREAD_ID, cwd: home.cwd!, text: "FAIL", signal: new AbortController().signal })).completed).not.toBe(true);
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(starts);
    const stopped = new AbortController();
    const running = invoke("stop", "STOP", { signal: stopped.signal });
    await vi.waitFor(() => expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(starts + 1));
    stopped.abort();
    expect(await running).toMatchObject({ cessation: "provider-terminal" });
    expect(await runner.run({ threadId: "legacy-thread", cwd: temp, text: "ordinary", signal: new AbortController().signal })).toEqual({ text: "ordinary result" });
    expect(ordinary.run).toHaveBeenCalledTimes(1);
    expect(listThreads(state).find((thread) => thread.id === "legacy-thread")).toEqual(legacyRecord);
    expect(readFileSync(join(state, "threads", "legacy-thread.jsonl"))).toEqual(legacyBytes);
  } finally { vi.unstubAllEnvs(); rmSync(temp, { recursive: true, force: true }); }
}, 30000);


test("production decoration retains default readiness and process journaling", async () => {
  const { temp, state, rows } = fixture();
  const release = join(temp, "release-models");
  vi.stubEnv("CODEX_FIXTURE_MODELS_RELEASE", release);
  let sidecar: ReturnType<typeof serveSecretary> | undefined;
  let socket: ReturnType<typeof createConnection> | undefined;
  try {
    // A fresh empty profile contains no work or processes to recover.
    const log: string[] = [];
    sidecar = serveSecretary({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: (line) => log.push(line) });
    await vi.waitFor(() => expect(existsSync(join(state, "local.sock")), log.join("\n")).toBe(true));
    socket = createConnection(join(state, "local.sock"));
    const events: any[] = [];
    createInterface({ input: socket }).on("line", (line) => events.push(JSON.parse(line))).on("error", () => {});
    await new Promise<void>((resolve, reject) => { socket!.once("connect", resolve); socket!.once("error", reject); });
    await vi.waitFor(() => expect(rows().some((row) => row.method === "model/list")).toBe(true));
    const pid = rows().find((row) => row.method === "model/list").pid;
    expect(JSON.parse(readFileSync(join(state, "native-agent-processes.json"), "utf8"))).toEqual(expect.arrayContaining([
      expect.objectContaining({ pid, startedAt: expect.any(String), commandLine: expect.stringContaining("codex") }),
    ]));
    await vi.waitFor(() => {
      const agents = events.findLast((event) => event.kind === "model_list")?.data.agents.map((agent: any) => agent.id);
      expect(agents).toContain("codex");
      expect(agents).not.toContain("claude-code");
    });
  } finally {
    writeFileSync(release, "release fixture");
    if (sidecar) {
      await vi.waitFor(() => expect(JSON.parse(readFileSync(join(state, "native-agent-processes.json"), "utf8"))).toEqual([]));
      socket?.destroy();
      await sidecar.close();
    }
    vi.unstubAllEnvs();
    rmSync(temp, { recursive: true, force: true });
  }
}, 10000);

test("settings subcommands retain the baseline CLI without starting the secretary", () => {
  const temp = realpathSync(mkdtempSync(join(tmpdir(), "ys-command-")));
  try {
    const result = spawnSync(process.execPath, [fileURLToPath(new URL("../dist/secretary-serve.js", import.meta.url)), "models", "missing-fixture-entry"], {
      env: { ...process.env, HOME: temp, YOROZU_STATE_DIR: join(temp, "state"), YOROZU_PROJECTS_DIR: join(temp, "projects") },
      encoding: "utf8", timeout: 5000,
    });
    expect(result.error).toBeUndefined();
    expect(result.status).toBe(0);
    expect(result.stdout).toBe("\n");
    expect(existsSync(join(temp, "state", "secretary-v1"))).toBe(false);
    expect(existsSync(join(temp, "state", "local.sock"))).toBe(false);
  } finally { rmSync(temp, { recursive: true, force: true }); }
});


test.each(["FAIL", "STOP_UNCONFIRMED", "FAIL_TERMINAL", "INTERRUPTED_TERMINAL"])("service preserves %s outcome, replay and queue semantics", async (mode) => {
  const { temp, state, rows } = fixture();
  let sidecar: ReturnType<typeof serveSecretary> | undefined;
  let socket: ReturnType<typeof createConnection> | undefined;
  let heldProvider: number | undefined;
  const stopFixture = (): void => {
    if (!heldProvider) return;
    let command = "";
    try { command = execFileSync("/bin/ps", ["-p", String(heldProvider), "-o", "command="], { encoding: "utf8" }); } catch {}
    if (command.includes(`${temp}/bin/codex`)) process.kill(heldProvider, "SIGKILL");
    heldProvider = undefined;
  };
  try {
    sidecar = serveSecretary({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} });
    await vi.waitFor(() => expect(existsSync(join(state, "local.sock"))).toBe(true));
    socket = createConnection(join(state, "local.sock"));
    const events: any[] = [];
    createInterface({ input: socket }).on("line", (line) => events.push(JSON.parse(line))).on("error", () => {});
    await new Promise<void>((resolve, reject) => { socket!.once("connect", resolve); socket!.once("error", reject); });
    const send = (id: string, kind: string, data: unknown) => {
      const event = { id, kind, data, threadId: SECRETARY_THREAD_ID, agentId: "main", ts: Date.now() };
      socket!.write(`${JSON.stringify(event)}\n`);
      return event;
    };
    const first = send("uncertain-user", "message", { role: "user", text: mode });
    await vi.waitFor(() => expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(1));
    if (mode === "STOP_UNCONFIRMED") {
      heldProvider = rows().find((row) => row.method === "turn/start").pid;
      send("stop-inflight", "interrupt", { targetEventId: first.id });
      await vi.waitFor(() => expect(events.some((event) => event.kind === "stop_status" && event.data.status === "unconfirmed")).toBe(true), { timeout: 6000 });
      // The adapter already reported no cessation evidence; clean up only our stubborn peer.
      stopFixture();
    }
    await vi.waitFor(() => expect(events.find((event) => event.id === `native:${first.id}:final` && event.data.done)?.data.failed).toBe(true), { timeout: 6000 });
    if (mode.endsWith("_TERMINAL")) {
      expect(events.find((event) => event.id === `native:${first.id}:final`)?.data.text).toContain(mode === "FAIL_TERMINAL" ? "Fixture provider failed" : "without completing");
      socket.write(`${JSON.stringify(first)}\n`);
      send("later-user", "message", { role: "user", text: mode });
      await vi.waitFor(() => expect(events.find((event) => event.id === "native:later-user:final" && event.data.done)?.data.failed).toBe(true));
      expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(2);
      expect(events.filter((event) => event.kind === "stop_status")).toHaveLength(0);
      expect(listThreads(state).find((thread) => thread.id === SECRETARY_THREAD_ID)?.nativeTurn).toBeUndefined();
      return;
    }
    send("stop-again", "interrupt", { targetEventId: first.id });
    await vi.waitFor(() => expect(events.findLast((event) => event.kind === "stop_status" && event.data.requestId === "stop-again")?.data.status).toBe("unconfirmed"));
    expect(events.filter((event) => event.kind === "stop_status" && event.data.targetEventId === first.id).some((event) => ["stopped", "completed"].includes(event.data.status))).toBe(false);
    socket.write(`${JSON.stringify(first)}\n`);
    send("later-user", "message", { role: "user", text: "RUN" });
    send("query-uncertain", "admission_query", { eventId: first.id });
    await vi.waitFor(() => expect(events.find((event) => event.kind === "admission_status" && event.data.requestId === "query-uncertain")?.data.status).toBe("indeterminate"));
    await vi.waitFor(() => expect(events.findLast((event) => event.kind === "thread_list")?.data.threads.find((thread: any) => thread.id === SECRETARY_THREAD_ID)).toMatchObject({ turnState: "stopped-unconfirmed", queuedEventIds: ["later-user"] }));
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(listThreads(state).find((thread) => thread.id === SECRETARY_THREAD_ID)?.nativeTurn).toBeUndefined();
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(1);
    expect(JSON.parse(readFileSync(join(state, "native-turn-queue.json"), "utf8"))).toContainEqual({ threadId: SECRETARY_THREAD_ID, eventId: "later-user" });
    expect(JSON.parse(readFileSync(join(state, "stopped-turns.jsonl"), "utf8").trim().split("\n").at(-1)!)).toMatchObject({ targetEventId: first.id, status: "unconfirmed" });
  } finally {
    stopFixture();
    socket?.destroy();
    await sidecar?.close();
    vi.unstubAllEnvs();
    rmSync(temp, { recursive: true, force: true });
  }
}, 15000);
