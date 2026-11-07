import assert from "node:assert/strict";
import test from "node:test";
import {
  MAX_STRING_CHARS, MAX_BLOCKS, MAX_PRESENTATION_BYTES,
  sanitizePresentation, type PresentationSdk,
} from "../src/presentation.ts";

const sdk: PresentationSdk = {
  normalize: (raw) => raw,
  tableAlt: (b) => [b.caption ?? "Table", b.headers.join(", "), ...b.rows.map((r) => r.join(", "))].join("\n"),
  chartAlt: (b) => [b.title, ...b.series.map((s) => `${s.name}: ${s.values.join(", ")}`)].join("\n"),
};
const table = () => ({ type: "table", caption: "Balances", headers: ["Who", "Paid"], rows: [["A", 120], ["B", 0]], rowHeaderColumnIndex: 0 });
const chart = () => ({ type: "chart", chartType: "bar", title: "Paid", categories: ["A", "B"], series: [{ name: "Paid", values: [120, 0] }] });
const sanitize = (...blocks: unknown[]) => sanitizePresentation({ blocks }, sdk);
const forbidden = ["action", "url", "value", "callback", "approvalId", "command", "__proto__", "constructor"];
function assertSafe(raw: unknown): void {
  if (!raw || typeof raw !== "object") return;
  for (const [key, value] of Object.entries(raw)) {
    assert.ok(!forbidden.includes(key), key);
    assertSafe(value);
  }
}

test("rebuilds title, tones, table, chart and non-empty divider alt", () => {
  const raw = { title: "Trip", tone: "info", blocks: [{ type: "text", text: "Intro" }, { type: "context", text: "Note" }, { type: "divider" }, table(), chart()] };
  const before = structuredClone(raw);
  const result = sanitizePresentation(raw, sdk);
  assert.deepEqual(result, {
    presentation: { title: "Trip", tone: "info", blocks: [
      { type: "text", text: "Intro", alt: "Intro" }, { type: "context", text: "Note", alt: "Note" }, { type: "divider", alt: "—" },
      { ...table(), alt: "Balances\nWho, Paid\nA, 120\nB, 0" }, { ...chart(), alt: "Paid\nPaid: 120, 0" },
    ] },
    fallbackText: "Trip\n\nIntro\n\nNote\n\n—\n\nBalances\nWho, Paid\nA, 120\nB, 0\n\nPaid\nPaid: 120, 0",
  });
  assert.deepEqual(raw, before);
  assert.deepEqual(sanitizePresentation(raw, sdk), result);
  for (const tone of ["info", "success", "warning", "danger", "neutral"]) {
    assert.equal(sanitizePresentation({ tone, blocks: [{ type: "divider" }] }, sdk).presentation?.tone, tone);
  }
  assert.equal(sanitizePresentation({ tone: "evil", blocks: [{ type: "divider" }] }, sdk).presentation?.tone, undefined);
  for (const kind of ["bar", "area", "line", "pie"]) {
    assert.equal(sanitize({ ...chart(), chartType: kind }).presentation?.blocks[0]?.type, "chart");
  }
  assert.equal(sanitize({ ...chart(), chartType: "radar" }).presentation?.blocks[0]?.type, "context");
});

test("drops controls and unknown blocks without rendering their actions", () => {
  const result = sanitize({ type: "buttons", buttons: [{ label: "Run", command: "secret" }] },
    { type: "select", options: [{ label: "Approve", approvalId: "secret" }] }, { type: "unknown", text: "secret" });
  assert.deepEqual(result, { fallbackText: "" });
  assert.deepEqual(sanitizePresentation({ title: "Title only", blocks: [] }, sdk), { fallbackText: "Title only" });
});

test("allowlists every nesting level; never renders objects or prototype fields", () => {
  const malicious = JSON.parse('{"action":{},"url":"secret","value":"secret","callback":"secret","approvalId":"secret","command":"secret","__proto__":{"polluted":true},"constructor":"secret"}') as Record<string, unknown>;
  const t = table();
  const c = chart();
  const dirty = { ...malicious, title: "Trip", blocks: [
    { ...t, ...malicious, rows: t.rows.map((r) => Object.assign(r, malicious)), headers: Object.assign(t.headers, malicious) },
    { ...c, ...malicious, categories: Object.assign(c.categories, malicious),
      series: c.series.map((s) => ({ ...s, ...malicious, values: Object.assign(s.values, malicious) })) },
    { type: "context", text: "Safe", ...malicious }, { type: "divider", ...malicious },
  ] };
  const result = sanitizePresentation(dirty, sdk);
  assertSafe(result);
  assert.ok(result.presentation);
  assert.ok(!JSON.stringify(result).includes("secret"));
  for (const value of [malicious, [], NaN, Infinity, -Infinity]) {
    const invalidTable = sanitize({ ...table(), rows: [[value]] });
    const invalidChart = sanitize({ ...chart(), series: [{ name: "Bad", values: [value, 0] }] });
    assert.equal(invalidTable.presentation?.blocks[0]?.type, "context");
    assert.equal(invalidChart.presentation?.blocks[0]?.type, "context");
    assertSafe(invalidTable);
    assertSafe(invalidChart);
    assert.ok(!JSON.stringify(invalidTable).includes("secret"));
  }
  for (const header of [7, malicious, null, []]) {
    assert.equal(sanitize({ ...table(), headers: [header] }).presentation?.blocks[0]?.type, "context");
  }
  const forgedType = { toString: () => "bar", url: "secret" };
  const forged = sanitize({ ...chart(), chartType: forgedType });
  assert.equal(forged.presentation?.blocks[0]?.type, "context");
  assertSafe(forged);
  const inherited = Object.create({ type: "text", text: "Inherited" }) as unknown;
  assert.deepEqual(sanitize(inherited), { fallbackText: "" });
});

test("keeps primitive cells and nullable finite chart values", () => {
  const result = sanitize({ ...table(), rows: [["A", true, null, 12]] },
    { ...chart(), series: [{ name: "Paid", values: [null, 1] }] });
  assert.equal(result.presentation?.blocks[0]?.type, "table");
  assert.equal(result.presentation?.blocks[1]?.type, "chart");
  assertSafe(result);
});

test("oversized data degrades to context; extra blocks drop in input order", () => {
  const boundaryTable = { ...table(), headers: Array.from({ length: 20 }, () => "H"),
    rows: Array.from({ length: 200 }, () => [1]) };
  const boundaryChart = { ...chart(), categories: Array.from({ length: 100 }, (_, i) => String(i)),
    series: Array.from({ length: 12 }, (_, i) => ({ name: String(i), values: Array.from({ length: 100 }, () => 1) })) };
  assert.equal(sanitize(boundaryTable).presentation?.blocks[0]?.type, "table");
  assert.equal(sanitize(boundaryChart).presentation?.blocks[0]?.type, "chart");
  const cases = [
    { ...table(), headers: Array.from({ length: 21 }, () => "H") },
    { ...table(), rows: Array.from({ length: 201 }, () => ["A", 1]) },
    { ...table(), rows: [Array.from({ length: 21 }, () => 1)] },
    { ...chart(), series: Array.from({ length: 13 }, (_, i) => ({ name: String(i), values: [1, 2] })) },
    { ...chart(), categories: Array.from({ length: 101 }, (_, i) => String(i)), series: [{ name: "Many", values: Array.from({ length: 101 }, () => 1) }] },
  ];
  for (const block of cases) {
    const result = sanitize(block);
    assert.equal(result.presentation?.blocks[0]?.type, "context");
    assert.ok(result.fallbackText);
  }
  const blocks = Array.from({ length: 60 }, (_, i) => ({ type: "text", text: String(i) }));
  const result = sanitize(...blocks);
  assert.equal(result.presentation?.blocks.length, MAX_BLOCKS);
  assert.equal(result.presentation?.blocks.at(-1)?.alt, "49");
  assert.equal(result.fallbackText, blocks.slice(0, 50).map((b) => b.text).join("\n\n"));
  assert.equal(sanitize({ type: "text", text: "x".repeat(5000) }).presentation?.blocks[0]?.alt.length, MAX_STRING_CHARS);
  const large = sanitize(...Array.from({ length: 10 }, () => ({ type: "text", text: "界".repeat(2000) })));
  assert.equal(large.presentation, undefined);
  assert.ok(large.fallbackText.length > 0);
  assert.ok(Buffer.byteLength(JSON.stringify({ blocks: Array.from({ length: 10 }, () => ({ type: "text", text: "界".repeat(2000), alt: "界".repeat(2000) })) })) > MAX_PRESENTATION_BYTES);
});

test("SDK exceptions never escape and preserve available fallback", () => {
  const throws = () => { throw new Error("SDK failed"); };
  const raw = { title: "Trip", blocks: [{ type: "text", text: "Intro" }, table(), chart()] };
  assert.deepEqual(sanitizePresentation(raw, { ...sdk, normalize: throws }), {
    fallbackText: "Trip\n\nIntro\n\nBalances\n\nPaid",
  });
  for (const method of ["tableAlt", "chartAlt"] as const) {
    const result = sanitizePresentation(raw, { ...sdk, [method]: throws });
    assert.equal(result.presentation, undefined);
    assert.ok(result.fallbackText.startsWith("Trip\n\nIntro"));
  }
  assert.deepEqual(sanitizePresentation({ get title() { throw new Error("getter"); } }, sdk), { fallbackText: "" });
  assert.deepEqual(sanitizePresentation(null, sdk), { fallbackText: "" });
});
