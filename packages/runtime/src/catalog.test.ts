import { mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import {
  CATALOG_TTL_MS,
  catalogCacheFile,
  catalogOverlayFile,
  loadCatalog,
  mergeById,
  writeOverlay,
  type CatalogEntry,
} from "./catalog.js";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-catalog-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const row = (id: string, inputPer1M: number | null = 1): CatalogEntry => ({
  id,
  provider: "test",
  inputPer1M,
  outputPer1M: 2,
  contextK: 100,
  strengths: ["testing"],
  updated: "2026-09-12",
});

const served = (entries: CatalogEntry[]) =>
  vi.fn<typeof fetch>().mockResolvedValue(Response.json(entries));

const offline = () => vi.fn<typeof fetch>().mockRejectedValue(new Error("offline"));

test("the release asset is fetched once, then served from the day-old cache", async () => {
  const fetchMock = served([row("openai/a")]);
  expect(await loadCatalog({ dir, fetch: fetchMock })).toEqual([row("openai/a")]);
  expect(JSON.parse(readFileSync(catalogCacheFile(dir), "utf8"))).toEqual([row("openai/a")]);

  // Inside the 24h window nothing is fetched again, even when the network is gone.
  const second = offline();
  expect(await loadCatalog({ dir, fetch: second })).toEqual([row("openai/a")]);
  expect(second).not.toHaveBeenCalled();
});

test("a stale cache is refreshed, and kept when the refresh fails", async () => {
  await loadCatalog({ dir, fetch: served([row("openai/a")]) });
  const stale = new Date(Date.now() - CATALOG_TTL_MS - 60_000);
  utimesSync(catalogCacheFile(dir), stale, stale);

  const fetchMock = served([row("openai/b")]);
  expect(await loadCatalog({ dir, fetch: fetchMock })).toEqual([row("openai/b")]);
  expect(fetchMock).toHaveBeenCalledOnce();

  utimesSync(catalogCacheFile(dir), stale, stale);
  expect(await loadCatalog({ dir, fetch: offline() })).toEqual([row("openai/b")]);
});

test("with no cache and no network the bundled catalog answers", async () => {
  const entries = await loadCatalog({ dir, fetch: offline() });
  expect(entries.map((entry) => entry.id)).toContain("claude-cli/claude-opus-5");
  // The fallback is read, not cached: the next run still tries for a fresh one.
  expect(() => readFileSync(catalogCacheFile(dir), "utf8")).toThrow();
});

test("an HTTP error is a failure, not a catalog", async () => {
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValue(new Response("nope", { status: 404 }));
  const entries = await loadCatalog({ dir, fetch: fetchMock });
  expect(entries.map((entry) => entry.id)).toContain("claude-cli/claude-opus-5");
});

test("the overlay is merged over the catalog by id, field by field", async () => {
  await loadCatalog({ dir, fetch: served([row("openai/a"), row("openai/b")]) });
  writeFileSync(
    catalogOverlayFile(dir),
    JSON.stringify([{ id: "openai/a", inputPer1M: 99 }, row("openai/c")]),
  );

  const entries = await loadCatalog({ dir, fetch: offline() });
  expect(entries.map((entry) => entry.id)).toEqual(["openai/a", "openai/b", "openai/c"]);
  // Overridden field replaced, untouched ones kept.
  expect(entries[0]).toMatchObject({ id: "openai/a", inputPer1M: 99, outputPer1M: 2 });
});

test("writing the overlay merges into it and leaves the catalog alone", async () => {
  await loadCatalog({ dir, fetch: served([row("openai/a")]) });

  writeOverlay([row("openai/a", 50)], dir);
  writeOverlay([row("openai/c", 7)], dir);

  const overlay = JSON.parse(readFileSync(catalogOverlayFile(dir), "utf8")) as CatalogEntry[];
  expect(overlay.map((entry) => entry.id)).toEqual(["openai/a", "openai/c"]);
  expect(JSON.parse(readFileSync(catalogCacheFile(dir), "utf8"))).toEqual([row("openai/a")]);
  expect((await loadCatalog({ dir, fetch: offline() }))[0]!.inputPer1M).toBe(50);
});

test("merging keeps base order and appends what is new", () => {
  expect(mergeById([row("a"), row("b")], [row("b", 9), row("c")]).map((e) => e.id)).toEqual([
    "a",
    "b",
    "c",
  ]);
});
