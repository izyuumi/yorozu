/**
 * The auth state behind the Mac app's three provider cards, as one JSON line.
 * Run as `node dist/serve.js probe`. Never prints secrets: only whether each card is
 * usable, and why not when it is not. See docs/spec-v1.html section 2.
 */

import { env } from "node:process";
import { CHAIN_ENV } from "./chain.js";
import { claudeCli } from "./claude.js";
import { codexCli } from "./codex.js";
import { openaiCompat } from "./provider.js";

export interface ProbeReport {
  claude: { ok: boolean; reason?: string };
  codex: { ok: boolean; reason?: string };
  openai: { ok: boolean; reason?: string };
  /** The configured chain, echoed back so settings can show what is in force. */
  chain: string;
}

export async function probe(): Promise<ProbeReport> {
  const [claude, codex, openai] = await Promise.all([
    claudeCli().auth(),
    codexCli().auth(),
    openaiCompat({
      baseUrl: env.YOROZU_BASE_URL ?? "https://api.openai.com/v1",
      apiKey: env.YOROZU_API_KEY,
      model: env.YOROZU_MODEL ?? "gpt-4o-mini",
    }).auth(),
  ]);
  return { claude, codex, openai, chain: env[CHAIN_ENV] ?? "" };
}
