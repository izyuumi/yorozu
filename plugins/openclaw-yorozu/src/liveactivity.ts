// Counts-only Live Activity pushes (capability `liveActivityPush`): the pure part, with no runtime imports so
// `node --test` runs it as is. The app reports its activity's jobs over the encrypted session; the plugin changes
// only the turn jobs it can map to a conversation and passes every other job (recording, transcribing) unchanged.

export type JobKind = "turn" | "recording" | "transcribing" | "needsYou";
export type JobState = "running" | "done" | "failed";
/** One row as the app reports it; times are epoch milliseconds like the rest of the wire. */
export type WireJob = { token: string; kind: JobKind; state: JobState; steps?: number; startedAt: number; finishedAt?: number };
/** `live_activity`, client → plugin. No `pushToken`: the activity ended. `turns`: job token → convId of its running turns. */
export type ActivityReport = { pushToken?: string; jobs: WireJob[]; turns: Record<string, string> };

/** `YorozuActivityState` as Swift's default `JSONDecoder` reads it: dates are seconds since 2001-01-01. */
export type ContentJob = { token: string; kind: JobKind; state: JobState; steps?: number; startedAt: number; finishedAt?: number };
export type ContentState = { jobs: ContentJob[] };

export type TurnChange = { kind: "step"; steps: number } | { kind: "done" } | { kind: "failed" } | { kind: "gone" };

export type Plan = {
  event: "update" | "end";
  priority: 5 | 10;
  state: ContentState;
  staleDate?: number;
  dismissalDate?: number;
};

// The same numbers as `YorozuJobs` in the app.
export const LIMIT = 8;
export const LINGER_MS = 120_000;
export const STALE_MS = 15 * 60_000;
/** Step counts go at most this often per activity, at priority 5. */
export const STEP_INTERVAL_MS = 15_000;
/** The relay refuses a job above this many steps and drops the host; must match `MAX_STEPS` in apps/relay/src/protocol.ts. */
export const MAX_STEPS = 100_000;

const REFERENCE_MS = 978_307_200_000;
const KINDS: readonly string[] = ["turn", "recording", "transcribing", "needsYou"];
const STATES: readonly string[] = ["running", "done", "failed"];
const JOB_TOKEN = /^[A-Za-z0-9_-]{16}$/;
const CONV_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PUSH_TOKEN = /^(?:[0-9a-f]{2}){1,512}$/i;

type Fields = Record<string, unknown>;
const object = (v: unknown): v is Fields => typeof v === "object" && v !== null && !Array.isArray(v);
const nat = (v: unknown): v is number => Number.isSafeInteger(v) && (v as number) >= 0;

const validJob = (v: unknown): boolean =>
  object(v) &&
  typeof v.token === "string" &&
  JOB_TOKEN.test(v.token) &&
  typeof v.kind === "string" &&
  typeof v.state === "string" &&
  (v.steps === undefined || nat(v.steps)) &&
  nat(v.startedAt) &&
  (v.finishedAt === undefined || nat(v.finishedAt));

export const validReport = (d: Fields): boolean =>
  (d.pushToken === undefined || (typeof d.pushToken === "string" && PUSH_TOKEN.test(d.pushToken))) &&
  Array.isArray(d.jobs) &&
  d.jobs.length <= LIMIT &&
  d.jobs.every(validJob) &&
  object(d.turns) &&
  Object.keys(d.turns).length <= LIMIT &&
  Object.entries(d.turns).every(([token, convId]) => JOB_TOKEN.test(token) && typeof convId === "string" && CONV_ID.test(convId));

/** A report's jobs with only the known fields, so nothing else can reach the relay; a job of an unknown kind or state is dropped. */
export const cleanJobs = (jobs: readonly WireJob[]): WireJob[] =>
  jobs.filter((job) => KINDS.includes(job.kind) && STATES.includes(job.state)).map(({ token, kind, state, steps, startedAt, finishedAt }) => ({
    token,
    kind,
    state,
    ...(steps !== undefined && { steps: Math.min(steps, MAX_STEPS) }),
    startedAt,
    ...(finishedAt !== undefined && { finishedAt }),
  }));

const rank = (job: WireJob): number => {
  if (job.state !== "running") return 3;
  return job.kind === "needsYou" ? 0 : job.kind === "recording" ? 1 : 2;
};
const recency = (job: WireJob): number => job.finishedAt ?? job.startedAt;

/** Needs you, recording, running, then finished; newest first within each (`YorozuJobs.sorted`). */
export const sorted = (jobs: readonly WireJob[]): WireJob[] =>
  [...jobs].sort((a, b) => rank(a) - rank(b) || recency(b) - recency(a) || (a.token < b.token ? -1 : a.token > b.token ? 1 : 0));

/** Finished rows leave once they lingered; at most `LIMIT` stay (`YorozuJobs.apply`). */
export const tidy = (jobs: readonly WireJob[], now: number): WireJob[] =>
  sorted(jobs.filter((job) => job.finishedAt === undefined || now < job.finishedAt + LINGER_MS)).slice(0, LIMIT);

/** A turn of `convId` moved on: its running turn rows change, every other row stays as the app reported it. */
export function applyTurn(jobs: readonly WireJob[], turns: Readonly<Record<string, string>>, convId: string, change: TurnChange, now: number): WireJob[] {
  const mine = (job: WireJob) => job.kind === "turn" && job.state === "running" && turns[job.token] === convId;
  const next = jobs.flatMap((job): WireJob[] => {
    if (!mine(job)) return [job];
    switch (change.kind) {
      case "step":
        return [{ ...job, steps: Math.max(job.steps ?? 0, change.steps) }];
      case "done":
      case "failed":
        return [{ ...job, state: change.kind, finishedAt: now }];
      case "gone":
        return [];
    }
  });
  return tidy(next, now);
}

const seconds = (ms: number): number => (ms - REFERENCE_MS) / 1000;
const epochSeconds = (ms: number): number => Math.ceil(ms / 1000);

export const contentState = (jobs: readonly WireJob[]): ContentState => ({
  jobs: jobs.map(({ token, kind, state, steps, startedAt, finishedAt }) => ({
    token,
    kind,
    state,
    ...(steps !== undefined && { steps: Math.min(steps, MAX_STEPS) }),
    startedAt: seconds(startedAt),
    ...(finishedAt !== undefined && { finishedAt: seconds(finishedAt) }),
  })),
});

/** A row finished, left, or now needs you: Apple's immediate priority. Step counts alone wait (priority 5). */
export function urgent(before: readonly WireJob[], after: readonly WireJob[]): boolean {
  const was = new Map(before.map((job) => [job.token, job]));
  const left = before.some((job) => !after.some((other) => other.token === job.token));
  return (
    left ||
    after.some((job) => {
      const old = was.get(job.token);
      if (job.state !== "running") return old?.state === "running";
      return job.kind === "needsYou" && !old;
    })
  );
}

/** What to send for a change from `before` (last sent) to `after`, or null when nothing shows differently. With nothing
 * running the activity ends, dismissed once the last row lingered, since the suspended app runs no timer
 * (`YorozuActivityAttributes.show` with `endWhenIdle`). */
export function plan(before: readonly WireJob[], after: readonly WireJob[], now: number): Plan | null {
  if (JSON.stringify(before) === JSON.stringify(after)) return null;
  const state = contentState(after);
  if (!after.some((job) => job.state === "running")) {
    const last = Math.max(now, ...after.map((job) => (job.finishedAt ?? now) + LINGER_MS));
    const dismissalDate = epochSeconds(after.length ? last : now);
    return { event: "end", priority: 10, state, staleDate: dismissalDate, dismissalDate };
  }
  return { event: "update", priority: urgent(before, after) ? 10 : 5, state, staleDate: epochSeconds(now + STALE_MS) };
}

/** How long to hold a push: urgent ones go now, step counts once `STEP_INTERVAL_MS` passed since the last push. */
export const holdFor = (priority: 5 | 10, lastPushAt: number | undefined, now: number): number =>
  priority === 10 || lastPushAt === undefined ? 0 : Math.max(0, lastPushAt + STEP_INTERVAL_MS - now);
