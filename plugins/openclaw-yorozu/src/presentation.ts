import { Buffer } from "node:buffer";

export const MAX_STRING_CHARS = 4000;
export const MAX_BLOCKS = 50;
export const MAX_DEPTH = 6;
export const MAX_NODES = 20000;
export const MAX_TABLE_COLUMNS = 20;
export const MAX_TABLE_ROWS = 200;
export const MAX_CHART_SERIES = 12;
export const MAX_CHART_CATEGORIES = 100;
export const MAX_CHART_SEGMENTS = 100;
export const MAX_PRESENTATION_BYTES = 65536;
export const MAX_PREFLIGHT_CHARS = 4 * MAX_PRESENTATION_BYTES;
export const MAX_FALLBACK_BYTES = 32768;

export type Tone = "info" | "success" | "warning" | "danger" | "neutral";
export type ChartType = "bar" | "area" | "line" | "pie";
type Cell = string | number;
export type TableBlock = {
  type: "table"; caption: string; headers: string[]; rows: Cell[][]; rowHeaderColumnIndex?: number;
};
export type ChartBlock = { type: "chart"; title: string } & (
  { chartType: "pie"; segments: { label: string; value: number }[] } |
  { chartType: "bar" | "area" | "line"; categories: string[];
    series: { name: string; values: number[] }[]; xLabel?: string; yLabel?: string }
);
type NativeBlock = TableBlock | ChartBlock | { type: "text" | "context"; text: string } | { type: "divider" };
export type Block = NativeBlock & { alt: string };
export type Presentation = { title?: string; tone?: Tone; blocks: Block[] };
export type PresentationSdk = {
  normalize(raw: unknown): unknown;
  tableAlt(block: TableBlock): string;
  chartAlt(block: ChartBlock): string;
};

const array = (raw: unknown): raw is unknown[] => {
  try { return Array.isArray(raw); } catch { return false; }
};
const record = (raw: unknown): Record<string, unknown> | undefined =>
  typeof raw === "object" && raw !== null && !array(raw) ? raw as Record<string, unknown> : undefined;
const own = (raw: object, key: string, enumerable = true): unknown => {
  try {
    const descriptor = Object.getOwnPropertyDescriptor(raw, key);
    return descriptor && (!enumerable || descriptor.enumerable) && Object.hasOwn(descriptor, "value") ? descriptor.value : undefined;
  } catch { return undefined; }
};

// Iterate only the bounded prefix; repair lone surrogates before crossing the wire.
function string(raw: unknown, limit = MAX_STRING_CHARS, marker = true): string {
  if (typeof raw !== "string") return "";
  let result = "";
  for (const point of raw) {
    if (result.length + point.length > limit) return result + (marker ? "…" : "");
    const unit = point.charCodeAt(0);
    result += point.length === 1 && unit >= 0xD800 && unit <= 0xDFFF ? "\uFFFD" : point;
  }
  return result;
}
function optional(raw: unknown): string {
  if (typeof raw !== "string") return "";
  const prefix = string(raw, MAX_STRING_CHARS + 256, false);
  const trimmed = prefix.trim();
  return string(trimmed) + (trimmed && trimmed.length <= MAX_STRING_CHARS && raw.length > prefix.length ? "…" : "");
}
const finite = (raw: unknown): raw is number => typeof raw === "number" && Number.isFinite(raw);
const context = (text: string): Block => ({ type: "context", text, alt: text });
const tone = (raw: string): raw is Tone => ["info", "success", "warning", "danger", "neutral"].includes(raw);
const bytes = (raw: unknown): number => Buffer.byteLength(JSON.stringify(raw), "utf8");

const arrayLimits = { headers: MAX_TABLE_COLUMNS, rows: MAX_TABLE_ROWS, row: MAX_TABLE_COLUMNS,
  categories: MAX_CHART_CATEGORIES, series: MAX_CHART_SERIES, values: MAX_CHART_CATEGORIES, segments: MAX_CHART_SEGMENTS };
type CopyKind = "block" | "seriesEntry" | "segment" | "scalar" | keyof typeof arrayLimits;

function preflight(budget: { chars: number; exhausted: boolean }) {
  let visits = 0;
  function copyString(value: unknown): string {
    if (budget.exhausted) return "";
    const result = optional(value);
    budget.chars += result.length;
    if (budget.chars > MAX_PREFLIGHT_CHARS) budget.exhausted = true;
    return result;
  }
  const path = new WeakSet<object>();
  function copy(value: unknown, kind: CopyKind, depth: number): unknown {
    if (budget.exhausted || ++visits > MAX_NODES) { budget.exhausted = true; return undefined; }
    if (depth > MAX_DEPTH) return undefined;
    if (typeof value === "string") return copyString(value);
    if (value === null || typeof value === "boolean" || typeof value === "number") return value;
    // Preserve invalid scalar presence, notably an invalid optional row-header index.
    if (kind === "scalar" && value !== undefined) return null;
    if (typeof value !== "object" || path.has(value)) return undefined;
    path.add(value);
    try {
      if (Object.hasOwn(arrayLimits, kind)) {
        if (!array(value)) return undefined;
        const limit = arrayLimits[kind as keyof typeof arrayLimits];
        const length = own(value, "length", false);
        if (typeof length !== "number" || !Number.isSafeInteger(length) || length < 0) return undefined;
        const childKind: CopyKind = kind === "rows" ? "row" : kind === "series" ? "seriesEntry" : kind === "segments" ? "segment" : "scalar";
        const result: unknown[] = [];
        for (let i = 0; i < Math.min(length, limit + 1) && !budget.exhausted; i++) {
          const entry = own(value, String(i));
          // Lookahead counts only: never traverse the overflow entry.
          result.push(i === limit ? undefined : copy(entry, childKind, depth + 1));
        }
        return result;
      }
      if (!record(value)) return undefined;
      const result: Record<string, unknown> = {};
      let fields: [string, CopyKind][] = kind === "seriesEntry" ? [["name", "scalar"], ["values", "values"]]
        : kind === "segment" ? [["label", "scalar"], ["value", "scalar"]] : [["type", "scalar"]];
      if (kind === "block") {
        result.type = copyString(own(value, "type")).toLowerCase();
        if (result.type === "chart") result.chartType = copyString(own(value, "chartType")).toLowerCase();
        fields = result.type === "text" || result.type === "context" ? [["text", "scalar"]]
          : result.type === "table" ? [["caption", "scalar"], ["headers", "headers"], ["rows", "rows"], ["rowHeaderColumnIndex", "scalar"]]
          : result.type === "chart" ? [["title", "scalar"], ...(result.chartType === "pie"
            ? [["segments", "segments"]] as [string, CopyKind][]
            : ["bar", "line", "area"].includes(String(result.chartType))
              ? [["categories", "categories"], ["series", "series"], ["xLabel", "scalar"], ["yLabel", "scalar"]] as [string, CopyKind][] : [])] : [];
      }
      for (const [key, childKind] of fields) {
        if (budget.exhausted) break;
        const copied = copy(own(value, key), childKind, depth + 1);
        if (copied !== undefined) result[key] = copied;
      }
      return result;
    } finally { path.delete(value); }
  }
  return { copy: (raw: unknown) => record(copy(raw, "block", 1)), string: copyString, exhausted: () => budget.exhausted };
}

function overflow(b: Record<string, unknown>): string | undefined {
  const count = (value: unknown, limit: number, unit: string): string | undefined =>
    array(value) && value.length > limit ? `${limit + 1}+ ${unit}` : undefined;
  if (b.type === "table") {
    return count(b.rows, MAX_TABLE_ROWS, "rows") ?? count(b.headers, MAX_TABLE_COLUMNS, "columns") ??
      (array(b.rows) ? b.rows.map((row: unknown) => count(row, MAX_TABLE_COLUMNS, "columns")).find(Boolean) : undefined);
  }
  if (b.type === "chart") {
    return count(b.segments, MAX_CHART_SEGMENTS, "segments") ?? count(b.categories, MAX_CHART_CATEGORIES, "categories") ??
      count(b.series, MAX_CHART_SERIES, "series") ?? (array(b.series)
        ? b.series.map((s: unknown) => count(record(s)?.values, MAX_CHART_CATEGORIES, "values")).find(Boolean) : undefined);
  }
  return undefined;
}

// This summary uses only preflight primitives; never SDK renderers or object coercion.
function omitted(b: Record<string, unknown>, reason: string): Block {
  const primitive = (v: unknown): string => typeof v === "string" ? string(v, 160) : finite(v) ? String(v) : "";
  const lines = [optional(b.caption) || optional(b.title) || optional(b.text)];
  if (array(b.rows)) for (const row of b.rows.slice(0, 3)) {
    if (array(row)) lines.push(row.slice(0, 4).map(primitive).filter(Boolean).join(", "));
  }
  if (array(b.segments)) for (const entry of b.segments.slice(0, 3)) {
    const s = record(entry);
    if (s) lines.push([primitive(s.label), primitive(s.value)].filter(Boolean).join(": "));
  }
  if (array(b.series)) for (const entry of b.series.slice(0, 3)) {
    const s = record(entry);
    if (s) lines.push([primitive(s.name), array(s.values) ? s.values.slice(0, 4).map(primitive).filter(Boolean).join(", ") : ""].filter(Boolean).join(": "));
  }
  // Keep the explicit omission note even when the title consumes its whole cap.
  return context([string(lines.filter(Boolean).join("\n"), MAX_STRING_CHARS - reason.length - 3), `(${reason})`].filter(Boolean).join("\n"));
}

function labels(raw: unknown): raw is string[] {
  return array(raw) && raw.length > 0 && raw.every((v: unknown) => typeof v === "string" && v.trim().length > 0) &&
    new Set(raw.map((v: unknown) => typeof v === "string" ? v.trim() : "")).size === raw.length;
}

// Rebuild SDK output through the same allowlist, then validate before native rendering.
function native(b: Record<string, unknown>): NativeBlock | undefined {
  const type = optional(b.type).toLowerCase();
  if (type === "text" || type === "context") {
    const text = optional(b.text);
    return text ? { type, text } : undefined;
  }
  if (type === "divider") return { type };
  if (type === "table") {
    const caption = optional(b.caption);
    if (!caption || !labels(b.headers) || !array(b.rows) || !b.rows.length) return;
    const headers = b.headers.map(optional);
    const rows: Cell[][] = [];
    for (const row of b.rows as unknown[]) {
      if (!array(row) || row.length !== headers.length) return;
      const cells: Cell[] = [];
      for (const v of row as unknown[]) {
        if (finite(v)) cells.push(v);
        else if (typeof v === "string" && optional(v)) cells.push(optional(v));
        else return;
      }
      rows.push(cells);
    }
    const index = b.rowHeaderColumnIndex;
    if (index !== undefined && (!finite(index) || !Number.isInteger(index) || index < 0 || index >= headers.length)) return;
    return { type, caption, headers, rows, ...(typeof index === "number" ? { rowHeaderColumnIndex: index } : {}) };
  }
  if (type !== "chart") return;
  const title = optional(b.title);
  const chartType = optional(b.chartType).toLowerCase();
  if (!title) return;
  if (chartType === "pie") {
    if (!array(b.segments) || !b.segments.length) return;
    const segments: { label: string; value: number }[] = [];
    for (const entry of b.segments as unknown[]) {
      const s = record(entry);
      if (!s || !optional(s.label) || !finite(s.value) || s.value <= 0) return;
      segments.push({ label: optional(s.label), value: s.value });
    }
    return { type, chartType, title, segments };
  }
  if (!["bar", "line", "area"].includes(chartType) || !labels(b.categories) || !array(b.series) || !b.series.length) return;
  const categories = b.categories.map(optional);
  const series: { name: string; values: number[] }[] = [];
  for (const entry of b.series as unknown[]) {
    const s = record(entry);
    if (!s || !optional(s.name) || !array(s.values) || s.values.length !== categories.length || !s.values.every(finite)) return;
    series.push({ name: optional(s.name), values: s.values as number[] });
  }
  if (new Set(series.map((s) => s.name)).size !== series.length) return;
  const xLabel = optional(b.xLabel), yLabel = optional(b.yLabel);
  return { type, chartType: chartType as "bar" | "line" | "area", title, categories, series,
    ...(xLabel ? { xLabel } : {}), ...(yLabel ? { yLabel } : {}) };
}

function fallback(parts: string[]): string {
  const marker = "…(truncated)";
  let result = "";
  let size = 0;
  for (const part of parts.filter(Boolean)) {
    for (const point of (result ? "\n\n" : "") + part) {
      const n = Buffer.byteLength(point);
      if (size + n > MAX_FALLBACK_BYTES - Buffer.byteLength(marker)) return result + marker;
      result += point;
      size += n;
    }
  }
  return result;
}

export function sanitizePresentation(raw: unknown, sdk: PresentationSdk): { presentation?: Presentation; fallbackText: string } {
  if (typeof raw === "string") {
    if (raw.length > MAX_PRESENTATION_BYTES || Buffer.byteLength(raw, "utf8") > MAX_PRESENTATION_BYTES) return { fallbackText: "" };
    try { raw = JSON.parse(raw) as unknown; } catch { return { fallbackText: "" }; }
  }
  const root = record(raw);
  if (!root) return { fallbackText: "" };
  const budget = { chars: 0, exhausted: false };
  const checked = preflight(budget);
  const normalizedCopy = preflight(budget);
  const title = checked.string(own(root, "title"));
  const t = checked.string(own(root, "tone")).toLowerCase();
  const presentation: Presentation = { ...(title ? { title } : {}), ...(tone(t) ? { tone: t } : {}), blocks: [] };
  let size = bytes(presentation);
  const input = own(root, "blocks");
  const length = array(input) ? own(input, "length", false) : undefined;
  if (!array(input) || typeof length !== "number" || !Number.isSafeInteger(length) || length < 0) return { fallbackText: fallback([title]) };
  const blocks = presentation.blocks;
  const more = (count: number): void => {
    let note = context(`(${count}+ more blocks omitted)`);
    while (blocks.length && (blocks.length >= MAX_BLOCKS || size + bytes(note) + 1 > MAX_PRESENTATION_BYTES)) {
      const last = blocks.pop();
      size -= bytes(last) + (blocks.length ? 1 : 0);
      note = context(`(${++count}+ more blocks omitted)`);
    }
    blocks.push(note);
  };
  for (let i = 0; i < Math.min(length, MAX_BLOCKS + 1); i++) {
    const entry = own(input, String(i));
    if (i === MAX_BLOCKS) { more(1); break; }
    const b = checked.copy(entry);
    if (!b || !["text", "context", "divider", "table", "chart"].includes(String(b.type))) continue;
    const over = overflow(b);
    let block: Block;
    const reason = over ? `${b.type} truncated: ${over}` : `${b.type} omitted: invalid data`;
    if (over || checked.exhausted()) block = omitted(b, checked.exhausted() ? `${b.type} omitted: resource limit` : reason);
    else {
      try {
        const normalized = record(sdk.normalize({ blocks: [b] }));
        const list = normalized && own(normalized, "blocks");
        const copy = array(list) && normalizedCopy.copy(own(list, "0"));
        const clean = copy && !overflow(copy) && !normalizedCopy.exhausted() ? native(copy) : undefined;
        if (!clean) block = omitted(b, normalizedCopy.exhausted() ? `${b.type} omitted: resource limit` : reason);
        else {
          const alt = clean.type === "table" ? string(sdk.tableAlt(clean)) : clean.type === "chart" ? string(sdk.chartAlt(clean))
            : clean.type === "divider" ? "" : clean.text;
          block = { ...clean, alt };
        }
      } catch { block = omitted(b, reason); }
    }
    const cost = bytes(block) + (blocks.length ? 1 : 0);
    if (size + cost > MAX_PRESENTATION_BYTES) { more(Math.min(length, MAX_BLOCKS + 1) - i); break; }
    blocks.push(block);
    size += cost;
    if (checked.exhausted()) { if (i + 1 < length) more(Math.min(length, MAX_BLOCKS + 1) - i - 1); break; }
  }
  const fallbackText = fallback([title, ...blocks.map((b) => b.alt)]);
  return blocks.length ? { presentation, fallbackText } : { fallbackText };
}
