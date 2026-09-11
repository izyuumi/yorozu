/**
 * Primary model plus fallback chain. The first provider to produce an event wins;
 * anything that fails before that — auth, HTTP 401/403/429, transport — advances to
 * the next one. See docs/spec-v1.html section 2.
 */

import { env } from "node:process";
import { claudeCli } from "./claude.js";
import { codexCli } from "./codex.js";
import { openaiCompat, type Provider } from "./provider.js";

/** `claude-cli/claude-sonnet-5,codex-cli/gpt-5.6,openai/gpt-4o-mini`. */
export const CHAIN_ENV = "YOROZU_MODEL_CHAIN";

export function composeProviders(
  primary: Provider,
  fallbacks: Provider[] = [],
): Provider {
  const all = [primary, ...fallbacks];

  return {
    /** Any one green unlocks the app, so the first usable provider decides. */
    async auth() {
      let reason: string | undefined;
      for (const provider of all) {
        const result = await provider.auth();
        if (result.ok) return result;
        reason ??= result.reason;
      }
      return { ok: false, reason };
    },

    async *stream(messages, tools) {
      for (const [index, provider] of all.entries()) {
        let started = false;
        try {
          for await (const event of provider.stream(messages, tools)) {
            started = true;
            yield event;
          }
          return;
        } catch (e) {
          // Once an event is out the turn is half-spoken: replaying it on the next
          // provider would duplicate text, so only pre-token failures fall through.
          if (started || index === all.length - 1) throw e;
        }
      }
    },
  };
}

/** One `kind/model` entry of the chain. The model may itself contain slashes. */
export function providerFromSpec(spec: string): Provider {
  const slash = spec.indexOf("/");
  const kind = (slash < 0 ? spec : spec.slice(0, slash)).trim();
  const model = slash < 0 ? "" : spec.slice(slash + 1).trim();
  switch (kind) {
    case "claude-cli":
      return claudeCli({ model });
    case "codex-cli":
      return codexCli({ model });
    case "openai":
      return openaiCompat({
        baseUrl: env.YOROZU_BASE_URL ?? "https://api.openai.com/v1",
        apiKey: env.YOROZU_API_KEY,
        model: model || (env.YOROZU_MODEL ?? "gpt-4o-mini"),
      });
    default:
      throw new Error(`${CHAIN_ENV}: unknown provider "${kind}" in "${spec}"`);
  }
}

/**
 * The configured chain, falling back to the OpenAI-compatible adapter the earlier
 * tickets configured from the environment.
 */
export function chainFromEnv(spec = env[CHAIN_ENV]): Provider {
  // Set-but-blank is how an unconfigured environment variable usually arrives; it means
  // the default, not a failure to start.
  const [primary, ...fallbacks] = (spec?.trim() ? spec : "openai")
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map(providerFromSpec);
  if (!primary) throw new Error(`${CHAIN_ENV} is empty`);
  return composeProviders(primary, fallbacks);
}
