/**
 * The auth state behind the Mac app's Providers list, as one JSON line. Run as
 * `node dist/serve.js probe`. Never prints secrets: only whether each provider is usable, and
 * why not when it is not. See docs/spec-v1.html section 2.
 *
 * It is also the migration: a runtime with no `providers.json` yet gets one seeded from these
 * probes, which is what the auto-chain in chain.ts builds on.
 */

import { env } from "node:process";
import { claudeCli } from "./claude.js";
import { codexCli } from "./codex.js";
import { stateDir } from "./memory.js";
import {
  CHAIN_ENV,
  DEFAULT_OPENAI_BASE_URL,
  keyFor,
  loadProviders,
  seedProviders,
  type ProviderEntry,
} from "./providers.js";
import { openaiCompat } from "./provider.js";

export interface ProbeCard {
  ok: boolean;
  reason?: string;
}

export interface ProbeReport {
  /** The three built-in providers, probed as they were before `providers.json` existed. */
  claude: ProbeCard;
  codex: ProbeCard;
  openai: ProbeCard;
  /** The configured chain override, echoed back so settings can show what is in force. */
  chain: string;
  /** The configured providers, seeded from the probes above when there were none. */
  providers: ProviderEntry[];
  /** Per entry id, whether the runtime could actually use it. */
  status: Record<string, ProbeCard>;
}

export async function probe(dir = stateDir()): Promise<ProbeReport> {
  const [claude, codex, openai] = await Promise.all([
    claudeCli().auth(),
    codexCli().auth(),
    openaiCompat({
      baseUrl: env.YOROZU_BASE_URL ?? DEFAULT_OPENAI_BASE_URL,
      apiKey: env.YOROZU_API_KEY,
      model: env.YOROZU_MODEL ?? "gpt-4o-mini",
    }).auth(),
  ]);

  const stored = loadProviders(dir);
  const providers = stored.length ? stored : seedProviders({ claude, codex, openai }, dir);

  // The CLI kinds are already probed above — their login is per binary, not per entry — so
  // only the HTTP endpoints cost a call of their own here.
  const status: Record<string, ProbeCard> = {};
  await Promise.all(
    providers.map(async (entry) => {
      status[entry.id] =
        entry.kind === "claude-cli"
          ? claude
          : entry.kind === "codex-cli"
            ? codex
            : await openaiCompat({
                baseUrl: entry.baseUrl ?? DEFAULT_OPENAI_BASE_URL,
                ...(keyFor(entry) ? { apiKey: keyFor(entry) } : {}),
                model: entry.models[0] ?? "gpt-4o-mini",
              }).auth();
    }),
  );

  return { claude, codex, openai, chain: env[CHAIN_ENV] ?? "", providers, status };
}
