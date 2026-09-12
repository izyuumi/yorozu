/**
 * The model catalog: price, context and strengths per model, fetched from the rolling
 * GitHub release and cached for a day. Offline, yesterday's cache is used, and failing
 * that the copy bundled with the repo. `catalog.overlay.json` in the state directory is
 * merged over it by id — research mode writes there, and the catalog itself is never
 * rewritten. See docs/spec-v1.html section 2.
 */

import { mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { env } from "node:process";
import { fileURLToPath } from "node:url";
import { stateDir } from "./memory.js";

export interface CatalogEntry {
  /** Provider spec as `chainFromEnv` takes it, e.g. `claude-cli/claude-opus-5`. */
  id: string;
  provider: string;
  /** USD per million tokens, or null where nobody publishes one. */
  inputPer1M: number | null;
  outputPer1M: number | null;
  contextK: number | null;
  strengths: string[];
  /** ISO date the row was last checked. */
  updated: string;
  /** Free text for the rows that need one, e.g. custom endpoints. */
  note?: string;
}

export const CATALOG_URL_ENV = "YOROZU_CATALOG_URL";

/** The asset `.github/workflows/catalog.yml` keeps up to date. */
export const DEFAULT_CATALOG_URL =
  "https://dl.yumi.to/models.json";

export const CATALOG_TTL_MS = 24 * 60 * 60 * 1000;

/** The copy in the repo, reachable from `src/` and `dist/` alike. */
const BUNDLED = fileURLToPath(new URL("../../../catalog/models.json", import.meta.url));

export const catalogCacheFile = (dir = stateDir()): string => join(dir, "catalog.json");
export const catalogOverlayFile = (dir = stateDir()): string => join(dir, "catalog.overlay.json");

/** A missing or hand-broken file is not a failure: there is always another source. */
function readEntries(file: string): CatalogEntry[] | undefined {
  try {
    const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
    return Array.isArray(parsed) ? (parsed as CatalogEntry[]) : undefined;
  } catch {
    return undefined;
  }
}

/** Overlay rows win field by field; an id the base does not have is appended. */
export function mergeById(base: CatalogEntry[], overlay: CatalogEntry[]): CatalogEntry[] {
  const byId = new Map(base.map((entry) => [entry.id, entry]));
  for (const entry of overlay) byId.set(entry.id, { ...byId.get(entry.id), ...entry });
  return [...byId.values()];
}

export interface CatalogOptions {
  /** State directory holding the cache and the overlay. */
  dir?: string;
  url?: string;
  /** Injectable for tests. */
  fetch?: typeof fetch;
}

const isFresh = (file: string): boolean => {
  try {
    return Date.now() - statSync(file).mtimeMs < CATALOG_TTL_MS;
  } catch {
    return false;
  }
};

/** The catalog as the runtime sees it: cache or network, then the overlay on top. */
export async function loadCatalog(options: CatalogOptions = {}): Promise<CatalogEntry[]> {
  const dir = options.dir ?? stateDir();
  const cache = catalogCacheFile(dir);
  let entries = isFresh(cache) ? readEntries(cache) : undefined;

  if (!entries) {
    try {
      const url = options.url ?? env[CATALOG_URL_ENV] ?? DEFAULT_CATALOG_URL;
      const res = await (options.fetch ?? globalThis.fetch)(url);
      if (!res.ok) throw new Error(`catalog ${res.status}`);
      const body: unknown = await res.json();
      if (!Array.isArray(body)) throw new Error("catalog is not an array");
      entries = body as CatalogEntry[];
      mkdirSync(dir, { recursive: true });
      writeFileSync(cache, `${JSON.stringify(entries, null, 2)}\n`);
    } catch {
      // Offline, or a broken release asset: a stale cache beats nothing, and the copy
      // shipped with the runtime beats having no catalog at all.
      entries = readEntries(cache) ?? readEntries(BUNDLED) ?? [];
    }
  }

  return mergeById(entries, readEntries(catalogOverlayFile(dir)) ?? []);
}

/** Merges rows into the local overlay and returns it. The catalog is left alone. */
export function writeOverlay(entries: CatalogEntry[], dir = stateDir()): CatalogEntry[] {
  const file = catalogOverlayFile(dir);
  const merged = mergeById(readEntries(file) ?? [], entries);
  mkdirSync(dir, { recursive: true });
  writeFileSync(file, `${JSON.stringify(merged, null, 2)}\n`);
  return merged;
}
