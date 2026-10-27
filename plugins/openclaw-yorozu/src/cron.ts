import { tryResolveDefaultAgentId } from "openclaw/plugin-sdk/agent-scope-runtime";
import type { OpenClawConfig } from "openclaw/plugin-sdk/channel-core";
import { loadCronStore, resolveCronStorePath } from "openclaw/plugin-sdk/cron-store-runtime";
import { normalizeAgentId } from "openclaw/plugin-sdk/routing";
import { isId, type CronJob } from "./envelope.js";

type StoredJob = Awaited<ReturnType<typeof loadCronStore>>["jobs"][number];
type Schedule = StoredJob["schedule"];

export async function listCronJobs(cfg: OpenClawConfig, agent: string): Promise<CronJob[]> {
  const store = await loadCronStore(resolveCronStorePath((cfg as { cron?: { store?: string } }).cron?.store));
  const system = (cfg as { agents?: { defaults?: { systemAgent?: { agentId?: string } } } }).agents?.defaults?.systemAgent?.agentId?.trim();
  const owner = system || tryResolveDefaultAgentId(cfg);
  const fallback = owner ? normalizeAgentId(owner) : undefined;
  const mine = normalizeAgentId(agent);
  return store.jobs
    .filter((job) => (job.agentId ? normalizeAgentId(job.agentId) : fallback) === mine)
    .map(toWire)
    .sort((a, b) => a.name.localeCompare(b.name) || a.id.localeCompare(b.id));
}

function toWire(job: StoredJob): CronJob {
  const state = job.state ?? {};
  const status = state.lastRunStatus ?? state.lastStatus;
  const delivery = job.delivery;
  const threadId = String(delivery?.threadId ?? "").toLowerCase();
  return {
    id: job.id,
    name: job.displayName?.trim() || job.name,
    enabled: job.enabled,
    schedule: job.schedule as unknown as Record<string, unknown>,
    scheduleText: describeSchedule(job.schedule),
    ...(state.nextRunAtMs !== undefined && { nextRunAt: state.nextRunAtMs }),
    ...(state.lastRunAtMs !== undefined && { lastRunAt: state.lastRunAtMs }),
    ...(status && { lastStatus: status }),
    ...(state.lastError && { lastError: state.lastError.slice(0, 2000) }),
    ...(delivery?.channel === "yorozu" && isId(threadId) && { delivery: { channel: "yorozu", threadId } }),
  };
}

const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

export function describeSchedule(schedule: Schedule): string {
  switch (schedule.kind) {
    case "at":
      return "Once";
    case "every":
      return `Every ${duration(schedule.everyMs)}`;
    case "cron": {
      const tz = schedule.tz ? ` (${schedule.tz})` : "";
      return `${describeCron(schedule.expr.trim())}${tz}`;
    }
    case "on-exit":
      return "When a command exits";
    case "stream":
      return "On command output";
    default:
      return "Custom";
  }
}

function duration(ms: number): string {
  const units: [number, string][] = [[86_400_000, "day"], [3_600_000, "hour"], [60_000, "minute"], [1_000, "second"]];
  for (const [size, unit] of units) {
    if (ms % size === 0) {
      const n = ms / size;
      return n === 1 ? unit : `${n} ${unit}s`;
    }
  }
  return `${ms} ms`;
}

function describeCron(expr: string): string {
  const fields = expr.split(/\s+/);
  if (fields.length !== 5) return `Cron ${expr}`;
  const [min, hour, dom, month, dow] = fields as [string, string, string, string, string];
  const num = (s: string) => /^\d{1,2}$/.test(s);
  const at = num(min) && num(hour) ? `at ${hour.padStart(2, "0")}:${min.padStart(2, "0")}` : null;
  const step = /^\*\/(\d+)$/.exec(min);
  if (step && hour === "*" && dom === "*" && month === "*" && dow === "*") return `Every ${step[1]} minutes`;
  if (num(min) && hour === "*" && dom === "*" && month === "*" && dow === "*") return `Hourly at :${min.padStart(2, "0")}`;
  if (at && month === "*") {
    if (dom === "*" && dow === "*") return `Daily ${at}`;
    if (dom === "*" && (dow === "1-5" || dow === "MON-FRI")) return `Weekdays ${at}`;
    if (dom === "*" && /^[0-7]$/.test(dow)) return `${DAYS[Number(dow) % 7]}s ${at}`;
    if (num(dom) && dow === "*") return `Monthly on day ${Number(dom)} ${at}`;
  }
  return `Cron ${expr}`;
}
