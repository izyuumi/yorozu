/**
 * Jobs the agent scheduled for itself, as plain JSON in `<state dir>/schedule.json`.
 * A job fires as a new turn in the thread it was created from — there is no heartbeat
 * anywhere, the runner just wakes every 30s and asks which jobs are due.
 * See docs/spec-v1.html sections 4 and 5.
 */

import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { matchesCron, parseCron } from "./cron.js";
import type { Tool } from "./index.js";
import { stateDir } from "./memory.js";
import { currentThread } from "./threads.js";

export interface Job {
  id: string;
  /** Thread the resulting turn runs in. */
  threadId: string;
  /** What the agent is told to do when the job fires. */
  instruction: string;
  /** ISO 8601 instant, for a one-shot. Mutually exclusive with `cron`. */
  when?: string;
  /** 5-field cron expression, for a repeating job. */
  cron?: string;
  /** Agent ID that asked for the job. */
  createdBy: string;
  /** ISO 8601 instant of the last firing. */
  lastRun?: string;
}

/** Thread the runtime talks to itself in: no phone ever opens it. */
export const SYSTEM_THREAD = "system";

/** Seeded into a fresh schedule. Unschedule it and it stays gone. */
export const CONSOLIDATION_JOB: Job = {
  id: "nightly-consolidation",
  threadId: SYSTEM_THREAD,
  cron: "0 3 * * *",
  createdBy: "system",
  instruction:
    "Nightly memory consolidation. Call read_transcripts to read the last 24 hours of " +
    "conversation, then call remember once for each durable fact about the user it reveals " +
    "— preferences, decisions, corrections, approvals — that memory does not already hold. " +
    "Skip anything transient, and say nothing if there is nothing new.",
};

const scheduleFile = (dir: string): string => join(dir, "schedule.json");

export function saveJobs(jobs: Job[], dir = stateDir()): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(scheduleFile(dir), `${JSON.stringify(jobs, null, 2)}\n`);
}

/** The stored jobs. A missing or unreadable file is seeded with the nightly job. */
export function listJobs(dir = stateDir()): Job[] {
  try {
    const stored: unknown = JSON.parse(readFileSync(scheduleFile(dir), "utf8"));
    if (Array.isArray(stored)) return stored as Job[];
  } catch {
    // First run, or a file someone broke by hand: start from the built-in schedule.
  }
  saveJobs([CONSOLIDATION_JOB], dir);
  return [CONSOLIDATION_JOB];
}

export interface NewJob {
  instruction: string;
  /** ISO 8601 instant for a one-shot. Exactly one of `at` or `cron` is required. */
  at?: string;
  cron?: string;
  threadId?: string;
  createdBy?: string;
}

/** Model-supplied input: everything here is validated before it reaches disk. */
export function addJob(input: NewJob, dir = stateDir()): Job {
  const instruction = String(input.instruction ?? "").trim();
  if (!instruction) throw new Error("schedule: instruction is empty");
  if (!input.at === !input.cron) throw new Error("schedule: pass exactly one of at or cron");
  if (input.cron) parseCron(input.cron);

  let when: string | undefined;
  if (input.at) {
    const date = new Date(input.at);
    if (Number.isNaN(date.getTime())) throw new Error(`schedule: not a time: ${input.at}`);
    when = date.toISOString();
  }

  const job: Job = {
    id: randomUUID(),
    threadId: input.threadId || currentThread(dir),
    instruction,
    createdBy: input.createdBy || "main",
    ...(when ? { when } : { cron: input.cron }),
  };
  saveJobs([...listJobs(dir), job], dir);
  return job;
}

export function removeJob(id: string, dir = stateDir()): boolean {
  const jobs = listJobs(dir);
  const left = jobs.filter((job) => job.id !== id);
  if (left.length === jobs.length) return false;
  saveJobs(left, dir);
  return true;
}

const sameMinute = (a: number, b: number): boolean =>
  Math.floor(a / 60_000) === Math.floor(b / 60_000);

/** A stored expression can be hand-edited: a broken one must not stop the schedule. */
function isCronDue(job: Job, now: Date): boolean {
  try {
    return matchesCron(job.cron!, now);
  } catch {
    return false;
  }
}

/**
 * Jobs to fire at `now`, marking them run: one-shots are dropped, cron jobs keep
 * their `lastRun` so a second tick inside the same minute does not fire them twice.
 */
export function dueJobs(now = new Date(), dir = stateDir()): Job[] {
  const fired: Job[] = [];
  const keep: Job[] = [];
  for (const job of listJobs(dir)) {
    const run = { ...job, lastRun: now.toISOString() };
    if (job.when && !job.lastRun && new Date(job.when).getTime() <= now.getTime()) {
      fired.push(run);
    } else if (
      job.cron &&
      isCronDue(job, now) &&
      !(job.lastRun && sameMinute(new Date(job.lastRun).getTime(), now.getTime()))
    ) {
      fired.push(run);
      keep.push(run);
    } else {
      keep.push(job);
    }
  }
  if (fired.length) saveJobs(keep, dir);
  return fired;
}

export const SCHEDULER_INTERVAL_MS = 30_000;

export interface SchedulerHandle {
  stop(): void;
}

export interface SchedulerOptions {
  dir?: string;
  intervalMs?: number;
}

/** Wakes every 30s and hands each due job to `onFire`, which runs it as a turn. */
export function startScheduler(
  onFire: (job: Job) => void,
  options: SchedulerOptions = {},
): SchedulerHandle {
  const dir = options.dir ?? stateDir();
  const timer = setInterval(() => {
    for (const job of dueJobs(new Date(), dir)) {
      try {
        onFire(job);
      } catch {
        // One failing job must not cancel the rest of the schedule.
      }
    }
  }, options.intervalMs ?? SCHEDULER_INTERVAL_MS);
  timer.unref?.();
  return { stop: () => clearInterval(timer) };
}

const describe = (job: Job): string =>
  `${job.id} ${job.cron ? `cron ${job.cron}` : `at ${job.when}`} [${job.threadId}] ${job.instruction}`;

export const scheduleTool: Tool = {
  name: "schedule",
  description:
    "Schedule an instruction to run later as a new turn in this thread, once at a given " +
    "time or repeatedly on a cron expression.",
  parameters: {
    type: "object",
    properties: {
      instruction: { type: "string", description: "What to do when the job fires." },
      at: { type: "string", description: "ISO 8601 instant, for a one-shot." },
      cron: { type: "string", description: "5-field cron: minute hour day-of-month month day-of-week." },
    },
    required: ["instruction"],
  },
  run: ({ instruction, at, cron }, context) => {
    const job = addJob({
      instruction: String(instruction ?? ""),
      ...(at ? { at: String(at) } : {}),
      ...(cron ? { cron: String(cron) } : {}),
      ...(context ? { threadId: context.threadId, createdBy: context.agentId } : {}),
    });
    return `scheduled: ${describe(job)}`;
  },
};

export const unscheduleTool: Tool = {
  name: "unschedule",
  description: "Cancel a scheduled job by its ID.",
  parameters: {
    type: "object",
    properties: { id: { type: "string" } },
    required: ["id"],
  },
  run: ({ id }) => (removeJob(String(id ?? "")) ? `unscheduled: ${String(id)}` : `no such job: ${String(id)}`),
};

export const listScheduleTool: Tool = {
  name: "list_schedule",
  description: "List every scheduled job with its ID, timing and instruction.",
  parameters: { type: "object", properties: {}, required: [] },
  run: () => {
    const jobs = listJobs();
    return jobs.length ? jobs.map(describe).join("\n") : "nothing scheduled";
  },
};
