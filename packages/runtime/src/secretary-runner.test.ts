/** Real Rust/Node/official-adapter boundary, with a local protocol peer instead of live Codex. */
import { expect, test, vi } from "vitest";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { secretaryRunner, SECRETARY_THREAD_ID } from "../dist/secretary-runner.js";
import { appendThreadEvent, createThread, listThreads, setNativeTurn, setThreadSession, threadHome } from "../dist/threads.js";
import type { NativeTurn } from "./native.js";

const peer = `#!${process.execPath}
const fs = require('node:fs');
const lines = require('node:readline').createInterface({ input: process.stdin });
const send = value => process.stdout.write(JSON.stringify(value) + '\\n');
const log = value => fs.appendFileSync(process.env.CODEX_FIXTURE_LOG, JSON.stringify(value) + '\\n');
const session = 'fixture-native-session';
let mode = '';
lines.on('line', line => {
  const frame = JSON.parse(line);
  if (frame.method) log({ method: frame.method, params: frame.params });
  if (frame.method === 'initialize') send({ id: frame.id, result: {} });
  if (['thread/start', 'thread/resume'].includes(frame.method)) send({ id: frame.id, result: { thread: { id: session } } });
  if (frame.method === 'turn/start') {
    const records = JSON.parse(fs.readFileSync(process.env.CODEX_FIXTURE_STATE + '/threads.json', 'utf8'));
    log({ persistedBeforeStart: records.find(t => t.id === 'yorozu-secretary-v1').nativeSessionId === session });
    mode = frame.params.input[0].text;
    send({ id: frame.id, result: { turn: { id: 'fixture-turn' } } });
    if (mode === 'FAIL') { process.exit(8); return; }
    if (mode === 'STOP') return;
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
    send({ id: frame.id, result: {} });
    send({ method: 'turn/completed', params: { threadId: session, turn: { id: 'fixture-turn', status: 'interrupted' } } });
  }
});
`;

test("secretary preserves legacy data, durable replay, session continuity and native controls", async () => {
  const temp = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-secretary-wire-")));
  const state = join(temp, "state");
  const bin = join(temp, "bin");
  mkdirSync(bin);
  writeFileSync(join(bin, "codex"), peer);
  chmodSync(join(bin, "codex"), 0o700);
  vi.stubEnv("YOROZU_PROJECTS_DIR", join(temp, "projects"));
  vi.stubEnv("PATH", `${bin}:${dirname(process.execPath)}`);
  vi.stubEnv("HOME", temp);
  vi.stubEnv("CODEX_FIXTURE_STATE", state);
  vi.stubEnv("CODEX_FIXTURE_LOG", join(temp, "protocol.jsonl"));
  const rows = (): any[] => readFileSync(join(temp, "protocol.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
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
