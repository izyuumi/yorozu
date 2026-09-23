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

test.each(["http://example.com/models.json", "file:///tmp/models.json", "not a URL"])(
  "an insecure or malformed catalog URL falls back without fetching: %s",
  async (url) => {
    const fetchMock = served([row("untrusted/model")]);
    const entries = await loadCatalog({ dir, url, fetch: fetchMock });
    expect(entries.map((entry) => entry.id)).toContain("claude-cli/claude-opus-5");
    expect(fetchMock).not.toHaveBeenCalled();
  },
);

test("HTTPS redirects reach the release asset without automatic redirect following", async () => {
  const fetchMock = vi.fn<typeof fetch>()
    .mockResolvedValueOnce(new Response(null, {
      status: 302,
      headers: { location: "https://github.com/example/models.json" },
    }))
    .mockResolvedValueOnce(Response.json([row("openai/a")]));

  expect(await loadCatalog({ dir, fetch: fetchMock })).toEqual([row("openai/a")]);
  expect(fetchMock).toHaveBeenLastCalledWith(
    "https://github.com/example/models.json",
    expect.objectContaining({ redirect: "manual" }),
  );
});

test("a redirect to HTTP falls back before requesting the insecure destination", async () => {
  const fetchMock = vi.fn<typeof fetch>().mockResolvedValueOnce(new Response(null, {
    status: 302,
    headers: { location: "http://example.com/models.json" },
  }));
  const entries = await loadCatalog({ dir, fetch: fetchMock });
  expect(entries.map((entry) => entry.id)).toContain("claude-cli/claude-opus-5");
  expect(fetchMock).toHaveBeenCalledOnce();
});

test("a catalog request that hangs is aborted after ten seconds and falls back", async () => {
  const timeout = vi.spyOn(AbortSignal, "timeout");
  const fetchMock = vi.fn<typeof fetch>().mockImplementation(async (_url, init) => {
    const signal = init?.signal;
    if (!signal) return Response.json([row("untrusted/model")]);
    return new Promise<Response>((_resolve, reject) => {
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
    });
  });
  try {
    const entries = await loadCatalog({ dir, fetch: fetchMock });
    expect(entries.map((entry) => entry.id)).toContain("claude-cli/claude-opus-5");
    expect(timeout).toHaveBeenCalledWith(10_000);
  } finally {
    timeout.mockRestore();
  }
}, 15_000);

test.each(["a".repeat(256 * 1024), "界".repeat(90 * 1024)])(
  "a catalog body larger than 256 KiB falls back without caching",
  async (note) => {
    const fetchMock = served([{ ...row("oversized/model"), note }]);
    const entries = await loadCatalog({ dir, fetch: fetchMock });
    expect(entries.map((entry) => entry.id)).toContain("claude-cli/claude-opus-5");
    expect(() => readFileSync(catalogCacheFile(dir), "utf8")).toThrow();
  },
);

test("a Content-Length over the cap is refused before the body is read", async () => {
  const body = new ReadableStream<Uint8Array>({
    pull() {
      throw new Error("the body must not be read");
    },
  });
  const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(
    new Response(body, { status: 200, headers: { "content-length": String(300 * 1024) } }),
  );
  const entries = await loadCatalog({ dir, fetch: fetchMock });
  expect(entries.map((entry) => entry.id)).toContain("claude-cli/claude-opus-5");
  expect(() => readFileSync(catalogCacheFile(dir), "utf8")).toThrow();
});

test("a body that streams past the cap is cancelled, not buffered to the end", async () => {
  let pulled = 0;
  const chunk = new TextEncoder().encode(`[${JSON.stringify(row("x/y"))},`.padEnd(64 * 1024, " "));
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      pulled++;
      controller.enqueue(chunk);
    },
  });
  const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(new Response(body, { status: 200 }));
  const entries = await loadCatalog({ dir, fetch: fetchMock });
  expect(entries.map((entry) => entry.id)).toContain("claude-cli/claude-opus-5");
  // 64 KiB per pull: the fifth chunk crosses 256 KiB, and the stream is not read further.
  expect(pulled).toBeLessThanOrEqual(6);
});

test("invalid catalog rows are dropped while valid nullable fields and model ids survive", async () => {
  const valid = {
    ...row("openai/<your model>:v1.2-test_3", null),
    outputPer1M: null,
    contextK: null,
    note: "custom endpoint",
  };
  const invalid = [
    null,
    {},
    row(""),
    row("bad\nmodel"),
    row("bad;model"),
    row("x".repeat(121)),
    { ...row("bad/provider"), provider: 1 },
    { ...row("bad/input"), inputPer1M: "1" },
    { ...row("bad/output"), outputPer1M: false },
    { ...row("bad/context"), contextK: "100" },
    { ...row("bad/strengths"), strengths: [1] },
    { ...row("bad/updated"), updated: null },
    { ...row("bad/note"), note: [] },
  ];
  const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(Response.json([valid, ...invalid]));
  expect(await loadCatalog({ dir, fetch: fetchMock })).toEqual([valid]);
  expect(await loadCatalog({ dir, fetch: offline() })).toEqual([valid]);
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
