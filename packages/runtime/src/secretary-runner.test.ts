/** Real Rust/Node/official-adapter boundary, with a local protocol peer instead of live Codex. */
import { expect, test, vi } from "vitest";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createConnection } from "node:net";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { serve as serveRuntime } from "../dist/serve.js";
import { serveSecretary } from "../dist/secretary-serve.js";
import { dirname, join } from "node:path";
import { secretaryRunner, SECRETARY_THREAD_ID } from "../dist/secretary-runner.js";
import { appendThreadEvent, createThread, listThreads, readThreadEvents, setNativeTurn, setThreadSession, threadHome } from "../dist/threads.js";
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
let changed = 'A';
lines.on('line', line => {
  const frame = JSON.parse(line);
  if (frame.method) log({ method: frame.method, params: frame.params, pid: process.pid });
  if (frame.method === 'initialize') {
    if (process.env.CODEX_FIXTURE_PRESTART === 'initialize') send({ id: frame.id, error: { message: 'Fixture initialization failed' } });
    else if (process.env.CODEX_FIXTURE_PRESTART?.startsWith('stop-')) {
      setInterval(() => {}, 1000);
      process.on('SIGTERM', () => setTimeout(() => process.exit(0), Number(process.env.CODEX_FIXTURE_PRESTART.slice(5))));
      return;
    } else send({ id: frame.id, result: {} });
  }
  if (frame.method === 'config/read') send({ id: frame.id, result: { config: { mcp_servers: { fixture_connector: { enabled: true } } } } });
  if (frame.method === 'thread/inject_items') send({ id: frame.id, result: {} });
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
  if (['thread/start', 'thread/resume'].includes(frame.method)) send(process.env.CODEX_FIXTURE_PRESTART === 'session'
    ? { id: frame.id, error: { message: 'Fixture session rejected' } } : { id: frame.id, result: { thread: { id: session } } });
  if (frame.method === 'turn/start') {
    const records = JSON.parse(fs.readFileSync(process.env.CODEX_FIXTURE_STATE + '/threads.json', 'utf8'));
    log({ persistedBeforeStart: records.find(t => t.id === 'yorozu-secretary-v1')?.nativeSessionId === session });
    mode = frame.params.input[0].text;
    if (frame.params.outputSchema) {
      const input = mode.split('User message:\\n').at(-1).trim();
      if (input === 'CRASH_PLANNER') { send({ id: frame.id, result: { turn: { id: 'fixture-turn' } } }); setTimeout(() => process.exit(8), 30); return; }
      const records = fs.existsSync(process.env.CODEX_FIXTURE_STATE + '/secretary-tasks-v1')
        ? fs.readdirSync(process.env.CODEX_FIXTURE_STATE + '/secretary-tasks-v1').flatMap(name => { try { return [JSON.parse(fs.readFileSync(process.env.CODEX_FIXTURE_STATE + '/secretary-tasks-v1/' + name + '/task.json', 'utf8'))]; } catch { return []; } }) : [];
      const target = records.find(task => task.title === 'First task')?.id || '';
      const actions = input === 'TASKS' ? [
        { kind: 'start', target: '', title: 'First task', specialty: 'file', instruction: 'CONTROLLED_ONE' },
        { kind: 'start', target: '', title: 'Second task', specialty: 'file', instruction: 'CONTROLLED_TWO' },
      ] : input === 'CHANGE_FIRST' ? [{ kind: 'steer', target, title: '', specialty: '', instruction: 'write B instead' }]
        : input === 'STOP_FIRST' ? [{ kind: 'stop', target, title: '', specialty: '', instruction: '' }] : [];
      send({ id: frame.id, result: { turn: { id: 'fixture-turn' } } });
      send({ method: 'item/completed', params: { threadId: session, item: { id: 'reply', type: 'agentMessage', text: JSON.stringify({ reply: input === 'HELLO' ? 'Hello, how can I help?' : '', actions }) } } });
      send({ method: 'turn/completed', params: { threadId: session, turn: { id: 'fixture-turn', status: 'completed' } } });
      return;
    }
    if (mode.includes('Task: CONTROLLED_')) {
      const first = mode.includes('Task: CONTROLLED_ONE');
      const suffix = first ? 'one' : 'two';
      if (first && process.env.CODEX_FIXTURE_TASK_APPROVAL) send({ id: 'task-approval', method: 'item/commandExecution/requestApproval', params: { threadId: session, turnId: 'fixture-turn', command: 'controlled approval' } });
      send({ id: frame.id, result: { turn: { id: 'fixture-turn' } } });
      const timer = setInterval(() => {
        if (!fs.existsSync(process.env.CODEX_FIXTURE_RELEASE + '-' + suffix)) return;
        clearInterval(timer);
        fs.writeFileSync(process.env.CODEX_FIXTURE_RESULT + '-' + suffix, changed);
        send({ method: 'item/completed', params: { threadId: session, item: { id: 'reply', type: 'agentMessage', text: suffix + ' wrote ' + changed } } });
        send({ method: 'turn/completed', params: { threadId: session, turn: { id: 'fixture-turn', status: 'completed' } } });
      }, 20);
      return;
    }
    send({ id: frame.id, result: { turn: { id: 'fixture-turn' } } });
    if (mode === 'STEER' || mode === 'STEER_LOST') {
      setTimeout(() => send({ method: 'item/agentMessage/delta', params: { threadId: session, itemId: 'reply', delta: 'Waiting for controlled change' } }), 30);
      const timer = setInterval(() => {
        if (!fs.existsSync(process.env.CODEX_FIXTURE_RELEASE)) return;
        clearInterval(timer);
        fs.writeFileSync(process.env.CODEX_FIXTURE_RESULT, changed);
        send({ method: 'item/completed', params: { threadId: session, item: { id: 'reply', type: 'agentMessage', text: 'Wrote ' + changed } } });
        send({ method: 'turn/completed', params: { threadId: session, turn: { id: 'fixture-turn', status: 'completed' } } });
      }, 20);
      return;
    }
    if (mode === 'FAIL') { process.exit(8); return; }
    if (mode === 'DONE') {
      send({ method: 'item/completed', params: { threadId: session, item: { id: 'reply', type: 'agentMessage', text: 'Fixture completed' } } });
      send({ method: 'turn/completed', params: { threadId: session, turn: { id: 'fixture-turn', status: 'completed' } } });
      return;
    }
    if (mode === 'BURST') {
      for (let i = 0; i < 400; i += 1) send({ method: 'item/agentMessage/delta', params: { threadId: session, itemId: 'reply', delta: 'x' } });
      send({ method: 'item/completed', params: { threadId: session, item: { id: 'reply', type: 'agentMessage', text: 'x'.repeat(400) } } });
      send({ method: 'turn/completed', params: { threadId: session, turn: { id: 'fixture-turn', status: 'completed' } } });
      return;
    }
    if (mode === 'FAIL_TERMINAL' || mode === 'INTERRUPTED_TERMINAL') {
      send({ method: 'turn/completed', params: { threadId: session, turn: { id: 'fixture-turn', status: mode === 'FAIL_TERMINAL' ? 'failed' : 'interrupted', error: { message: 'Fixture provider failed' } } } });
      return;
    }
    if (mode === 'STOP') {
      send({ method: 'item/agentMessage/delta', params: { threadId: session, itemId: 'reply', delta: 'Partial fixture reply' } });
      return;
    }
    if (mode === 'STOP_UNCONFIRMED') {
      process.on('SIGTERM', () => {});
      setInterval(() => {}, 1000);
      return;
    }
    send({ id: 'approval', method: 'item/commandExecution/requestApproval', params: { threadId: session, turnId: 'fixture-turn', command: 'fixture command' } });
  }
  if (frame.id === 'task-approval' && frame.result) log({ taskApproval: frame.result });
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
  if (frame.method === 'turn/steer') {
    changed = frame.params.input[0].text === 'write B instead' ? 'B' : 'unexpected';
    if (mode === 'STEER_LOST') { fs.writeFileSync(process.env.CODEX_FIXTURE_RESULT, changed); process.exit(8); return; }
    const receipt = () => send({ id: frame.id, result: { turnId: 'fixture-turn' } });
    if (!process.env.CODEX_FIXTURE_STEER_RECEIPT) receipt();
    else {
      const timer = setInterval(() => {
        if (fs.existsSync(process.env.CODEX_FIXTURE_STEER_RECEIPT)) { clearInterval(timer); receipt(); }
      }, 20);
    }
  }
  if (frame.method === 'turn/interrupt') {
    if (mode === 'STOP_UNCONFIRMED') return;
    send({ id: frame.id, result: {} });
    send({ method: 'turn/completed', params: { threadId: session, turn: { id: 'fixture-turn', status: 'interrupted' } } });
  }
});
`;

function serveLedger(options: Parameters<typeof serveSecretary>[0]) {
  let unavailable: string | undefined;
  return serveRuntime({ ...options, secretaryUnavailable: () => unavailable,
    decorateNativeRunners: (runners) => ({ ...runners, codex: secretaryRunner(options!.stateDir!, runners.codex!, (reason) => {
      unavailable = reason; options?.log?.(`STATE secretary-unavailable ${reason}`);
    }) }),
  });
}

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
    const liveStopped = await running;
    expect(liveStopped).toMatchObject({ cessation: "provider-terminal" });
    expect(liveStopped.failed).not.toBe(true);
    runner = secretaryRunner(state, ordinary);
    expect(await runner.run({ threadId: SECRETARY_THREAD_ID, cwd: home.cwd!, text: "Never replay stopped work", signal: new AbortController().signal }))
      .toMatchObject({ cessation: "provider-terminal", failed: true, text: expect.stringMatching(/Partial fixture reply[\s\S]*Stopped before completion/) });
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(starts + 1);
    expect(await runner.run({ threadId: "legacy-thread", cwd: temp, text: "ordinary", signal: new AbortController().signal })).toEqual({ text: "ordinary result" });
    expect(ordinary.run).toHaveBeenCalledTimes(1);
    expect(listThreads(state).find((thread) => thread.id === "legacy-thread")).toEqual(legacyRecord);
    expect(readFileSync(join(state, "threads", "legacy-thread.jsonl"))).toEqual(legacyBytes);
  } finally { vi.unstubAllEnvs(); rmSync(temp, { recursive: true, force: true }); }
}, 30000);

test("streamed bursts retain the exact final reply with fewer durable updates", async () => {
  const { temp, state } = fixture();
  try {
    const runner = secretaryRunner(state, { run: async () => ({ text: "unused" }) });
    appendThreadEvent({ id: "burst", threadId: SECRETARY_THREAD_ID, agentId: "main", ts: Date.now(), kind: "message", data: { role: "user", text: "BURST" } }, state);
    setNativeTurn(SECRETARY_THREAD_ID, { id: "native:burst:final", userEventId: "burst", state: "running" }, state);
    const result = await runner.run({ threadId: SECRETARY_THREAD_ID, cwd: threadHome(SECRETARY_THREAD_ID, state).cwd!, text: "BURST", signal: new AbortController().signal,
      onSession: (id) => setThreadSession(SECRETARY_THREAD_ID, id, state) });
    expect(result).toMatchObject({ text: "x".repeat(400), completed: true });
    const runs = join(state, "secretary-v1", "runs");
    const threads = join(runs, readdirSync(runs)[0], "state", "threads");
    const events = readFileSync(join(threads, readdirSync(threads)[0]), "utf8").trim().split("\n").map((line) => JSON.parse(line).data);
    expect(events.filter((event) => event.kind === "update").length).toBeGreaterThan(0);
    expect(events.filter((event) => event.kind === "update").length).toBeLessThan(400);
    expect(events.find((event) => event.kind === "completed")?.text).toBe("x".repeat(400));
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

test.each(["STEER", "STEER_LOST"])("%s reaches the same provider turn and never becomes another execution", async (mode) => {
  const { temp, state, rows } = fixture();
  const release = join(temp, "release-task");
  const resultFile = join(temp, "result.txt");
  vi.stubEnv("CODEX_FIXTURE_RELEASE", release);
  vi.stubEnv("CODEX_FIXTURE_RESULT", resultFile);
  const receiptRelease = join(temp, "release-receipt");
  vi.stubEnv("CODEX_FIXTURE_STEER_RECEIPT", receiptRelease);
  let sidecar: ReturnType<typeof serveSecretary> | undefined;
  let socket: ReturnType<typeof createConnection> | undefined;
  const events: any[] = [];
  const connect = async () => {
    await vi.waitFor(() => expect(existsSync(join(state, "local.sock"))).toBe(true));
    socket = createConnection(join(state, "local.sock"));
    createInterface({ input: socket }).on("line", (line) => events.push(JSON.parse(line))).on("error", () => {});
    await new Promise<void>((resolve, reject) => { socket!.once("connect", resolve); socket!.once("error", reject); });
  };
  const message = (id: string, text: string, delivery?: "steer") => ({ id, threadId: SECRETARY_THREAD_ID,
    ts: Date.now(), agentId: "main", kind: "message", data: { role: "user", text, ...(delivery ? { delivery } : {}) } });
  const send = (event: unknown) => socket!.write(`${JSON.stringify(event)}\n`);
  try {
    sidecar = serveLedger({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} });
    await connect();
    send(message("steer-original", mode));
    await vi.waitFor(() => expect(events.some((event) => event.kind === "message" && event.data.text === "Waiting for controlled change")).toBe(true));
    const change = message("steer-change", "write B instead", "steer");
    send(change);
    await vi.waitFor(() => expect(rows().filter((row) => row.method === "turn/steer")).toHaveLength(1));
    socket!.write(`${JSON.stringify({ id: "withdraw-change", kind: "interrupt", data: { targetEventId: change.id },
      threadId: SECRETARY_THREAD_ID, agentId: "main", ts: Date.now() })}\n`);
    if (mode === "STEER") {
      socket!.write(`${JSON.stringify({ id: "query-pending", kind: "admission_query", data: { eventId: change.id },
        threadId: SECRETARY_THREAD_ID, agentId: "main", ts: Date.now() })}\n`);
      await vi.waitFor(() => expect(events.some((event) => event.kind === "admission_status" && event.data.requestId === "query-pending")).toBe(true));
      expect(events.some((event) => event.kind === "stop_status" && event.data.requestId === "withdraw-change")).toBe(false);
      writeFileSync(receiptRelease, "acknowledge change");
      await vi.waitFor(() => expect(events.some((event) => event.kind === "stop_status" && event.data.requestId === "withdraw-change")).toBe(true));
    }
    socket!.destroy();
    await connect();
    send(change); // same client submission after losing its connection
    await vi.waitFor(() => expect(readThreadEvents(SECRETARY_THREAD_ID, state).find((event) => event.id === "native:steer-change:final")?.data.text)
      .toContain(mode === "STEER" ? "received your change" : "unconfirmed"));
    expect(rows().find((row) => row.method === "turn/steer").params.expectedTurnId).toBe("fixture-turn");
    expect(events.some((event) => event.kind === "stop_status" && event.data.targetEventId === change.id && event.data.status === "withdrawn")).toBe(false);
    if (mode === "STEER") writeFileSync(release, "finish original task");
    await vi.waitFor(() => expect(readFileSync(resultFile, "utf8")).toBe("B"));
    await vi.waitFor(() => expect(readThreadEvents(SECRETARY_THREAD_ID, state).some((event) => event.id === "native:steer-original:final" && event.data.done)).toBe(true));
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(1);
    expect(JSON.parse(readFileSync(join(state, "native-turn-queue.json"), "utf8"))).not.toContainEqual({ threadId: SECRETARY_THREAD_ID, eventId: change.id });
    socket!.destroy();
    await sidecar.close();
    sidecar = serveLedger({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} });
    await connect();
    send(change);
    if (mode === "STEER") {
      send(message("after-steer", "DONE"));
      await vi.waitFor(() => expect(readThreadEvents(SECRETARY_THREAD_ID, state).some((event) => event.id === "native:after-steer:final" && event.data.done)).toBe(true));
      expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(2);
    } else {
      socket!.write(`${JSON.stringify({ id: "query-steer", kind: "admission_query", data: { eventId: change.id },
        threadId: SECRETARY_THREAD_ID, agentId: "main", ts: Date.now() })}\n`);
      await vi.waitFor(() => expect(events.find((event) => event.kind === "admission_status" && event.data.requestId === "query-steer")?.data.status).toBe("indeterminate"));
      expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(1);
    }
    expect(rows().filter((row) => row.method === "turn/steer")).toHaveLength(1);
  } finally {
    socket?.destroy();
    await sidecar?.close();
    vi.unstubAllEnvs();
    rmSync(temp, { recursive: true, force: true });
  }
}, 15000);

test("restart declines an accepted steer that crashed before the delivery journal", async () => {
  const { temp, state, rows } = fixture();
  let sidecar: ReturnType<typeof serveSecretary> | undefined;
  let socket: ReturnType<typeof createConnection> | undefined;
  try {
    secretaryRunner(state, { run: async () => ({ text: "unused" }) });
    appendThreadEvent({ id: "unsent-change", threadId: SECRETARY_THREAD_ID, agentId: "main", ts: Date.now(), kind: "message",
      data: { role: "user", text: "write B instead", delivery: "queue", secretarySteerTarget: "prior-task" } } as any, state);
    writeFileSync(join(state, "native-turn-queue.json"), JSON.stringify([{ threadId: SECRETARY_THREAD_ID, eventId: "unsent-change" }]));
    sidecar = serveLedger({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} });
    await vi.waitFor(() => expect(readThreadEvents(SECRETARY_THREAD_ID, state).find((event) => event.id === "native:unsent-change:final")?.data.text).toContain("not delivered"));
    expect(JSON.parse(readFileSync(join(state, "native-turn-queue.json"), "utf8"))).toEqual([]);
    socket = createConnection(join(state, "local.sock"));
    socket.on("error", () => {});
    await new Promise<void>((resolve, reject) => { socket!.once("connect", resolve); socket!.once("error", reject); });
    socket.write(`${JSON.stringify({ id: "after-unsent", threadId: SECRETARY_THREAD_ID, agentId: "main", ts: Date.now(),
      kind: "message", data: { role: "user", text: "DONE" } })}\n`);
    await vi.waitFor(() => expect(readThreadEvents(SECRETARY_THREAD_ID, state).some((event) => event.id === "native:after-unsent:final" && event.data.done)).toBe(true));
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(1);
    expect(rows().find((row) => row.method === "turn/start").params.input[0].text).toBe("DONE");
  } finally {
    socket?.destroy(); await sidecar?.close(); vi.unstubAllEnvs(); rmSync(temp, { recursive: true, force: true });
  }
}, 10000);

test("a closed worker input records an uncertain steer and keeps the Rust owner alive", async () => {
  const temp = realpathSync(mkdtempSync(join(tmpdir(), "ys-steer-pipe-")));
  const ready = join(temp, "ready");
  const exit = join(temp, "exit");
  const script = join(temp, "worker.sh");
  // Close the actual inherited pipe fd; Node's process.stdin.destroy() can retain fd 0.
  writeFileSync(script, 'read request\nexec 0<&-\n: > "$YOROZU_TEST_PIPE_READY"\nwhile [ ! -f "$YOROZU_TEST_PIPE_EXIT" ]; do /bin/sleep 0.02; done\n');
  const host = spawn(process.env.YOROZU_SECRETARY_HOST!, ["--secretary", join(temp, "secretary-v1"), "pipe-run", join(temp, "Yorozu Secretary"), "/bin/sh", script], {
    stdio: ["pipe", "pipe", "ignore"], env: { ...process.env, YOROZU_TEST_PIPE_READY: ready, YOROZU_TEST_PIPE_EXIT: exit },
  });
  const frames: any[] = [];
  const closed = new Promise<void>((resolve) => host.once("close", () => resolve()));
  createInterface({ input: host.stdout }).on("line", (line) => frames.push(JSON.parse(line)));
  const send = (id: string, op: string, data = {}) => host.stdin.write(`${JSON.stringify({ version: 1, id, op, runId: "pipe-run", ...data })}\n`);
  try {
    send("1", "submit", { text: "one task", turn: {} });
    await vi.waitFor(() => expect(existsSync(ready)).toBe(true));
    send("2", "steer", { deliveryId: "change", text: "change task", attachments: [] });
    await vi.waitFor(() => expect(frames.find((frame) => frame.event?.kind === "steer_result")?.event.data).toEqual({ deliveryId: "change", accepted: null }));
    send("3", "snapshot");
    await vi.waitFor(() => expect(frames.find((frame) => frame.id === "3")?.result.activeRunId).toBe("pipe-run"));
    expect(host.exitCode).toBe(null);
  } finally {
    writeFileSync(exit, "finish fixture"); host.stdin.end(); await closed;
    rmSync(temp, { recursive: true, force: true });
  }
}, 10000);


test.each(["FAIL", "STOP_UNCONFIRMED", "FAIL_TERMINAL", "INTERRUPTED_TERMINAL", "SYMLINK_TERMINAL"])("service preserves %s outcome, replay and queue semantics", async (mode) => {
  const { temp, state, rows } = fixture();
  if (mode === "SYMLINK_TERMINAL") {
    mkdirSync(join(temp, "real-projects"));
    symlinkSync(join(temp, "real-projects"), join(temp, "projects"));
  }
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
    sidecar = serveLedger({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} });
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
    const prompt = mode === "SYMLINK_TERMINAL" ? "FAIL_TERMINAL" : mode;
    const first = send("uncertain-user", "message", { role: "user", text: prompt });
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
      expect(events.find((event) => event.id === `native:${first.id}:final`)?.data.text).toContain(prompt === "FAIL_TERMINAL" ? "Fixture provider failed" : "without completing");
      socket.write(`${JSON.stringify(first)}\n`);
      send("later-user", "message", { role: "user", text: prompt });
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
    if (mode === "FAIL") {
      // A new coordinator may release only proven tool-free plans, never legacy execution.
      socket.destroy(); await sidecar.close();
      const previousModelRequests = rows().filter((row) => row.method === "model/list").length;
      sidecar = serveSecretary({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} });
      await vi.waitFor(() => expect(existsSync(join(state, "local.sock"))).toBe(true));
      socket = createConnection(join(state, "local.sock"));
      createInterface({ input: socket }).on("line", (line) => events.push(JSON.parse(line))).on("error", () => {});
      await new Promise<void>((resolve, reject) => { socket!.once("connect", resolve); socket!.once("error", reject); });
      send("legacy-hold-upgrade", "message", { role: "user", text: "HELLO" });
      await vi.waitFor(() => expect(events.some((event) => event.kind === "receipt" && event.data.eventId === "legacy-hold-upgrade")).toBe(true));
      expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(1);
      await vi.waitFor(() => expect(rows().filter((row) => row.method === "model/list").length).toBeGreaterThan(previousModelRequests));
      await vi.waitFor(() => expect(JSON.parse(readFileSync(join(state, "native-agent-processes.json"), "utf8"))).toEqual([]));
    }
  } finally {
    stopFixture();
    socket?.destroy();
    await sidecar?.close();
    vi.unstubAllEnvs();
    rmSync(temp, { recursive: true, force: true });
  }
}, 15000);

test.each(["unmarked workspace", "missing host", "bad host", "conflicting thread"])("%s disables only the secretary", async (failure) => {
  const { temp, state, rows } = fixture();
  const workspace = join(temp, "projects", "Yorozu Secretary");
  const ordinaryWorkspace = join(temp, "projects", "Ordinary");
  mkdirSync(ordinaryWorkspace, { recursive: true });
  createThread("Existing", state, "ordinary-thread", { agent: "codex", cwd: ordinaryWorkspace });
  appendThreadEvent({ id: "history", threadId: "ordinary-thread", agentId: "main", ts: 1, kind: "message", data: { role: "user", text: "Keep existing history" } }, state);
  const history = readFileSync(join(state, "threads", "ordinary-thread.jsonl"), "utf8");
  if (failure === "unmarked workspace") {
    mkdirSync(workspace);
    writeFileSync(join(workspace, "user-file"), "Leave me unchanged");
  } else if (failure === "conflicting thread") {
    createThread("Existing non-secretary", state, SECRETARY_THREAD_ID, { agent: "yorozu" });
  } else {
    const host = join(temp, "unusable-host");
    if (failure === "bad host") {
      writeFileSync(host, `#!${process.execPath}\nprocess.exit(1);\n`);
      chmodSync(host, 0o700);
    }
    vi.stubEnv("YOROZU_SECRETARY_HOST", host);
  }
  const log: string[] = [];
  let sidecar: ReturnType<typeof serveSecretary> | undefined;
  let socket: ReturnType<typeof createConnection> | undefined;
  try {
    sidecar = serveLedger({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: (line) => log.push(line) });
    expect(log.some((line) => line.startsWith("STATE secretary-unavailable "))).toBe(true);
    await vi.waitFor(() => expect(existsSync(join(state, "local.sock"))).toBe(true));
    socket = createConnection(join(state, "local.sock"));
    const events: any[] = [];
    createInterface({ input: socket }).on("line", (line) => events.push(JSON.parse(line))).on("error", () => {});
    await new Promise<void>((resolve, reject) => { socket!.once("connect", resolve); socket!.once("error", reject); });
    for (const threadId of [SECRETARY_THREAD_ID, "ordinary-thread"]) socket.write(`${JSON.stringify({ id: `request-${threadId}`, threadId, agentId: "main", ts: Date.now(), kind: "message", data: { role: "user", text: "DONE" } })}\n`);
    await vi.waitFor(() => expect(events.find((event) => event.threadId === SECRETARY_THREAD_ID && event.kind === "message" && event.data.done)?.data)
      .toMatchObject({ failed: true, text: expect.stringContaining("Secretary unavailable:") }));
    await vi.waitFor(() => expect(events.find((event) => event.threadId === "ordinary-thread" && event.kind === "message" && event.data.done)?.data.text).toBe("Fixture completed"));
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(1);
    expect(rows().find((row) => row.method === "thread/start")?.params.cwd).toBe(ordinaryWorkspace);
    expect(readFileSync(join(state, "threads", "ordinary-thread.jsonl"), "utf8").startsWith(history)).toBe(true);
    if (failure === "unmarked workspace") expect(readFileSync(join(workspace, "user-file"), "utf8")).toBe("Leave me unchanged");
  } finally {
    socket?.destroy();
    await sidecar?.close();
    vi.unstubAllEnvs();
    rmSync(temp, { recursive: true, force: true });
  }
}, 10000);

test.each(["initialize", "session", "missing-codex"])("%s failure before submission leaves later secretary work usable", async (fault) => {
  const { temp, state, rows } = fixture();
  let sidecar: ReturnType<typeof serveSecretary> | undefined;
  let socket: ReturnType<typeof createConnection> | undefined;
  const fixturePath = process.env.PATH!;
  try {
    sidecar = serveLedger({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} });
    await vi.waitFor(() => expect(existsSync(join(state, "local.sock"))).toBe(true));
    socket = createConnection(join(state, "local.sock"));
    const events: any[] = [];
    createInterface({ input: socket }).on("line", (line) => events.push(JSON.parse(line))).on("error", () => {});
    await new Promise<void>((resolve, reject) => { socket!.once("connect", resolve); socket!.once("error", reject); });
    await vi.waitFor(() => expect(events.some((event) => event.kind === "model_list" && event.data.agents.some((agent: any) => agent.id === "codex"))).toBe(true));
    if (fault === "missing-codex") { mkdirSync(join(temp, "empty-bin")); vi.stubEnv("PATH", join(temp, "empty-bin")); }
    else vi.stubEnv("CODEX_FIXTURE_PRESTART", fault);
    const send = (id: string) => socket!.write(`${JSON.stringify({ id, threadId: SECRETARY_THREAD_ID, agentId: "main", ts: Date.now(), kind: "message", data: { role: "user", text: "DONE" } })}\n`);
    send("before-start");
    await vi.waitFor(() => expect(events.find((event) => event.id === "native:before-start:final")?.data)
      .toMatchObject({ failed: true, text: expect.stringContaining("no Codex turn was submitted") }), { timeout: 5000 });
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(0);
    if (fault === "missing-codex") vi.stubEnv("PATH", fixturePath);
    else vi.stubEnv("CODEX_FIXTURE_PRESTART", "");
    send("before-start"); // An accepted failure remains final; it is never replayed.
    send("next-start");
    await vi.waitFor(() => expect(events.find((event) => event.id === "native:next-start:final")?.data.text).toBe("Fixture completed"));
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(1);
    expect(events.some((event) => event.kind === "stop_status" && event.data.status === "unconfirmed")).toBe(false);
  } finally {
    socket?.destroy();
    await sidecar?.close();
    vi.unstubAllEnvs();
    rmSync(temp, { recursive: true, force: true });
  }
}, 10000);

test.each(["stop-300", "stop-3000", "session-ack"])("%s retains honest cessation before forwarding turn/start", async (fault) => {
  const { temp, state, rows } = fixture();
  try {
    const runner = secretaryRunner(state, { run: async () => ({ text: "unused" }) });
    const abort = new AbortController();
    if (fault.startsWith("stop-")) vi.stubEnv("CODEX_FIXTURE_PRESTART", fault);
    appendThreadEvent({ id: "early-stop", threadId: SECRETARY_THREAD_ID, agentId: "main", ts: Date.now(), kind: "message", data: { role: "user", text: "DONE" } }, state);
    setNativeTurn(SECRETARY_THREAD_ID, { id: "native:early-stop:final", userEventId: "early-stop", state: "running" }, state);
    const running = runner.run({ threadId: SECRETARY_THREAD_ID, cwd: threadHome(SECRETARY_THREAD_ID, state).cwd!, text: "DONE", signal: abort.signal,
      onSession: () => { throw new Error("Fixture session persistence failed"); } });
    if (fault.startsWith("stop-")) {
      await vi.waitFor(() => expect(rows().some((row) => row.method === "initialize")).toBe(true));
      abort.abort();
    }
    const result = await running;
    if (fault === "stop-3000") expect(result).toMatchObject({ unconfirmed: true });
    else {
      expect(result).toMatchObject({ cessation: "process-exited", text: expect.stringContaining("no Codex turn was submitted") });
      expect(result.failed === true).toBe(fault === "session-ack");
    }
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(0);
  } finally { vi.unstubAllEnvs(); rmSync(temp, { recursive: true, force: true }); }
}, 15000);

test.each(["missing-host", "raced-run", "locked-host", "before-submit-stop"])("%s requires host closure and race-safe admission evidence", async (fault) => {
  const { temp, state } = fixture();
  const host = process.env.YOROZU_SECRETARY_HOST!;
  let holder: ReturnType<typeof spawn> | undefined;
  try {
    const runner = secretaryRunner(state, { run: async () => ({ text: "unused" }) });
    const workspace = threadHome(SECRETARY_THREAD_ID, state).cwd!;
    const root = join(state, "secretary-v1");
    if (fault === "missing-host") vi.stubEnv("YOROZU_SECRETARY_HOST", join(temp, "missing-host"));
    if (fault === "raced-run") {
      const racer = join(temp, "racing-host");
      writeFileSync(racer, `#!${process.execPath}\nrequire('node:fs').mkdirSync(require('node:path').join(process.argv[3], 'runs', process.argv[4]), {recursive:true});\n`);
      chmodSync(racer, 0o700);
      vi.stubEnv("YOROZU_SECRETARY_HOST", racer);
    }
    if (fault === "locked-host") {
      holder = spawn(host, ["--secretary", root, "held-fixture", workspace, process.execPath, fileURLToPath(new URL("../dist/secretary-worker.js", import.meta.url))], { stdio: ["pipe", "pipe", "ignore"] });
      const opened = new Promise<void>((resolve) => holder!.stdout!.once("data", () => resolve()));
      holder.stdin!.write(`${JSON.stringify({ version: 1, id: "1", op: "snapshot" })}\n`);
      await opened;
    }
    appendThreadEvent({ id: "host-start", threadId: SECRETARY_THREAD_ID, agentId: "main", ts: Date.now(), kind: "message", data: { role: "user", text: "DONE" } }, state);
    setNativeTurn(SECRETARY_THREAD_ID, { id: "native:host-start:final", userEventId: "host-start", state: "running" }, state);
    const abort = new AbortController();
    if (fault === "before-submit-stop") abort.abort();
    const result = await runner.run({ threadId: SECRETARY_THREAD_ID, cwd: workspace, text: "DONE", signal: abort.signal });
    if (fault === "raced-run") {
      expect(result).toMatchObject({ unconfirmed: true });
      vi.stubEnv("YOROZU_SECRETARY_HOST", join(temp, "missing-host"));
      expect(await runner.run({ threadId: SECRETARY_THREAD_ID, cwd: workspace, text: "DONE", signal: abort.signal }))
        .toMatchObject({ unconfirmed: true }); // The same run now predates this invocation.
    }
    else {
      expect(result).toMatchObject({ cessation: "process-exited", text: expect.stringContaining("no Codex turn was submitted") });
      expect(result.failed === true).toBe(fault !== "before-submit-stop");
    }
  } finally {
    if (holder) { const closed = new Promise<void>((resolve) => holder!.once("close", () => resolve())); holder.stdin!.end(); await closed; }
    vi.unstubAllEnvs(); rmSync(temp, { recursive: true, force: true });
  }
}, 10000);

// Primary coordinator contract: actual host admissions and real Rust/Node workers with an
// official-protocol peer. The peer only supplies model decisions and controlled completion;
// the runtime must create, route, persist and project the independent work itself.
test("coordinator answers another topic while two specialists run and targets only the corrected task", async () => {
  const { temp, state, rows } = fixture();
  const release = join(temp, "release-task");
  const result = join(temp, "result");
  vi.stubEnv("CODEX_FIXTURE_RELEASE", release);
  vi.stubEnv("CODEX_FIXTURE_RESULT", result);
  let sidecar: ReturnType<typeof serveSecretary> | undefined;
  let socket: ReturnType<typeof createConnection> | undefined;
  const events: any[] = [];
  const connect = async () => {
    await vi.waitFor(() => expect(existsSync(join(state, "local.sock"))).toBe(true));
    socket = createConnection(join(state, "local.sock"));
    createInterface({ input: socket }).on("line", (line) => events.push(JSON.parse(line))).on("error", () => {});
    await new Promise<void>((resolve, reject) => { socket!.once("connect", resolve); socket!.once("error", reject); });
  };
  const send = (id: string, text: string) => socket!.write(`${JSON.stringify({ id, threadId: SECRETARY_THREAD_ID,
    ts: Date.now(), agentId: "main", kind: "message", data: { role: "user", text, delivery: "steer" } })}\n`);
  const completed = (id: string) => readThreadEvents(SECRETARY_THREAD_ID, state).find((event) => event.id === `native:${id}:final` && event.data.done);
  try {
    sidecar = serveSecretary({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} });
    await connect();
    send("coordinate-tasks", "TASKS");
    await vi.waitFor(() => expect(completed("coordinate-tasks")?.data.text).toContain("delegated (file)"));
    await vi.waitFor(() => expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(3));
    const workers = listThreads(state).filter((thread) => thread.id.startsWith("secretary-task-"));
    expect(workers).toHaveLength(2);
    expect(new Set(workers.map((thread) => thread.cwd)).size).toBe(2);
    send("separate-topic", "HELLO");
    await vi.waitFor(() => expect(completed("separate-topic")?.data.text).toBe("Hello, how can I help?"));
    expect(existsSync(result + "-one")).toBe(false);
    expect(existsSync(result + "-two")).toBe(false);
    expect(rows().filter((row) => row.method === "turn/steer")).toHaveLength(0);
    send("correct-first", "CHANGE_FIRST");
    await vi.waitFor(() => expect(completed("correct-first")?.data.text).toContain("change received by the active task"));
    const corrections = rows().filter((row) => row.method === "turn/steer");
    expect(corrections).toHaveLength(1);
    const correctedStart = rows().find((row) => row.method === "turn/start" && row.pid === corrections[0].pid);
    expect(correctedStart.params.input[0].text).toContain("Task: CONTROLLED_ONE");
    const firstHistory = readThreadEvents(workers.find((thread) => thread.title === "First task")!.id, state);
    expect(firstHistory.some((event) => event.kind === "message" && event.data.role === "user" && event.data.delivery === "steer" && event.data.text === "write B instead")).toBe(true);
    const first = workers.find((thread) => thread.title === "First task")!;
    socket!.write(`${JSON.stringify({ id: "direct-task-change", threadId: first.id, ts: Date.now(), agentId: "main",
      kind: "message", data: { role: "user", text: "write B instead", delivery: "queue" } })}\n`);
    await vi.waitFor(() => expect(readThreadEvents(first.id, state).find((event) => event.id === "native:direct-task-change:final")?.data.done).toBe(true));
    expect(readThreadEvents(SECRETARY_THREAD_ID, state).find((event) => event.id === `task-card:${first.id}`)?.data.done).toBe(false);
    writeFileSync(release + "-two", "finish second first");
    await vi.waitFor(() => expect(readFileSync(result + "-two", "utf8")).toBe("A"));
    writeFileSync(release + "-one", "finish corrected first");
    await vi.waitFor(() => expect(readFileSync(result + "-one", "utf8")).toBe("B"));
    await vi.waitFor(() => expect(readThreadEvents(SECRETARY_THREAD_ID, state).filter((event) => event.parentAgentId && event.data.done)).toHaveLength(2));
    const cards = [...new Map(readThreadEvents(SECRETARY_THREAD_ID, state).filter((event) => event.parentAgentId).map((event) => [event.id, event])).values()];
    expect(cards.every((event) => event.data.replyTo === "coordinate-tasks")).toBe(true);
    expect(cards.every((event) => event.ts < completed("separate-topic")!.ts)).toBe(true);
    expect(cards.map((event) => event.data.text).sort()).toEqual(["one wrote B", "two wrote A"]);
    socket!.write(`${JSON.stringify({ id: "late-task-change", threadId: first.id, ts: Date.now(), agentId: "main",
      kind: "message", data: { role: "user", text: "write C instead", delivery: "queue" } })}\n`);
    await vi.waitFor(() => expect(readThreadEvents(first.id, state).find((event) => event.id === "native:late-task-change:final")?.data.text).toContain("not queued"));
    const planningStarts = rows().filter((row) => ["thread/start", "thread/resume"].includes(row.method) && row.params.developerInstructions);
    expect(planningStarts).toHaveLength(3);
    for (const start of planningStarts) {
      expect(start.params.sandbox).toBe("read-only");
      expect(start.params.config).toMatchObject({ "features.apps": false, "features.plugins": false,
        "features.shell_tool": false, "features.unified_exec": false, "mcp_servers.fixture_connector.enabled": false, web_search: "disabled" });
    }
    expect(rows().filter((row) => row.method === "turn/start" && row.params.outputSchema).every((row) => row.params.environments.length === 0)).toBe(true);
    const count = rows().filter((row) => row.method === "turn/start").length;
    socket!.destroy(); await sidecar.close();
    events.length = 0;
    sidecar = serveSecretary({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} });
    await connect();
    // Replay exact accepted identities, preserving original timestamp and immutable payload.
    for (const id of ["coordinate-tasks", "correct-first"]) {
      const original = readThreadEvents(SECRETARY_THREAD_ID, state).find((event) => event.id === id)!;
      socket!.write(`${JSON.stringify(original)}\n`);
    }
    await vi.waitFor(() => expect(events.some((event) => event.kind === "receipt" && event.data.eventId === "correct-first")).toBe(true));
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(count);
    expect(rows().filter((row) => row.method === "turn/steer")).toHaveLength(2);
    expect(new Set(readThreadEvents(SECRETARY_THREAD_ID, state).filter((event) => event.parentAgentId).map((event) => event.id)).size).toBe(2);
  } finally {
    writeFileSync(release + "-one", "cleanup"); writeFileSync(release + "-two", "cleanup");
    socket?.destroy(); await sidecar?.close(); vi.unstubAllEnvs();
    // A restarted host's background model probe can finish during recursive removal.
    // Retry only filesystem cleanup races; all behavior assertions have already run.
    rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }
}, 20000);

test("long Japanese task history leaves room for conversation and an oversized message does not poison later turns", async () => {
  const { temp, state, rows } = fixture();
  for (let index = 0; index < 24; index++) {
    const id = `secretary-task-${index.toString(16).padStart(64, "0")}`;
    const requestId = `task-request-${createHash("sha256").update(id).digest("hex")}`;
    const path = join(state, "secretary-tasks-v1", id);
    mkdirSync(path, { recursive: true });
    writeFileSync(join(path, "task.json"), JSON.stringify({ version: 1, id, requestId, parentEventId: `old-${index}`,
      createdAt: index + 1, title: `過去の作業 ${index}`, specialty: "調査", instruction: "完了済みの作業" }));
    createThread(`過去の作業 ${index}`, state, id, { agent: "codex", cwd: temp });
    appendThreadEvent({ id: `native:${requestId}:final`, threadId: id, ts: index + 2, agentId: "main", kind: "message",
      data: { role: "agent", text: "調査結果です。".repeat(1500), done: true } }, state);
  }
  let sidecar: ReturnType<typeof serveSecretary> | undefined;
  let socket: ReturnType<typeof createConnection> | undefined;
  const send = (id: string, text: string) => socket!.write(`${JSON.stringify({ id, threadId: SECRETARY_THREAD_ID,
    ts: Date.now(), agentId: "main", kind: "message", data: { role: "user", text, delivery: "steer" } })}\n`);
  const final = (id: string) => readThreadEvents(SECRETARY_THREAD_ID, state).find((event) => event.id === `native:${id}:final`);
  try {
    sidecar = serveSecretary({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} });
    await vi.waitFor(() => expect(existsSync(join(state, "local.sock"))).toBe(true));
    socket = createConnection(join(state, "local.sock"));
    createInterface({ input: socket }).on("line", () => {}).on("error", () => {});
    await new Promise<void>((resolve, reject) => { socket!.once("connect", resolve); socket!.once("error", reject); });
    send("long-history", "HELLO");
    await vi.waitFor(() => expect(final("long-history")?.data.text).toBe("Hello, how can I help?"));
    send("too-long", "界".repeat(22000));
    await vi.waitFor(() => expect(final("too-long")?.data.text).toContain("shorter message"));
    send("too-escaped", '"'.repeat(40000));
    await vi.waitFor(() => expect(final("too-escaped")?.data.text).toContain("shorter message"));
    send("after-long", "HELLO");
    await vi.waitFor(() => expect(final("after-long")?.data.text).toBe("Hello, how can I help?"));
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(2);
  } finally { socket?.destroy(); await sidecar?.close(); vi.unstubAllEnvs(); rmSync(temp, { recursive: true, force: true }); }
}, 10000);

test("specialist approval remains required under legacy YOLO and Stop leaves other work and main chat usable", async () => {
  const { temp, state, rows } = fixture();
  const release = join(temp, "release-task");
  vi.stubEnv("CODEX_FIXTURE_RELEASE", release);
  vi.stubEnv("CODEX_FIXTURE_RESULT", join(temp, "result"));
  vi.stubEnv("CODEX_FIXTURE_TASK_APPROVAL", "1");
  let sidecar: ReturnType<typeof serveSecretary> | undefined;
  let socket: ReturnType<typeof createConnection> | undefined;
  const events: any[] = [];
  const send = (id: string, text: string) => socket!.write(`${JSON.stringify({ id, threadId: SECRETARY_THREAD_ID,
    ts: Date.now(), agentId: "main", kind: "message", data: { role: "user", text, delivery: "steer" } })}\n`);
  try {
    sidecar = serveSecretary({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} });
    await vi.waitFor(() => expect(existsSync(join(state, "local.sock"))).toBe(true));
    socket = createConnection(join(state, "local.sock"));
    createInterface({ input: socket }).on("line", (line) => events.push(JSON.parse(line))).on("error", () => {});
    await new Promise<void>((resolve, reject) => { socket!.once("connect", resolve); socket!.once("error", reject); });
    socket.write(`${JSON.stringify({ id: "legacy-yolo", threadId: SECRETARY_THREAD_ID, ts: Date.now(), agentId: "main",
      kind: "approval_settings", data: { yolo: true, hours: 1 } })}\n`);
    send("approval-tasks", "TASKS");
    await vi.waitFor(() => expect(events.some((event) => event.kind === "approval_card")).toBe(true));
    const card = events.find((event) => event.kind === "approval_card");
    expect(card.threadId).not.toBe(SECRETARY_THREAD_ID);
    expect(card.data.actionClass).toBe("commandExecution");
    expect(rows().some((row) => row.taskApproval)).toBe(false);
    await vi.waitFor(() => expect(readThreadEvents(SECRETARY_THREAD_ID, state).findLast((event) => event.id === `task-card:${card.threadId}`)?.data.text).toContain("Your answer is needed"));
    send("during-approval", "HELLO");
    await vi.waitFor(() => expect(readThreadEvents(SECRETARY_THREAD_ID, state).find((event) => event.id === "native:during-approval:final")?.data.text).toBe("Hello, how can I help?"));
    expect(rows().some((row) => row.taskApproval)).toBe(false);
    send("change-during-approval", "CHANGE_FIRST");
    await vi.waitFor(() => expect(readThreadEvents(SECRETARY_THREAD_ID, state).find((event) => event.id === "native:change-during-approval:final")?.data.text).toContain("not delivered and was not queued"));
    expect(rows().filter((row) => row.method === "turn/steer")).toHaveLength(0);
    send("stop-first", "STOP_FIRST");
    await vi.waitFor(() => expect(events.some((event) => event.kind === "stop_status" && event.threadId === card.threadId && event.data.status === "stopped"), JSON.stringify(events.filter((event) => event.kind === "stop_status" || event.kind === "message" && event.data.done))).toBe(true));
    expect(events.some((event) => event.kind === "approval_answer" && event.data.actionId === card.data.actionId && event.data.answer === "no")).toBe(true);
    expect(rows().filter((row) => row.method === "turn/interrupt")).toHaveLength(1);
    expect(existsSync(join(temp, "result-one"))).toBe(false);
    writeFileSync(release + "-two", "finish unaffected task");
    await vi.waitFor(() => expect(readFileSync(join(temp, "result-two"), "utf8")).toBe("A"));
    send("after-stop", "HELLO");
    await vi.waitFor(() => expect(readThreadEvents(SECRETARY_THREAD_ID, state).find((event) => event.id === "native:after-stop:final")?.data.text).toBe("Hello, how can I help?"));
  } finally {
    writeFileSync(release + "-two", "cleanup"); socket?.destroy(); await sidecar?.close();
    vi.unstubAllEnvs(); rmSync(temp, { recursive: true, force: true });
  }
}, 20000);

test("a damaged task record is held while the secretary still answers new conversation", async () => {
  const { temp, state, rows } = fixture();
  const id = `secretary-task-${"a".repeat(64)}`;
  const path = join(state, "secretary-tasks-v1", id);
  for (const letter of ["a", "b", "c", "d"]) {
    const damaged = join(state, "secretary-tasks-v1", `secretary-task-${letter.repeat(64)}`);
    mkdirSync(damaged, { recursive: true }); writeFileSync(join(damaged, "task.json"), '{"version":');
  }
  vi.stubEnv("CODEX_FIXTURE_RELEASE", join(temp, "release-task"));
  vi.stubEnv("CODEX_FIXTURE_RESULT", join(temp, "result"));
  let sidecar: ReturnType<typeof serveSecretary> | undefined;
  let socket: ReturnType<typeof createConnection> | undefined;
  try {
    sidecar = serveSecretary({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} });
    await vi.waitFor(() => expect(existsSync(join(state, "local.sock"))).toBe(true));
    socket = createConnection(join(state, "local.sock"));
    createInterface({ input: socket }).on("line", () => {}).on("error", () => {});
    await new Promise<void>((resolve, reject) => { socket!.once("connect", resolve); socket!.once("error", reject); });
    socket.write(`${JSON.stringify({ id: "after-corruption", threadId: SECRETARY_THREAD_ID, ts: Date.now(), agentId: "main",
      kind: "message", data: { role: "user", text: "HELLO", delivery: "steer" } })}\n`);
    await vi.waitFor(() => expect(readThreadEvents(SECRETARY_THREAD_ID, state).find((event) => event.id === "native:after-corruption:final")?.data.text).toBe("Hello, how can I help?"));
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(1);
    expect(readFileSync(join(path, "task.json"), "utf8")).toBe('{"version":');
    expect(readThreadEvents(SECRETARY_THREAD_ID, state).some((event) => event.data.text?.includes("task record needs repair"))).toBe(true);
    socket.write(`${JSON.stringify({ id: "fresh-after-corruption", threadId: SECRETARY_THREAD_ID, ts: Date.now(), agentId: "main",
      kind: "message", data: { role: "user", text: "TASKS", delivery: "steer" } })}\n`);
    await vi.waitFor(() => expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(4));
    expect(listThreads(state).filter((thread) => thread.id.startsWith("secretary-task-")).length).toBe(2);
  } finally { socket?.destroy(); await sidecar?.close(); vi.unstubAllEnvs(); rmSync(temp, { recursive: true, force: true }); }
}, 10000);

test("a lost tool-free planning turn does not hold later conversation or execution after restart", async () => {
  const { temp, state, rows } = fixture();
  let sidecar: ReturnType<typeof serveSecretary> | undefined;
  let socket: ReturnType<typeof createConnection> | undefined;
  const connect = async () => {
    await vi.waitFor(() => expect(existsSync(join(state, "local.sock"))).toBe(true));
    socket = createConnection(join(state, "local.sock"));
    createInterface({ input: socket }).on("line", () => {}).on("error", () => {});
    await new Promise<void>((resolve, reject) => { socket!.once("connect", resolve); socket!.once("error", reject); });
  };
  const send = (id: string, text: string) => socket!.write(`${JSON.stringify({ id, threadId: SECRETARY_THREAD_ID,
    ts: Date.now(), agentId: "main", kind: "message", data: { role: "user", text, delivery: "steer" } })}\n`);
  const final = (id: string) => readThreadEvents(SECRETARY_THREAD_ID, state).find((event) => event.id === `native:${id}:final`);
  try {
    sidecar = serveSecretary({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} }); await connect();
    send("lost-plan", "CRASH_PLANNER");
    await vi.waitFor(() => expect(final("lost-plan")?.data.text).toContain("No new task was dispatched"));
    send("after-lost-plan", "HELLO");
    await vi.waitFor(() => expect(final("after-lost-plan")?.data.text).toBe("Hello, how can I help?"));
    socket!.destroy(); await sidecar.close();
    sidecar = serveSecretary({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} }); await connect();
    send("after-plan-restart", "HELLO");
    await vi.waitFor(() => expect(final("after-plan-restart")?.data.text).toBe("Hello, how can I help?"));
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(3);
    expect(listThreads(state).filter((thread) => thread.id.startsWith("secretary-task-"))).toHaveLength(0);
  } finally { socket?.destroy(); await sidecar?.close(); vi.unstubAllEnvs(); rmSync(temp, { recursive: true, force: true }); }
}, 10000);

test("refused specialist setup reports not-started and preserves the conflicting user file", async () => {
  const { temp, state, rows } = fixture();
  let sidecar: ReturnType<typeof serveSecretary> | undefined;
  let socket: ReturnType<typeof createConnection> | undefined;
  try {
    sidecar = serveSecretary({ stateDir: state, relayUrl: "ws://127.0.0.1:9", log: () => {} });
    const conflict = join(temp, "projects", "Yorozu Secretary Tasks");
    writeFileSync(conflict, "preserve this existing file");
    await vi.waitFor(() => expect(existsSync(join(state, "local.sock"))).toBe(true));
    socket = createConnection(join(state, "local.sock"));
    createInterface({ input: socket }).on("line", () => {}).on("error", () => {});
    await new Promise<void>((resolve, reject) => { socket!.once("connect", resolve); socket!.once("error", reject); });
    socket.write(`${JSON.stringify({ id: "refused-task", threadId: SECRETARY_THREAD_ID, ts: Date.now(), agentId: "main",
      kind: "message", data: { role: "user", text: "TASKS", delivery: "steer" } })}\n`);
    await vi.waitFor(() => expect(readThreadEvents(SECRETARY_THREAD_ID, state).find((event) => event.parentAgentId)?.data)
      .toMatchObject({ failed: true, done: true, text: expect.stringContaining("task was not started") }));
    expect(rows().filter((row) => row.method === "turn/start")).toHaveLength(1);
    expect(readFileSync(conflict, "utf8")).toBe("preserve this existing file");
  } finally { socket?.destroy(); await sidecar?.close(); vi.unstubAllEnvs(); rmSync(temp, { recursive: true, force: true }); }
}, 10000);
