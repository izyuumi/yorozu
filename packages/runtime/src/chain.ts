/**
 * Primary model plus fallback chain. The first provider to produce an event wins;
 * anything that fails before that — auth, HTTP 401/403/429, transport — advances to
 * the next one. See docs/spec-v1.html section 2.
 *
 * What is in the chain comes from `providers.json` (see providers.ts), in the order the user
 * put the entries in. `YOROZU_MODEL_CHAIN` still overrides it, and a runtime with neither
 * probes the providers it can find rather than guessing at one that has no key.
 */

import { env } from "node:process";
import { claudeCli } from "./claude.js";
import { codexCli } from "./codex.js";
import {
  DEFAULT_OPENAI_BASE_URL,
  loadProviders,
  providerFromEntry,
  specsOf,
  type ProviderEntry,
} from "./providers.js";
import { openaiCompat, type Provider } from "./provider.js";

export { CHAIN_ENV } from "./providers.js";
import { CHAIN_ENV } from "./providers.js";

/** What the Mac app shows, and what a turn fails with, when nothing is signed in. */
export const NO_PROVIDER = "No provider signed in";

export function composeProviders(
  primary: Provider,
  fallbacks: Provider[] = [],
): Provider {
  const all = [primary, ...fallbacks];
  // Search is a capability, not a turn: the first provider that has one answers, and the
  // chain has none at all when nobody does, which is what makes `web_search` fall back.
  const searcher = all.find((provider) => provider.search);

  return {
    ...(searcher ? { search: (query: string) => searcher.search!(query) } : {}),

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

    async *stream(messages, tools, options) {
      for (const [index, provider] of all.entries()) {
        let started = false;
        try {
          for await (const event of provider.stream(messages, tools, options)) {
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

/**
 * One `<provider>/<model>` entry of the chain. The provider half is an id from
 * `providers.json`; the three built-in kind names are still accepted, which is what keeps a
 * hand-written `YOROZU_MODEL_CHAIN` and every `model:` frontmatter from before this file
 * working. The model may itself contain slashes.
 */
export function providerFromSpec(spec: string, entries = loadProviders()): Provider {
  const slash = spec.indexOf("/");
  const name = (slash < 0 ? spec : spec.slice(0, slash)).trim();
  const model = slash < 0 ? "" : spec.slice(slash + 1).trim();

  const entry = entries.find((candidate) => candidate.id === name);
  if (entry) return providerFromEntry(entry, model);

  switch (name) {
    case "claude-cli":
      return claudeCli({ model });
    case "codex-cli":
      return codexCli({ model });
    case "openai":
      return openaiCompat({
        baseUrl: env.YOROZU_BASE_URL ?? DEFAULT_OPENAI_BASE_URL,
        apiKey: env.YOROZU_API_KEY,
        model: model || (env.YOROZU_MODEL ?? "gpt-4o-mini"),
      });
    default:
      throw new Error(`${CHAIN_ENV}: unknown provider "${name}" in "${spec}"`);
  }
}

/** The chain those specs describe. Throws when there is nothing in them. */
export function chainFromSpecs(specs: string[], entries = loadProviders()): Provider {
  const [primary, ...fallbacks] = specs
    .map((spec) => spec.trim())
    .filter(Boolean)
    .map((spec) => providerFromSpec(spec, entries));
  if (!primary) throw new Error(`${CHAIN_ENV} is empty`);
  return composeProviders(primary, fallbacks);
}

/**
 * One thread's own model in front of the chain everything else runs on: the spec is tried
 * first, and a provider that fails before it has said anything falls through to the default,
 * exactly as one entry of the chain falls through to the next. A spec naming a provider that
 * no longer exists throws, as any other unknown spec does; it is the caller's business what to
 * do about a thread set to a model the user has since deleted.
 */
export const chainWithPrimary = (spec: string, fallback: Provider, dir?: string): Provider =>
  composeProviders(providerFromSpec(spec, loadProviders(dir)), [fallback]);

/** The usable half of a probe report, in the order the report lists it. */
export function autoSpecs(report: {
  providers: ProviderEntry[];
  status: Record<string, { ok: boolean }>;
}): string[] {
  return specsOf(
    report.providers.filter((entry) => entry.enabled && report.status[entry.id]?.ok === true),
  );
}

/**
 * The chain for a runtime that has been told nothing: probe every provider we could use and
 * keep the ones that answer, preferring the subscription CLIs over a paid key. Resolved once,
 * on first use — probing runs two CLIs and an HTTP call, which is not something to do at
 * import time — and `NO_PROVIDER` is what both `auth` and a turn fail with when none is
 * usable, so the Mac app has something true to show instead of a 401 per turn.
 */
export function autoChain(dir?: string): Provider {
  let resolving: Promise<Provider> | undefined;

  const resolve = async (): Promise<Provider> => {
    // Imported on use: probe.ts builds on this module, and probing is what seeds
    // `providers.json` on a runtime that has none.
    const { probe } = await import("./probe.js");
    const report = await probe(dir);
    const specs = autoSpecs(report);
    if (!specs.length) throw new Error(NO_PROVIDER);
    return chainFromSpecs(specs, report.providers);
  };

  const chain = (): Promise<Provider> => (resolving ??= resolve());

  return {
    async auth() {
      try {
        return await (await chain()).auth();
      } catch (e) {
        return { ok: false, reason: e instanceof Error ? e.message : String(e) };
      }
    },
    async *stream(messages, tools, options) {
      yield* (await chain()).stream(messages, tools, options);
    },
    /** A chain without native search throws here, which is `web_search`'s cue to drive a browser. */
    async search(query) {
      const resolved = await chain();
      if (!resolved.search) throw new Error("the active chain has no native search");
      return resolved.search(query);
    },
  };
}

/**
 * The chain in force: `YOROZU_MODEL_CHAIN` when it is set, else the entries in
 * `providers.json`, else whatever the probes can find.
 */
export function chainFromEnv(spec = env[CHAIN_ENV], dir?: string): Provider {
  const entries: ProviderEntry[] = loadProviders(dir);
  // Set-but-blank is how an unconfigured environment variable usually arrives: it means
  // "nothing configured here", not an empty chain.
  if (spec?.trim()) return chainFromSpecs(spec.split(","), entries);
  const specs = specsOf(entries);
  return specs.length ? chainFromSpecs(specs, entries) : autoChain(dir);
}
