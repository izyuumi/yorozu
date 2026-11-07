import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  MAX_STRING_CHARS, MAX_BLOCKS, MAX_PRESENTATION_BYTES, MAX_FALLBACK_BYTES,
  MAX_TABLE_COLUMNS, MAX_TABLE_ROWS, MAX_CHART_SERIES, MAX_CHART_CATEGORIES, MAX_CHART_SEGMENTS,
  sanitizePresentation, type PresentationSdk,
} from "../src/presentation.ts";

const fixture = JSON.parse(readFileSync(new URL("fixtures/presentation-sdk-2026.9.8.json", import.meta.url), "utf8")) as {
  cases: { name: string; input: { blocks: Record<string, unknown>[] }; normalized: { blocks: Record<string, unknown>[] } | null }[];
};
// Preflight applies the SDK's string trim rule before calling the pinned normalizer.
function trimmed(raw: unknown): unknown {
  if (typeof raw === "string") return raw.trim();
  if (Array.isArray(raw)) return raw.map(trimmed);
  if (raw && typeof raw === "object") return Object.fromEntries(Object.entries(raw).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, trimmed(v)]));
  return raw;
}
const pinned = new Map(fixture.cases.map((c) => [JSON.stringify(trimmed(c.input)), c.normalized]));
const missingPins: string[] = [];
const sdk: PresentationSdk = {
  normalize(raw) {
    const key = JSON.stringify(trimmed(raw));
    if (!pinned.has(key)) missingPins.push(key);
    assert.ok(pinned.has(key), `unpinned SDK input: ${key}`);
    return structuredClone(pinned.get(key));
  },
  tableAlt: (b) => `${b.caption}\n${b.headers.join(", ")}\n${b.rows.map((r) => r.join(", ")).join("\n")}`,
  chartAlt: (b) => b.chartType === "pie" ? `${b.title}\n${b.segments.map((s) => `${s.label}: ${s.value}`).join("\n")}`
    : `${b.title}\n${b.series.map((s) => `${s.name}: ${s.values.join(", ")}`).join("\n")}`,
};
const identity: PresentationSdk = { ...sdk, normalize: (raw) => raw };
const table = () => ({ type: "table", caption: "Balances", headers: ["Who", "Paid"], rows: [["A", 120], ["B", 0]], rowHeaderColumnIndex: 0 });
const chart = () => ({ type: "chart", chartType: "bar", title: "Paid", categories: ["A", "B"], series: [{ name: "Paid", values: [120, 0] }] });
const sanitize = (...blocks: unknown[]) => sanitizePresentation({ blocks }, identity);
const forbidden = ["action", "url", "value", "callback", "approvalId", "command", "__proto__", "constructor"];
function assertSafe(raw: unknown, path: string[] = [], segment = false): void {
  if (!raw || typeof raw !== "object") return;
  for (const [key, value] of Object.entries(raw)) {
    const segmentValue = key === "value" && segment;
    assert.ok(!forbidden.includes(key) || segmentValue, [...path, key].join("."));
    if (key === "segments" && "type" in raw && raw.type === "chart" && "chartType" in raw && raw.chartType === "pie" && Array.isArray(value)) {
      value.forEach((s: unknown, i: number) => assertSafe(s, [...path, key, String(i)], true));
    } else assertSafe(value, [...path, key]);
  }
}
function spySdk(base = identity) {
  const calls = { normalize: 0, tableAlt: 0, chartAlt: 0 };
  const spy: PresentationSdk = {
    normalize(raw) { calls.normalize++; assertSafe(raw); return base.normalize(raw); },
    tableAlt(b) { calls.tableAlt++; return base.tableAlt(b); },
    chartAlt(b) { calls.chartAlt++; return base.chartAlt(b); },
  };
  return { calls, spy };
}

test("pinned SDK accepts exact table/cartesian/pie schemas; dropped blocks become honest context", () => {
  for (const c of fixture.cases) {
    const { calls, spy } = spySdk(sdk);
    const before = structuredClone(c.input);
    const result = sanitizePresentation(c.input, spy);
    const expected = c.normalized?.blocks[0];
    const block = result.presentation?.blocks[0];
    assert.equal(calls.normalize, 1, c.name);
    if (expected) {
      assert.ok(block, c.name);
      const { alt, ...native } = block;
      assert.deepEqual(native, expected, c.name);
      assert.ok(alt, c.name);
      assert.equal(calls.tableAlt, expected.type === "table" ? 1 : 0, c.name);
      assert.equal(calls.chartAlt, expected.type === "chart" ? 1 : 0, c.name);
    } else {
      assert.equal(block?.type, "context", c.name);
      assert.match(block?.alt ?? "", /\((table|chart|text) omitted: invalid data\)$/, c.name);
      assert.equal(calls.tableAlt + calls.chartAlt, 0, c.name);
      assert.ok(!result.fallbackText.includes("undefined"), c.name);
    }
    assertSafe(result);
    assert.deepEqual(c.input, before);
  }
  assert.deepEqual(missingPins, []);
});

test("SDK drops and exceptions preserve primitive summaries without native invalid data", () => {
  const raw = { blocks: [table(), chart(), { type: "text", text: "Intro" }] };
  for (const normalize of [() => ({ blocks: [] }), () => undefined, () => { throw new Error("SDK"); }]) {
    const { calls, spy } = spySdk({ ...identity, normalize });
    const result = sanitizePresentation(raw, spy);
    assert.equal(calls.normalize, 3);
    assert.equal(calls.tableAlt + calls.chartAlt, 0);
    assert.deepEqual(result.presentation?.blocks.map((b) => b.type), ["context", "context", "context"]);
    assert.match(result.fallbackText, /Balances\nA, 120\nB, 0/);
    assert.match(result.fallbackText, /Paid\nPaid: 120, 0/);
    assert.match(result.fallbackText, /Intro\n\(text omitted/);
  }
  for (const method of ["tableAlt", "chartAlt"] as const) {
    const result = sanitizePresentation(raw, { ...identity, [method]: () => { throw new Error("alt"); } });
    assert.match(result.fallbackText, /omitted: invalid data/);
    assert.equal(result.presentation?.blocks[2]?.type, "text");
  }
});

test("allowlists nested schemas; controls, inherited properties, accessors, cycles stay inert", () => {
  const malicious = JSON.parse('{"action":{},"url":"secret","value":"secret","callback":"secret","approvalId":"secret","command":"secret","__proto__":{},"constructor":"secret"}') as Record<string, unknown>;
  let getters = 0;
  const hostile = new Proxy({ title: "Title", blocks: [
    { ...table(), ...malicious, rows: table().rows.map((r) => Object.assign(r, malicious)) },
    { ...chart(), ...malicious, series: chart().series.map((s) => ({ ...s, ...malicious })) },
    { type: "chart", chartType: "pie", title: "Pie", segments: [{ label: "A", ...malicious, value: 1 }] },
    { type: "buttons", buttons: [{ label: "secret", command: "secret" }] },
    { type: "select", options: [{ label: "secret", value: "secret" }] },
    { type: "unknown", text: "secret" }, Object.create({ type: "text", text: "secret" }) as unknown,
    { type: "text", get text() { getters++; throw new Error("getter"); } },
  ], get command() { getters++; return "secret"; } }, {
    get() { throw new Error("get forbidden"); }, ownKeys() { throw new Error("enumeration forbidden"); },
  });
  const result = sanitizePresentation(hostile, identity);
  assert.equal(getters, 0);
  assertSafe(result);
  assert.ok(!JSON.stringify(result).includes("secret"));
  assert.deepEqual(result.presentation?.blocks.map((b) => b.type), ["table", "chart", "chart", "context"]);
  const cyclic: Record<string, unknown> = { ...table() }; cyclic.rows = [cyclic];
  const cyclicRows: unknown[] = []; cyclicRows.push(cyclicRows);
  let deep: unknown = "Bottom";
  for (let i = 0; i < 10000; i++) deep = { rows: [deep] };
  for (const b of [cyclic, { ...table(), rows: cyclicRows }, { ...table(), rows: [[deep, 1]] }]) {
    const output = sanitize(b);
    assert.equal(output.presentation?.blocks[0]?.type, "context");
    assertSafe(output);
  }
  assert.deepEqual(sanitize({ type: "buttons", text: "secret" }), { fallbackText: "" });
});

test("divider alt stays empty; SDK trim rules apply to titles, text, tones, axis labels", () => {
  const result = sanitizePresentation({ title: "   ", tone: " INFO ", blocks: [
    { type: "text", text: " Before " }, { type: "divider" }, { type: "text", text: " After " },
  ] }, identity);
  assert.equal(result.presentation?.title, undefined);
  assert.equal(result.presentation?.tone, "info");
  assert.deepEqual(result.presentation?.blocks[1], { type: "divider", alt: "" });
  assert.equal(result.fallbackText, "Before\n\nAfter");
  assert.equal(sanitizePresentation({ title: " ".repeat(5000), blocks: [] }, identity).fallbackText, "");
  assert.deepEqual(sanitizePresentation({ title: " Title ", blocks: [] }, identity), { fallbackText: "Title" });
  assert.equal(sanitizePresentation({ tone: "evil", blocks: [{ type: "divider" }] }, identity).presentation?.tone, undefined);
});

test("UTF-16 boundaries repair lone surrogates; all truncations marked; UTF-8 JSON round-trips", () => {
  for (const text of ["x".repeat(MAX_STRING_CHARS - 1) + "😀rest", "x".repeat(MAX_STRING_CHARS - 2) + "😀rest", "\ud800bad\udfff"]) {
    const result = sanitize({ type: "text", text });
    const block = result.presentation?.blocks[0];
    assert.ok(block && block.type === "text");
    assert.equal(block.text.isWellFormed(), true);
    assert.deepEqual(JSON.parse(Buffer.from(JSON.stringify(result), "utf8").toString("utf8")), result);
    if (text.length > MAX_STRING_CHARS) assert.ok(block.text.endsWith("…"));
    else assert.equal(block.text, "�bad�");
  }
  const alt = sanitizePresentation({ blocks: [table()] }, { ...identity, tableAlt: () => "x".repeat(MAX_STRING_CHARS - 1) + "😀rest" });
  assert.equal(alt.presentation?.blocks[0]?.alt, "x".repeat(MAX_STRING_CHARS - 1) + "…");
  const raw = { blocks: [{ ...table(), headers: ["H"], rows: [["x".repeat(10 * 1024 * 1024)]] }] };
  const checking: PresentationSdk = { ...identity, normalize(data) {
    assert.ok(Buffer.byteLength(JSON.stringify(data)) < MAX_STRING_CHARS + 1000);
    return data;
  } };
  const result = sanitizePresentation(raw, checking);
  assert.equal(result.presentation?.blocks[0]?.type, "table");
  assert.match(result.fallbackText, /…/);
});

test("optional strings trim bounded code-point prefixes and preserve truncation markers", () => {
  for (const [text, expected] of [
    [" ".repeat(256) + "x".repeat(MAX_STRING_CHARS) + " tail", "x".repeat(MAX_STRING_CHARS) + "…"],
    [" ".repeat(MAX_STRING_CHARS + 255) + "😀tail", ""],
    ["  Normal\u00a0", "Normal"],
    [" ".repeat(300) + "Title" + " ".repeat(MAX_STRING_CHARS), "Title…"],
  ]) {
    assert.equal(sanitizePresentation({ title: text, blocks: [] }, identity).fallbackText, expected);
  }
});

function fakeArray(limit: number, entry: (i: number) => unknown) {
  let reads = 0;
  const array = new Proxy<unknown[]>([], {
    get() { throw new Error("ordinary read forbidden"); }, ownKeys() { throw new Error("enumeration forbidden"); },
    getOwnPropertyDescriptor(target, key) {
      if (key === "length") return { value: 1_000_000, writable: true, enumerable: false, configurable: false };
      if (typeof key === "string" && /^\d+$/.test(key)) {
        const i = Number(key);
        assert.ok(i <= limit, `past lookahead: ${i}`);
        reads++;
        return { value: entry(i), enumerable: true, configurable: true, writable: true };
      }
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  return { array, reads: () => reads };
}

test("overflow counts only bounded prefixes; never calls any SDK method for that block", () => {
  const cases: [string, number, (a: unknown[]) => unknown, (i: number) => unknown][] = [
    ["rows", MAX_TABLE_ROWS, (rows) => ({ ...table(), rows }), () => ["A", 1]],
    ["columns", MAX_TABLE_COLUMNS, (headers) => ({ ...table(), headers }), (i) => `H${i}`],
    ["row columns", MAX_TABLE_COLUMNS, (row) => ({ ...table(), rows: [row] }), () => 1],
    ["series", MAX_CHART_SERIES, (series) => ({ ...chart(), series }), (i) => ({ name: `S${i}`, values: [1, 2] })],
    ["categories", MAX_CHART_CATEGORIES, (categories) => ({ ...chart(), categories }), (i) => `C${i}`],
    ["values", MAX_CHART_CATEGORIES, (values) => ({ ...chart(), series: [{ name: "S", values }] }), () => 1],
    ["segments", MAX_CHART_SEGMENTS, (segments) => ({ type: "chart", chartType: "pie", title: "Shares", segments }), (i) => ({ label: `S${i}`, value: 1 })],
  ];
  for (const [name, limit, build, entry] of cases) {
    const fake = fakeArray(limit, entry);
    const { calls, spy } = spySdk();
    const result = sanitizePresentation({ blocks: [build(fake.array)] }, spy);
    assert.equal(fake.reads(), limit + 1, name);
    assert.deepEqual(calls, { normalize: 0, tableAlt: 0, chartAlt: 0 }, name);
    assert.equal(result.presentation?.blocks[0]?.type, "context", name);
    assert.match(result.fallbackText, /\((table|chart) truncated: \d+\+ (rows|columns|series|categories|values|segments)\)$/, name);
    assertSafe(result);
  }
  const fake = fakeArray(MAX_BLOCKS, (i) => ({ type: "text", text: String(i) }));
  const { calls, spy } = spySdk();
  const result = sanitizePresentation({ blocks: fake.array }, spy);
  assert.equal(fake.reads(), MAX_BLOCKS + 1);
  assert.equal(calls.normalize, MAX_BLOCKS);
  assert.equal(result.presentation?.blocks.length, MAX_BLOCKS);
  assert.equal(result.presentation?.blocks.at(-1)?.alt, "(2+ more blocks omitted)");
});

test("limits accept exact SDK-shaped dimensions", () => {
  const headers = Array.from({ length: MAX_TABLE_COLUMNS }, (_, i) => `H${i}`);
  const t = { ...table(), headers, rows: Array.from({ length: MAX_TABLE_ROWS }, () => headers.map(() => 1)) };
  const categories = Array.from({ length: MAX_CHART_CATEGORIES }, (_, i) => `C${i}`);
  const c = { ...chart(), categories, series: Array.from({ length: MAX_CHART_SERIES }, (_, i) => ({ name: `S${i}`, values: categories.map(() => 1) })) };
  assert.equal(sanitize(t).presentation?.blocks[0]?.type, "table");
  assert.equal(sanitize(c).presentation?.blocks[0]?.type, "chart");
  assert.equal(sanitize({ type: "chart", chartType: "pie", title: "Shares", segments: categories.map((label) => ({ label, value: 1 })) }).presentation?.blocks[0]?.type, "chart");
});

test("running UTF-8 presentation and fallback budgets retain earlier blocks and explicit omission notes", () => {
  const { calls, spy } = spySdk();
  const result = sanitizePresentation({ title: "界".repeat(MAX_STRING_CHARS), blocks: Array.from({ length: MAX_BLOCKS }, (_, i) => ({ type: "text", text: `${i}:` + "界".repeat(2000) })) }, spy);
  assert.ok(result.presentation);
  assert.ok(Buffer.byteLength(JSON.stringify(result.presentation)) <= MAX_PRESENTATION_BYTES);
  assert.ok(result.presentation.blocks.length > 1 && result.presentation.blocks.length < MAX_BLOCKS);
  assert.match(result.presentation.blocks[0]?.alt ?? "", /^0:/);
  assert.match(result.presentation.blocks.at(-1)?.alt ?? "", /^\(\d+\+ more blocks omitted\)$/);
  assert.ok(calls.normalize < MAX_BLOCKS, "stop normalizing after byte budget");
  assert.ok(Buffer.byteLength(result.fallbackText) <= MAX_FALLBACK_BYTES);
  assert.ok(result.fallbackText.endsWith("…(truncated)"));
  assert.deepEqual(JSON.parse(Buffer.from(JSON.stringify(result), "utf8").toString("utf8")), result);
});

test("untrusted roots reject before SDK; bounded JSON input accepted", () => {
  const { calls, spy } = spySdk();
  for (const raw of [null, undefined, 1, true, [], "null", "1", "[]", "invalid JSON", "x".repeat(MAX_PRESENTATION_BYTES + 1), JSON.stringify({ title: "界".repeat(MAX_PRESENTATION_BYTES / 2) })]) {
    assert.deepEqual(sanitizePresentation(raw, spy), { fallbackText: "" });
  }
  assert.deepEqual(calls, { normalize: 0, tableAlt: 0, chartAlt: 0 });
  const raw = { title: "JSON", blocks: [{ type: "text", text: "Safe" }] };
  const padded = JSON.stringify(raw) + " ".repeat(MAX_PRESENTATION_BYTES - JSON.stringify(raw).length);
  assert.deepEqual(sanitizePresentation(padded, identity), sanitizePresentation(raw, identity));
  const throwing = new Proxy<unknown[]>([], { getOwnPropertyDescriptor() { throw new Error("trap"); } });
  assert.deepEqual(sanitizePresentation({ title: "Title", blocks: throwing }, spy), { fallbackText: "Title" });
});

test("invalid optional scalars cannot disappear into valid tables; finite-only schemas enforced", () => {
  for (const index of [null, true, {}, [], "0", 0.5, -1, 2, NaN, Infinity, Symbol("index"), () => 0]) {
    assert.equal(sanitize({ ...table(), rowHeaderColumnIndex: index }).presentation?.blocks[0]?.type, "context");
  }
  for (const value of [null, true, {}, [], "", "   ", NaN, Infinity, -Infinity]) {
    assert.equal(sanitize({ ...table(), rows: [["A", value]] }).presentation?.blocks[0]?.type, "context");
    assert.equal(sanitize({ ...chart(), series: [{ name: "S", values: [1, value] }] }).presentation?.blocks[0]?.type, "context");
    assert.equal(sanitize({ type: "chart", chartType: "pie", title: "Pie", segments: [{ label: "A", value }] }).presentation?.blocks[0]?.type, "context");
  }
  for (const value of [0, -1]) assert.equal(sanitize({ type: "chart", chartType: "pie", title: "Pie", segments: [{ label: "A", value }] }).presentation?.blocks[0]?.type, "context");
});

test("chart discriminant ignores fields belonging to the other variant", () => {
  const forbiddenArray = new Proxy<unknown[]>([], { getOwnPropertyDescriptor() { throw new Error("irrelevant field traversed"); } });
  assert.equal(sanitize({ ...chart(), segments: forbiddenArray }).presentation?.blocks[0]?.type, "chart");
  assert.equal(sanitize({ type: "chart", chartType: "pie", title: "Pie", segments: [{ label: "A", value: 1 }],
    categories: forbiddenArray, series: forbiddenArray }).presentation?.blocks[0]?.type, "chart");
});

test("global node budget stops repeated bounded tables without allocating large inputs", () => {
  const row = Array.from({ length: MAX_TABLE_COLUMNS }, () => 0);
  const t = { ...table(), headers: row.map((_, i) => `H${i}`), rows: Array.from({ length: MAX_TABLE_ROWS }, () => row) };
  const fake = fakeArray(MAX_BLOCKS, () => t);
  const { calls, spy } = spySdk();
  const result = sanitizePresentation({ blocks: fake.array }, spy);
  assert.ok(calls.normalize > 0 && calls.normalize < 6);
  assert.ok(fake.reads() < 6);
  assert.match(result.fallbackText, /table omitted: resource limit/);
  assert.match(result.presentation?.blocks.at(-1)?.alt ?? "", /more blocks omitted/);
  assertSafe(result);
});

test("shared character budget bounds repeated strings across blocks and both preflight passes", () => {
  const text = "x".repeat(MAX_STRING_CHARS);
  const t = { ...table(), headers: ["H"], rows: Array.from({ length: 10 }, () => [text]) };
  const large = { ...t, rows: Array.from({ length: MAX_TABLE_ROWS }, () => Array(MAX_TABLE_COLUMNS).fill(text)),
    headers: Array.from({ length: MAX_TABLE_COLUMNS }, (_, i) => `H${i}`) };
  for (const [input, base, maxCalls] of [
    [large, identity, 0],
    [t, { ...identity, normalize: () => ({ blocks: [{ ...t, caption: "" }] }) }, 3],
    [table(), { ...identity, normalize: () => ({ blocks: [large] }) }, 1],
  ] as const) {
    const fake = fakeArray(MAX_BLOCKS, () => input);
    const { calls, spy } = spySdk(base);
    const result = sanitizePresentation({ blocks: fake.array }, spy);
    assert.ok(Buffer.byteLength(JSON.stringify(result)) <= MAX_PRESENTATION_BYTES);
    assert.ok(calls.normalize <= maxCalls, `normalize calls: ${calls.normalize}`);
    assert.ok(fake.reads() <= maxCalls + 1);
    assert.match(result.fallbackText, /table omitted: resource limit/);
    assert.match(result.presentation?.blocks.at(-1)?.alt ?? "", /\d+\+ more blocks omitted/);
  }
});
