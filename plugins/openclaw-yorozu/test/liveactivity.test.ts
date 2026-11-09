import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import {
  applyTurn,
  cleanJobs,
  contentState,
  holdFor,
  LINGER_MS,
  MAX_STEPS,
  plan,
  STEP_INTERVAL_MS,
  tidy,
  validReport,
  type TurnChange,
  type WireJob,
} from "../src/liveactivity.ts";

// 2027-01-15T08:00:00Z, the instant the Swift fixture test reads back.
const T0 = 1_800_000_000_000;
const CONV = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b";
const OTHER = "0a1b2c3d-4e5f-4a6b-8c7d-8e9f0a1b2c3d";
const TURN = "AAAAAAAAAAAAAAAA";
const REC = "recLocal-_012345";

const turn = (over: Partial<WireJob> = {}): WireJob => ({ token: TURN, kind: "turn", state: "running", steps: 1, startedAt: T0, ...over });
const recording: WireJob = { token: REC, kind: "recording", state: "running", startedAt: T0 + 10_500 };
const turns = { [TURN]: CONV };

test("a plugin-made content state matches the fixture the app's decoder reads", () => {
  const fixture = readFileSync(new URL("../../../apps/ios/Tests/Fixtures/activity-content-state.json", import.meta.url), "utf8");
  const stepped = applyTurn([turn(), recording], turns, CONV, { kind: "step", steps: 2 }, T0 + 30_000);
  const done = applyTurn(stepped, turns, CONV, { kind: "done" }, T0 + 60_250);
  assert.equal(JSON.stringify(contentState(done)), JSON.stringify(JSON.parse(fixture)));
});

test("only the conversation's running turn changes; local jobs pass through unchanged", () => {
  const other = turn({ token: "BBBBBBBBBBBBBBBB", startedAt: T0 + 1 });
  const jobs = [recording, other, turn()];
  const map = { ...turns, BBBBBBBBBBBBBBBB: OTHER };
  const next = applyTurn(jobs, map, CONV, { kind: "step", steps: 4 }, T0 + 5);
  assert.deepEqual(next.find((job) => job.token === TURN)?.steps, 4);
  assert.deepEqual(next.find((job) => job.token === REC), recording);
  assert.deepEqual(next.find((job) => job.token === other.token), other);
  assert.equal(applyTurn(next, map, CONV, { kind: "step", steps: 2 }, T0 + 6).find((job) => job.token === TURN)?.steps, 4);
  assert.deepEqual(applyTurn(jobs, map, CONV, { kind: "gone" }, T0 + 7).map((job) => job.token), [REC, other.token]);
  const failed = applyTurn(jobs, map, CONV, { kind: "failed" }, T0 + 8).find((job) => job.token === TURN);
  assert.equal(failed?.state, "failed");
  assert.equal(failed?.finishedAt, T0 + 8);
  assert.deepEqual(applyTurn([turn()], {}, CONV, { kind: "done" }, T0 + 9), [turn()]);
});

test("host push is a full snapshot", () => {
  const needsYou: WireJob = { token: "DDDDDDDDDDDDDDDD", kind: "needsYou", state: "running", startedAt: T0 - 100 };
  const finished = turn({ token: "CCCCCCCCCCCCCCCC", state: "done", finishedAt: T0 });
  const before = cleanJobs([turn(), needsYou, finished]);
  const map = { ...turns, [needsYou.token]: OTHER };
  const now = T0 + 1_000;
  const after = applyTurn(before, map, CONV, { kind: "done" }, now);
  const push = plan(before, after, now);

  assert.ok(push);
  assert.equal(push.state.jobs.length, 3);
  assert.deepEqual(push.state.jobs.find((job) => job.token === needsYou.token), {
    token: needsYou.token, kind: "needsYou", state: "running", startedAt: 821_692_799.9,
  });
  assert.equal(push.state.jobs.find((job) => job.token === TURN)?.state, "done");
  assert.equal(push.state.jobs.find((job) => job.token === finished.token)?.state, "done");
  assert.equal(push.priority, 10);
});

test("the host never creates a needsYou row", () => {
  const needsYou: WireJob = { token: "DDDDDDDDDDDDDDDD", kind: "needsYou", state: "running", startedAt: T0 - 100 };
  const changes: TurnChange[] = [{ kind: "step", steps: 2 }, { kind: "done" }, { kind: "failed" }, { kind: "gone" }];
  for (const before of [cleanJobs([turn()]), cleanJobs([turn(), needsYou])]) {
    const tokens = new Set(before.filter((job) => job.kind === "needsYou").map((job) => job.token));
    for (const change of changes) {
      const after = applyTurn(before, turns, CONV, change, T0 + 1_000);
      assert.ok(after.filter((job) => job.kind === "needsYou").every((job) => tokens.has(job.token)), change.kind);
    }
  }
});

test("a needsYou row the host has not been told about is absent from its push", () => {
  const before = cleanJobs([turn()]);
  const now = T0 + 1_000;
  const after = applyTurn(before, turns, CONV, { kind: "step", steps: 2 }, now);
  const push = plan(before, after, now);

  assert.ok(push);
  assert.equal(push.state.jobs.find((job) => job.token === TURN)?.steps, 2);
  // Removing the extension writer now would lose needs-you rows absent from the app's report.
  assert.equal(push.state.jobs.some((job) => job.kind === "needsYou"), false);
});

test("finished rows linger, then go, and the order matches the app's", () => {
  const finished = turn({ token: "CCCCCCCCCCCCCCCC", state: "done", finishedAt: T0 });
  const ask: WireJob = { token: "DDDDDDDDDDDDDDDD", kind: "needsYou", state: "running", startedAt: T0 - 100 };
  assert.deepEqual(tidy([finished, turn(), recording, ask], T0 + 1).map((job) => job.token), [ask.token, REC, TURN, finished.token]);
  assert.deepEqual(tidy([finished], T0 + LINGER_MS).length, 0);
});

test("steps wait at priority 5, a finished turn goes at 10, and the last running job ending ends the activity", () => {
  const before = [turn(), recording];
  const stepped = applyTurn(before, turns, CONV, { kind: "step", steps: 3 }, T0 + 1_000);
  const step = plan(before, stepped, T0 + 1_000);
  assert.equal(step?.event, "update");
  assert.equal(step?.priority, 5);
  assert.equal(step?.staleDate, Math.ceil((T0 + 1_000 + 15 * 60_000) / 1000));
  assert.equal(plan(stepped, stepped, T0 + 2_000), null);

  const done = applyTurn(stepped, turns, CONV, { kind: "done" }, T0 + 2_000);
  assert.deepEqual(plan(stepped, done, T0 + 2_000)?.priority, 10);
  assert.equal(plan(stepped, done, T0 + 2_000)?.event, "update");

  const alone = applyTurn([turn()], turns, CONV, { kind: "done" }, T0 + 3_000);
  const end = plan([turn()], alone, T0 + 3_000);
  assert.equal(end?.event, "end");
  assert.equal(end?.priority, 10);
  assert.equal(end?.dismissalDate, Math.ceil((T0 + 3_000 + LINGER_MS) / 1000));
  const empty = plan([turn()], applyTurn([turn()], turns, CONV, { kind: "gone" }, T0 + 4_000), T0 + 4_000);
  assert.equal(empty?.event, "end");
  assert.equal(empty?.dismissalDate, Math.ceil((T0 + 4_000) / 1000));
});

test("a step push waits out the interval; an urgent one never waits", () => {
  assert.equal(holdFor(5, undefined, T0), 0);
  assert.equal(holdFor(5, T0, T0 + 4_000), STEP_INTERVAL_MS - 4_000);
  assert.equal(holdFor(5, T0, T0 + STEP_INTERVAL_MS), 0);
  assert.equal(holdFor(10, T0, T0 + 1), 0);
});

test("a report carries only opaque tokens, kinds, states, counts and times", () => {
  const report = { pushToken: "ab".repeat(32), jobs: [turn(), recording], turns };
  assert.equal(validReport(report), true);
  assert.equal(validReport({ jobs: [], turns: {} }), true);
  assert.equal(validReport({ ...report, pushToken: "xyz" }), false);
  assert.equal(validReport({ ...report, turns: { [TURN]: "not-a-conversation" } }), false);
  // A job of a kind or state this plugin does not know is valid, and dropped before it reaches the relay.
  const unknown = [{ ...turn(), kind: "tool" }, { ...recording, state: "paused" }] as unknown as WireJob[];
  assert.equal(validReport({ ...report, jobs: [...unknown, turn()] }), true);
  assert.deepEqual(cleanJobs([...unknown, turn()]), [turn()]);
  assert.equal(validReport({ ...report, jobs: [{ ...turn(), kind: 1 }] }), false);
  assert.equal(validReport({ ...report, extra: 1 }), true);
  assert.equal(validReport({ ...report, jobs: [{ ...turn(), token: "short" }] }), false);
  assert.equal(validReport({ ...report, jobs: Array(9).fill(turn()) }), false);
  const extra = { ...turn(), title: "secret" } as WireJob;
  assert.deepEqual(cleanJobs([extra]), [turn()]);
});

test("step counts above the relay's cap go out as the cap, normal counts unchanged", () => {
  assert.equal(MAX_STEPS, 100_000);
  assert.deepEqual(cleanJobs([turn({ steps: 250_000 })]), [turn({ steps: 100_000 })]);
  assert.equal(contentState([turn({ steps: 250_000 })]).jobs[0]!.steps, 100_000);
  assert.equal(contentState([turn({ steps: 42 })]).jobs[0]!.steps, 42);
});

test("validReport accepts safe epoch-millisecond requestedAtMs only", () => {
  const report = { activityId: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", pushToken: "ab".repeat(32), jobs: [turn()], turns };
  for (const requestedAtMs of [100_000_000_000, 1_800_000_000_500, Number.MAX_SAFE_INTEGER]) {
    assert.equal(validReport({ ...report, requestedAtMs }), true);
  }
  for (const requestedAtMs of [1.5e12 + 0.5, 1_800_000_000, -1, "1800000000500", 2 ** 53, null, 99_999_999_999]) {
    assert.equal(validReport({ ...report, requestedAtMs }), false, String(requestedAtMs));
  }
});

test("validReport requires paired Mode H fields and strict UUIDs; legacy stays valid", () => {
  const old = { jobs: [], turns: {} };
  const activityId = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
  const requestedAtMs = 1_800_000_000_000;
  assert.equal(validReport(old), true);
  assert.equal(validReport({ ...old, activityId }), false);
  assert.equal(validReport({ ...old, requestedAtMs }), false);
  assert.equal(validReport({ ...old, activityId, requestedAtMs }), true);
  for (const bad of ["bad", " " + activityId, activityId + " ", activityId + "\n", activityId.replaceAll("-", ""), 123, null]) {
    assert.equal(validReport({ ...old, activityId: bad, requestedAtMs }), false);
  }
});
