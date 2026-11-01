import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import {
  applyTurn,
  cleanJobs,
  contentState,
  holdFor,
  LINGER_MS,
  plan,
  STEP_INTERVAL_MS,
  tidy,
  validReport,
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
  assert.equal(validReport({ ...report, jobs: [{ ...turn(), kind: "tool" }] }), false);
  assert.equal(validReport({ ...report, jobs: [{ ...turn(), token: "short" }] }), false);
  assert.equal(validReport({ ...report, jobs: Array(9).fill(turn()) }), false);
  const extra = { ...turn(), title: "secret" } as WireJob;
  assert.deepEqual(cleanJobs([extra]), [turn()]);
});
