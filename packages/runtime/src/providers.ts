/**
 * The configured providers, as a list the user owns rather than three cards the code knows
 * about: `<state dir>/providers.json`. Order is chain order — the first enabled entry's first
 * model is the default model — and each entry's models are what `<id>/<model>` specs resolve
 * against, in agent frontmatter and in the catalog alike. See docs/spec-v1.html section 2.
 *
 * Secrets never land here: an entry carries a `keyRef`, the Mac app keeps that key in the
 * Keychain, and the sidecar reads it from the environment under ``keyEnvVar(keyRef)``.
 */

import { YOROZU_EFFORTS, type ModelOption } from "@yorozu/shared";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { env } from "node:process";
import { claudeCli } from "./claude.js";
import { codexCli } from "./codex.js";
import { stateDir } from "./memory.js";
import { openaiCompat, type Provider } from "./provider.js";

export type ProviderKind = "claude-cli" | "codex-cli" | "openai-compat";

export interface ProviderEntry {
  /** Stable, user-visible name of this entry: the first half of every `<id>/<model>` spec. */
  id: string;
  kind: ProviderKind;
  label: string;
  /** `openai-compat` only; with or without a trailing `/v1`. */
  baseUrl?: string;
  /** Name of the Keychain item holding this entry's key. Never the key itself. */
  keyRef?: string;
  /** Models offered for this entry, best first. Empty means whatever the provider defaults to. */
  models: string[];
  enabled: boolean;
}

/** `claude/claude-sonnet-5,codex/gpt-5.6`: an override, ahead of `providers.json`. */
export const CHAIN_ENV = "YOROZU_MODEL_CHAIN";

export const DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1";

/**
 * Curated starting points for the two subscription CLIs, which publish no model list to
 * fetch. The user edits them in Settings; nothing here is authoritative.
 */
export const DEFAULT_MODELS: Record<ProviderKind, string[]> = {
  "claude-cli": ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"],
  "codex-cli": ["gpt-5.6-codex", "gpt-5.6"],
  "openai-compat": [],
};

export const providersFile = (dir = stateDir()): string => join(dir, "providers.json");

/** Where an entry's API key is read from. Derived, so no secret is ever stored in the file. */
export const keyEnvVar = (keyRef: string): string =>
  `YOROZU_KEY_${keyRef.toUpperCase().replace(/[^A-Z0-9]/g, "_")}`;

/** An entry's key, from its own variable, falling back to the single-key environment. */
export const keyFor = (entry: ProviderEntry): string | undefined =>
  (entry.keyRef ? env[keyEnvVar(entry.keyRef)] : undefined) || env.YOROZU_API_KEY || undefined;

const KINDS: ProviderKind[] = ["claude-cli", "codex-cli", "openai-compat"];

/** Hand-edited file, so every field is checked: one bad entry is dropped, not fatal. */
function parseEntry(raw: unknown): ProviderEntry | null {
  if (typeof raw !== "object" || raw === null) return null;
  const entry = raw as Record<string, unknown>;
  const id = typeof entry.id === "string" ? entry.id.trim() : "";
  const kind = entry.kind as ProviderKind;
  if (!id || id.includes("/") || !KINDS.includes(kind)) return null;
  return {
    id,
    kind,
    label: typeof entry.label === "string" && entry.label ? entry.label : id,
    ...(typeof entry.baseUrl === "string" && entry.baseUrl ? { baseUrl: entry.baseUrl } : {}),
    ...(typeof entry.keyRef === "string" && entry.keyRef ? { keyRef: entry.keyRef } : {}),
    models: Array.isArray(entry.models)
      ? entry.models.filter((model): model is string => typeof model === "string" && model !== "")
      : [],
    enabled: entry.enabled !== false,
  };
}

/** The configured providers, in chain order. Empty when the file is missing or unusable. */
export function loadProviders(dir = stateDir()): ProviderEntry[] {
  try {
    const parsed: unknown = JSON.parse(readFileSync(providersFile(dir), "utf8"));
    if (!Array.isArray(parsed)) return [];
    return parsed.map(parseEntry).filter((entry): entry is ProviderEntry => entry !== null);
  } catch {
    return [];
  }
}

export function saveProviders(entries: ProviderEntry[], dir = stateDir()): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(providersFile(dir), `${JSON.stringify(entries, null, 2)}\n`);
}

/** One entry plus one of its models, as a provider the chain can hold. */
export function providerFromEntry(entry: ProviderEntry, model = ""): Provider {
  switch (entry.kind) {
    case "claude-cli":
      return claudeCli({ model });
    case "codex-cli":
      return codexCli({ model });
    case "openai-compat":
      return openaiCompat({
        baseUrl: entry.baseUrl ?? env.YOROZU_BASE_URL ?? DEFAULT_OPENAI_BASE_URL,
        ...(keyFor(entry) ? { apiKey: keyFor(entry) } : {}),
        model: model || entry.models[0] || env.YOROZU_MODEL || "gpt-4o-mini",
      });
  }
}

/**
 * The chain these entries describe, as `<id>/<model>` specs: every enabled entry in order,
 * each of its models in order. An entry with no models contributes one spec with an empty
 * model, which means whatever that provider is already configured to use.
 */
export function specsOf(entries: ProviderEntry[]): string[] {
  return entries
    .filter((entry) => entry.enabled)
    .flatMap((entry) =>
      entry.models.length ? entry.models.map((model) => `${entry.id}/${model}`) : [`${entry.id}/`],
    );
}

/**
 * The same specs as ``specsOf``, carrying the names a picker draws: what the sidecar publishes
 * to the phones as `model_list`, so a thread can be put on one model by name. Nothing secret
 * is in it — an entry's id, its label and its models, and never its `keyRef` or `baseUrl`.
 */
export const modelOptions = (entries: ProviderEntry[]): ModelOption[] =>
  entries
    .filter((entry) => entry.enabled)
    .flatMap((entry) =>
      entry.models.length
        ? entry.models.map((model) => ({
            id: `${entry.id}/${model}`,
            label: model,
            providerLabel: entry.label,
            efforts: [...YOROZU_EFFORTS],
          }))
        : // An entry with no models offers whatever it is already configured to use, which has
          // no name of its own to show: the provider's own is the honest label for it.
          [{ id: `${entry.id}/`, label: entry.label, providerLabel: entry.label, efforts: [...YOROZU_EFFORTS] }],
    );

/**
 * First run, and the migration off the three hard-coded cards: whatever the probes say is
 * usable becomes an entry, in the order the chain used to prefer them. Only ever called with
 * no file on disk; the result is written so the user's edits are never overwritten later.
 */
export function seedProviders(
  probes: { claude: { ok: boolean }; codex: { ok: boolean }; openai: { ok: boolean } },
  dir = stateDir(),
): ProviderEntry[] {
  const entries: ProviderEntry[] = [];
  if (probes.claude.ok) {
    entries.push({
      id: "claude",
      kind: "claude-cli",
      label: "Claude",
      models: DEFAULT_MODELS["claude-cli"],
      enabled: true,
    });
  }
  if (probes.codex.ok) {
    entries.push({
      id: "codex",
      kind: "codex-cli",
      label: "Codex",
      models: DEFAULT_MODELS["codex-cli"],
      enabled: true,
    });
  }
  // The environment the earlier tickets configured: an endpoint plus a key is an entry, and
  // the key stays where it was — `keyFor` falls back to `YOROZU_API_KEY`.
  if (env.YOROZU_BASE_URL || env.YOROZU_API_KEY) {
    entries.push({
      id: "openai",
      kind: "openai-compat",
      label: "OpenAI-compatible",
      baseUrl: env.YOROZU_BASE_URL ?? DEFAULT_OPENAI_BASE_URL,
      models: env.YOROZU_MODEL ? [env.YOROZU_MODEL] : [],
      enabled: true,
    });
  }
  saveProviders(entries, dir);
  return entries;
}

/**
 * The models one `openai-compat` entry's endpoint publishes, for the Settings picker. Empty
 * for the CLI kinds, which publish none, and for an endpoint that cannot be reached.
 */
export async function listEntryModels(id: string, dir = stateDir()): Promise<string[]> {
  const entry = loadProviders(dir).find((candidate) => candidate.id === id);
  if (!entry || entry.kind !== "openai-compat") return [];
  try {
    return await openaiCompat({
      baseUrl: entry.baseUrl ?? DEFAULT_OPENAI_BASE_URL,
      ...(keyFor(entry) ? { apiKey: keyFor(entry) } : {}),
      model: "",
    }).listModels();
  } catch {
    return [];
  }
}
