import { tryResolveDefaultAgentId } from "openclaw/plugin-sdk/agent-scope-runtime";
import type { OpenClawConfig } from "openclaw/plugin-sdk/channel-core";
import { loadCronStore, resolveCronStorePath } from "openclaw/plugin-sdk/cron-store-runtime";
import { normalizeAgentId } from "openclaw/plugin-sdk/routing";
import { describeSchedule } from "./cron-text.js";
import { isId, type CronJob } from "./envelope.js";

export { describeSchedule };

type StoredJob = Awaited<ReturnType<typeof loadCronStore>>["jobs"][number];

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
