/**
 * Whether each agent would answer a thread right now, for the Mac's setup and settings. The
 * runtime asks because a thread runs with the runtime's `PATH` and the runtime's logins; a
 * check from the app would see a different `PATH` and could disagree with what actually runs.
 */

import type { AgentReadiness, AgentStatusData } from "@yorozu/shared";
import { claudeCli } from "./claude.js";
import { codexCli } from "./codex.js";
import type { Provider } from "./provider.js";

/** Long enough for a local Gateway to say hello, short enough that setup never looks stuck. */
export const GATEWAY_TIMEOUT_MS = 3000;

export interface AgentStatusDeps {
  claude?: Pick<Provider, "auth">;
  codex?: Pick<Provider, "auth">;
  /** Resolves once the Gateway accepts a connection. Absent on a runtime without OpenClaw. */
  openclaw?: () => Promise<unknown>;
  timeoutMs?: number;
}

/** The CLI adapters' own failure words, turned into what the user does about them. */
function fromAuth({ ok, reason }: { ok: boolean; reason?: string }): AgentReadiness {
  if (ok) return { ok };
  if (reason?.endsWith("is not on PATH")) return { ok, reason: "not-found" };
  if (reason?.endsWith("not logged in")) return { ok, reason: "not-logged-in" };
  return { ok, ...(reason ? { detail: reason } : {}) };
}

async function gateway(connect: () => Promise<unknown>, timeoutMs: number): Promise<AgentReadiness> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error("OpenClaw Gateway did not answer")), timeoutMs);
  });
  try {
    await Promise.race([connect(), timeout]);
    return { ok: true };
  } catch (e) {
    // Connecting runs `openclaw` for a first-time setup code; a missing binary is not installed.
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return { ok: false, reason: "not-found" };
    return { ok: false, reason: "unreachable" };
  } finally {
    clearTimeout(timer);
  }
}

export async function agentStatus(deps: AgentStatusDeps = {}): Promise<AgentStatusData> {
  const { claude = claudeCli(), codex = codexCli(), openclaw, timeoutMs = GATEWAY_TIMEOUT_MS } = deps;
  const [claudeStatus, codexStatus, openclawStatus] = await Promise.all([
    claude.auth().then(fromAuth),
    codex.auth().then(fromAuth),
    openclaw ? gateway(openclaw, timeoutMs) : undefined,
  ]);
  return { claude: claudeStatus, codex: codexStatus, ...(openclawStatus ? { openclaw: openclawStatus } : {}) };
}
