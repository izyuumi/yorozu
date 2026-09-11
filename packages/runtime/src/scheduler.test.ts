import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { env } from "node:process";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import {
  addJob,
  CONSOLIDATION_JOB,
  dueJobs,
  listJobs,
  listScheduleTool,
  removeJob,
  scheduleTool,
  startScheduler,
  unscheduleTool,
  type Job,
} from "./scheduler.js";

let dir: string;
let previousStateDir: string | undefined;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-schedule-"));
  previousStateDir = env.YOROZU_STATE_DIR;
  env.YOROZU_STATE_DIR = dir;
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
  if (previousStateDir === undefined) delete env.YOROZU_STATE_DIR;
  else env.YOROZU_STATE_DIR = previousStateDir;
  rmSync(dir, { recursive: true, force: true });
});

const stored = (): Job[] => JSON.parse(readFileSync(join(dir, "schedule.json"), "utf8")) as Job[];

test("a fresh schedule holds the nightly consolidation job", () => {
  expect(listJobs(dir)).toEqual([CONSOLIDATION_JOB]);
  expect(stored()).toEqual([CONSOLIDATION_JOB]);
  expect(CONSOLIDATION_JOB).toMatchObject({ cron: "0 3 * * *", threadId: "system" });
  expect(CONSOLIDATION_JOB.instruction).toMatch(/read_transcripts/);
  expect(CONSOLIDATION_JOB.instruction).toMatch(/remember/);

  // Unscheduling it sticks: the seed only fills an absent file.
  expect(removeJob(CONSOLIDATION_JOB.id, dir)).toBe(true);
  expect(listJobs(dir)).toEqual([]);
});

test("the runner fires a due one-shot once, then forgets it", () => {
  vi.setSystemTime(new Date("2026-09-12T10:00:00"));
  const job = addJob(
    { instruction: "water the plants", at: "2026-09-12T10:00:20", threadId: "home" },
    dir,
  );

  const fired: Job[] = [];
  const scheduler = startScheduler((j) => fired.push(j), { dir });

  vi.advanceTimersByTime(30_000);
  expect(fired.map((j) => j.instruction)).toEqual(["water the plants"]);
  expect(fired[0]!.lastRun).toBe(new Date("2026-09-12T10:00:30").toISOString());

  // It is gone from disk, so no later tick can repeat it.
  vi.advanceTimersByTime(5 * 60_000);
  expect(fired).toHaveLength(1);
  expect(listJobs(dir).map((j) => j.id)).not.toContain(job.id);
  scheduler.stop();
});

test("a cron job fires on its minute, once, and again the next day", () => {
  removeJob(CONSOLIDATION_JOB.id, dir); // it shares this minute
  vi.setSystemTime(new Date("2026-09-12T02:59:40"));
  addJob({ instruction: "morning brief", cron: "0 3 * * *", threadId: "home" }, dir);

  const fired: Job[] = [];
  const scheduler = startScheduler((j) => fired.push(j), { dir });

  vi.advanceTimersByTime(30_000); // 03:00:10 — due
  vi.advanceTimersByTime(30_000); // 03:00:40 — same minute, already run
  vi.advanceTimersByTime(30_000); // 03:01:10 — no longer matching
  expect(fired.map((j) => j.threadId)).toEqual(["home"]);
  scheduler.stop();

  // The job survives its firing, with provenance of when it last ran.
  expect(stored()).toHaveLength(1);
  expect(dueJobs(new Date("2026-09-13T03:00:00"), dir).map((j) => j.instruction)).toEqual([
    "morning brief",
  ]);
});

test("the runner stops when told to", () => {
  vi.setSystemTime(new Date("2026-09-12T02:59:40"));
  const fired: Job[] = [];
  startScheduler((j) => fired.push(j), { dir }).stop();
  vi.advanceTimersByTime(10 * 60_000);
  expect(fired).toEqual([]);
});

test("a failing turn does not cancel the rest of the schedule", () => {
  vi.setSystemTime(new Date("2026-09-12T10:00:00"));
  addJob({ instruction: "boom", at: "2026-09-12T10:00:10" }, dir);
  addJob({ instruction: "fine", at: "2026-09-12T10:00:10" }, dir);

  const fired: string[] = [];
  const scheduler = startScheduler((job) => {
    fired.push(job.instruction);
    if (job.instruction === "boom") throw new Error("turn failed");
  }, { dir });

  vi.advanceTimersByTime(30_000);
  expect(fired).toEqual(["boom", "fine"]);
  scheduler.stop();
});

test("bad input is rejected and nothing partial is written", () => {
  expect(() => addJob({ instruction: "x" }, dir)).toThrow("exactly one");
  expect(() =>
    addJob({ instruction: "x", at: "2026-09-12T10:00:00Z", cron: "* * * * *" }, dir),
  ).toThrow("exactly one");
  expect(() => addJob({ instruction: "  ", cron: "* * * * *" }, dir)).toThrow("empty");
  expect(() => addJob({ instruction: "x", cron: "not a cron" }, dir)).toThrow("5 fields");
  expect(() => addJob({ instruction: "x", at: "whenever" }, dir)).toThrow("not a time");
  expect(listJobs(dir)).toEqual([CONSOLIDATION_JOB]);
});

test("a hand-broken schedule file falls back to the built-in one", () => {
  addJob({ instruction: "keep me", cron: "* * * * *" }, dir);
  rmSync(join(dir, "schedule.json"));
  expect(listJobs(dir)).toEqual([CONSOLIDATION_JOB]);
});

test("a hand-broken cron expression is skipped, not thrown", () => {
  addJob({ instruction: "fine", cron: "* * * * *" }, dir);
  const jobs = listJobs(dir);
  jobs[jobs.length - 1]!.cron = "99 * * * *";
  writeFileSync(join(dir, "schedule.json"), JSON.stringify(jobs));
  expect(dueJobs(new Date("2026-09-12T03:00:00"), dir).map((j) => j.id)).toEqual([
    CONSOLIDATION_JOB.id,
  ]);
});

test("the schedule tool files the job in the calling thread", () => {
  expect(scheduleTool.run({ instruction: "stand up", cron: "0 9 * * 1-5" }, {
    threadId: "work",
    agentId: "main",
  })).toMatch(/^scheduled: /);

  const job = listJobs(dir).at(-1)!;
  expect(job).toMatchObject({
    threadId: "work",
    createdBy: "main",
    cron: "0 9 * * 1-5",
    instruction: "stand up",
  });

  expect(listScheduleTool.run({})).toContain("[work] stand up");
  expect(unscheduleTool.run({ id: job.id })).toBe(`unscheduled: ${job.id}`);
  expect(unscheduleTool.run({ id: job.id })).toBe(`no such job: ${job.id}`);
  expect(listJobs(dir).map((j) => j.id)).toEqual([CONSOLIDATION_JOB.id]);
});

test("without a turn context the job lands in the home thread", () => {
  scheduleTool.run({ instruction: "later", at: "2026-09-12T10:00:00Z" });
  expect(listJobs(dir).at(-1)).toMatchObject({ threadId: "home", createdBy: "main" });
});
