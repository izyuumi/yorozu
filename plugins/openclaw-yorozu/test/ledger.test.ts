import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { setImmediate as immediate } from "node:timers/promises";
import "./genui-hooks.ts";
import { host, yorozuRuntime } from "./genui-host.js";
import { createLedger, type LedgerDeps, type RunRecord, type Store } from "../src/ledger.ts";
const { openLedger } = await import("../src/runs.ts");

const day = 24 * 60 * 60 * 1000;
const convId = "11111111-1111-4111-8111-111111111111";
const message = (messageId: string) => ({ convId, messageId, text: "hi" });
const runs = (): Store<RunRecord> => yorozuRuntime.getRuntime().state.openKeyedStore({ namespace: "runs", maxEntries: 10_000 });
const record = (boot: string, state: RunRecord["state"], at = day): RunRecord => ({ convId, at, boot, state });
const log = (lines: string[]) => ({ info: (line: string) => lines.push(line), warn: (line: string) => lines.push(line) });
const fixture = (bootId: string, overrides: Partial<LedgerDeps> = {}) => {
  const lines: string[] = [];
  return {
    ledger: createLedger({ runs, bootId, now: () => day, log: log(lines), inTranscript: () => "missing", ...overrides }),
    lines,
  };
};

beforeEach(() => {
  host.stores.clear();
  host.entries = undefined;
  host.register = undefined;
  host.calls = [];
});

test("every write stamps its boot, including a parked rerun after a restart", async () => {
  const { ledger: first } = fixture("A");
  await first.load();
  first.claim(message("m"));
  await first.handing("m", convId);
  first.runStarted("m", 0, false);
  first.turnEnded("m", convId, { parked: true, queued: false });
  await first.idle();

  const { ledger: second } = fixture("B", { now: () => day + 1 });
  await second.load();
  await second.handing("m", convId);
  second.turnEnded("m", convId, { parked: false, queued: false });
  await second.idle();

  assert.deepEqual(host.calls.map(({ value }: { value: RunRecord }) => value), [
    record("A", "accepted"), record("A", "handed"), record("A", "started"), record("A", "parked"),
    record("B", "handed"), record("B", "settled"),
  ], "every write carries its process boot and preserves receipt time");
  assert.deepEqual(await runs().lookup("m"), record("B", "settled"));
});

test("start-up counts group earlier unfinished entries by boot", async () => {
  for (const state of ["accepted", "handed", "started", "parked", "settled"] as const) {
    await runs().register(state, record("A", state));
  }
  await runs().register("b", record("B", "settled"));
  await runs().register("c", record("C", "handed"));
  const { ledger } = fixture("C");
  assert.equal(await ledger.load(), "loaded");
  assert.deepEqual(ledger.counts(), [
    "yorozu: restart ledger A: not handed 1, handed not started 1, started 1, parked 1",
  ], "only boot A has unfinished entries from an earlier process");
});

test("start-up counts log once across a reload and module re-import", async () => {
  await runs().register("prior", record("A", "handed", Date.now()));
  await runs().register("current", record(`${process.pid}:${Math.round(performance.timeOrigin)}`, "started", Date.now()));
  const first: string[] = [];
  const later: string[] = [];
  const ledger = await openLedger({ cfg: {}, agent: "main", log: log(first) } as never);
  // A later load must keep its first result even when the store goes down.
  host.entries = "reject";
  assert.equal(await ledger.load(), "loaded");
  assert.equal(await openLedger({ cfg: {}, agent: "other", log: log(later) } as never), ledger);
  host.entries = undefined;

  const reimport = await import(new URL("../src/runs.ts?reimport", import.meta.url).href);
  await reimport.openLedger({ cfg: {}, agent: "other", log: log(later) });
  assert.deepEqual(first, [
    "yorozu: restart ledger A: not handed 0, handed not started 1, started 0, parked 0",
  ], "one start-up count line was logged on first open");
  assert.deepEqual(later, []);
});

test("degraded ledger dedupes from the transcript and remembers reads in memory", async () => {
  host.entries = "reject";
  const reads: string[] = [];
  const { ledger, lines } = fixture("A", {
    inTranscript: (conversation, id) => {
      assert.equal(conversation, convId);
      reads.push(id);
      return id === "found" ? "found" : id === "unreadable" ? "unreadable" : "missing";
    },
  });
  const status = await ledger.load();
  host.entries = undefined;
  const reloaded = await ledger.load();
  const claims = ["found", "found", "unreadable", "unreadable", "missing"].map((id) => ledger.claim(message(id)));
  await ledger.idle();
  assert.deepEqual([status, reloaded, ...claims], [
    "degraded", "degraded", "duplicate", "duplicate", "fresh", "duplicate", "fresh",
  ], "fails open on an unreadable transcript and skips in-memory and transcript duplicates");
  assert.deepEqual(reads, ["found", "unreadable", "missing"]);
  assert.deepEqual(ledger.counts(), []);
  assert.ok(lines.includes("yorozu: run ledger unavailable: Error: store down"));
  assert.equal(lines.filter((line) => line.startsWith("yorozu: run ledger transcript check failed: ")).length, 1);
  assert.equal((await runs().lookup("missing"))?.state, "accepted");
});

test("load drops expired claims from memory and the store", async () => {
  await runs().register("expired", record("A", "settled", 0));
  await runs().register("within-window", record("A", "settled", 1));
  const { ledger } = fixture("B", { now: () => day + 1 });
  await ledger.load();
  assert.equal(await runs().lookup("expired"), undefined, "load deletes the expired row from the reopened store");
  assert.equal(ledger.claim(message("within-window")), "duplicate");
  assert.equal(ledger.claim(message("expired")), "fresh");
  await ledger.idle();
});

test("claims prune by receipt age even when the replay is the next claim", async () => {
  let now = 0;
  const { ledger } = fixture("A", { now: () => now });
  await ledger.load();
  ledger.claim(message("m"));
  now = day;
  assert.equal(ledger.claim(message("m")), "duplicate", "the claim is valid through the 24-hour boundary");
  now++;
  assert.equal(ledger.claim(message("m")), "fresh");
  await ledger.idle();
});

test("claims retain the latest 10,000 ids", async () => {
  const { ledger } = fixture("A");
  await ledger.load();
  for (let i = 0; i <= 10_000; i++) ledger.claim(message(String(i)));
  assert.equal(ledger.claim(message("1")), "duplicate", "the newest 10,000 claims remain known");
  assert.equal(ledger.claim(message("0")), "fresh");
  await ledger.idle();
});

test("degraded runtime checks user transport ids in the currently bound conversation", async (t) => {
  const id = "22222222-2222-4222-8222-222222222222";
  const unreadable = "33333333-3333-4333-8333-333333333333";
  const sessionKey = (agent: string) => `agent:${agent}:yorozu:direct:owner:thread:${convId}`;
  host.sessions.set(sessionKey("other"), { sessionId: "transcript" });
  host.transcripts.set("transcript", [
    { type: "message", id: "event", message: { role: "user", content: "hi", __openclaw: { transport: { messageId: id } } } },
  ]);
  const read = host.transcripts.get.bind(host.transcripts);
  const get = t.mock.method(host.transcripts, "get", (key: string) => read(key));
  const first: string[] = [];
  const later: string[] = [];
  host.entries = "reject";
  const binding = await import(new URL("../src/runs.ts?degraded", import.meta.url).href);
  const ledger = await binding.openLedger({ cfg: {}, agent: "main", log: log(first) });
  await binding.openLedger({ cfg: {}, agent: "other", log: log(later) });
  const replay = ledger.claim(message(id));
  get.mock.mockImplementation(() => { throw new Error("transcript down"); });
  const fresh = ledger.claim(message(unreadable));
  const reads = get.mock.callCount();
  const duplicate = ledger.claim(message(unreadable));
  await ledger.idle();

  assert.deepEqual([replay, fresh, duplicate], ["duplicate", "fresh", "duplicate"], "the degraded binding uses the reloaded agent's transcript");
  assert.ok(reads > 0);
  assert.equal(get.mock.callCount(), reads);
  assert.deepEqual(first, ["yorozu: run ledger unavailable: Error: store down"]);
  assert.equal(later.filter((line) => line.startsWith("yorozu: run ledger transcript check failed: ")).length, 1);
});

test("a slow accepted write cannot land after handed, started or settled", async () => {
  const { ledger } = fixture("A");
  await ledger.load();
  host.register = async (_namespace: string, _key: string, value: RunRecord) => {
    if (value.state === "accepted") await new Promise((resolve) => setImmediate(resolve));
  };
  ledger.claim(message("m"));
  const handed = ledger.handing("m", convId);
  ledger.runStarted("m", 0, false);
  ledger.turnEnded("m", convId, { parked: false, queued: false });
  await handed;
  await ledger.idle();

  assert.deepEqual(host.calls.map(({ value }: { value: RunRecord }) => value.state), [
    "accepted", "handed", "started", "settled",
  ], "writes for one id land in call order");
  assert.deepEqual(await runs().lookup("m"), record("A", "settled"));
});

test("handing resolves at its deadline and later writes wait for handed to land", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { ledger, lines } = fixture("A", { handDeadlineMs: 20 });
  const release = Promise.withResolvers<void>();
  t.after(() => release.resolve());
  host.register = (_namespace: string, _key: string, value: RunRecord) => {
    if (value.state === "handed") return release.promise;
  };
  await ledger.load();
  ledger.claim(message("m"));
  let returned = false;
  void ledger.handing("m", convId).then(() => { returned = true; });

  t.mock.timers.tick(19);
  await immediate();
  assert.equal(returned, false, "handing must wait before the deadline");
  assert.deepEqual(lines, []);
  t.mock.timers.tick(1);
  await immediate();
  assert.equal(returned, true, "handing must resolve at the deadline");
  assert.deepEqual(lines, ["yorozu: run ledger write slow m handed"]);

  ledger.runStarted("m", 0, false);
  ledger.turnEnded("m", convId, { parked: false, queued: false });
  await immediate();
  assert.equal((await runs().lookup("m"))?.state, "accepted");
  release.resolve();
  await ledger.idle();
  assert.deepEqual(host.calls.map(({ value }: { value: RunRecord }) => value.state), [
    "accepted", "handed", "started", "settled",
  ]);
  assert.deepEqual(await runs().lookup("m"), record("A", "settled"));
});
