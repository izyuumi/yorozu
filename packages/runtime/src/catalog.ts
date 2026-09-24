/**
 * The legacy auto-assign catalog: price, context and strengths per model, fetched from
 * the repository and cached for a day. Shipped app model pickers query their backends
 * directly; this catalog is only used by the direct-provider runtime. Offline, yesterday's
 * cache is used, then the bundled copy. `catalog.overlay.json` in the state directory is
 * merged over it by id. See docs/legacy-runtime.md.
 */

import { Buffer } from "node:buffer";
import { mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { env } from "node:process";
import { fileURLToPath } from "node:url";
import { z } from "zod";
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

const catalogEntrySchema = z.object({
  id: z.string().regex(/^[\w.\-\/:<> ]{1,120}$/),
  provider: z.string(),
  inputPer1M: z.number().nullable(),
  outputPer1M: z.number().nullable(),
  contextK: z.number().nullable(),
  strengths: z.array(z.string()),
  updated: z.string(),
  note: z.string().optional(),
});

export const CATALOG_URL_ENV = "YOROZU_CATALOG_URL";

/** Legacy metadata follows the repository independently of application releases. */
export const DEFAULT_CATALOG_URL =
  "https://raw.githubusercontent.com/izyuumi/yorozu/main/catalog/models.json";

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

/** More than any plausible catalog; a hostile or broken response is cut off, not buffered. */
export const CATALOG_MAX_BYTES = 256 * 1024;

/**
 * The body as text, refusing past the cap while it streams in: `Content-Length` is
 * checked first when the server sends one, but it is advisory, so the bytes are counted too.
 */
async function readCapped(res: Response): Promise<string> {
  const tooLarge = () => new Error("catalog is too large");
  const declared = Number(res.headers.get("content-length") ?? 0);
  if (declared > CATALOG_MAX_BYTES) throw tooLarge();
  if (!res.body) {
    // A mock or a bodiless response: nothing to stream, so measure after the fact.
    const text = await res.text();
    if (Buffer.byteLength(text, "utf8") > CATALOG_MAX_BYTES) throw tooLarge();
    return text;
  }
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > CATALOG_MAX_BYTES) {
      await reader.cancel();
      throw tooLarge();
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

/** Check each redirect before following it, so HTTPS cannot downgrade to HTTP. */
async function fetchCatalog(url: string, fetcher: typeof fetch): Promise<Response> {
  const signal = AbortSignal.timeout(10_000);
  for (let redirects = 0; ; redirects++) {
    if (new URL(url).protocol !== "https:") throw new Error("catalog URL must use HTTPS");
    const res = await fetcher(url, { redirect: "manual", signal });
    if (![301, 302, 303, 307, 308].includes(res.status)) return res;
    await res.body?.cancel();
    const location = res.headers.get("location");
    if (!location || redirects >= 5) throw new Error("invalid catalog redirect");
    url = new URL(location, url).href;
  }
}

/** The catalog as the runtime sees it: cache or network, then the overlay on top. */
export async function loadCatalog(options: CatalogOptions = {}): Promise<CatalogEntry[]> {
  const dir = options.dir ?? stateDir();
  const cache = catalogCacheFile(dir);
  let entries = isFresh(cache) ? readEntries(cache) : undefined;

  if (!entries) {
    try {
      const url = options.url ?? env[CATALOG_URL_ENV] ?? DEFAULT_CATALOG_URL;
      const res = await fetchCatalog(url, options.fetch ?? globalThis.fetch);
      if (!res.ok) throw new Error(`catalog ${res.status}`);
      const body: unknown = JSON.parse(await readCapped(res));
      if (!Array.isArray(body)) throw new Error("catalog is not an array");
      entries = body.flatMap((row) => {
        const parsed = catalogEntrySchema.safeParse(row);
        return parsed.success ? [parsed.data] : [];
      });
      mkdirSync(dir, { recursive: true });
      writeFileSync(cache, `${JSON.stringify(entries, null, 2)}\n`);
    } catch {
      // Offline, or a broken remote catalog: a stale cache beats nothing, and the copy
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
