import { Buffer } from "node:buffer";

export const MAX_STRING_CHARS = 4000;
export const MAX_BLOCKS = 50;
export const MAX_TABLE_COLUMNS = 20;
export const MAX_TABLE_ROWS = 200;
export const MAX_CHART_SERIES = 12;
export const MAX_CHART_CATEGORIES = 100;
export const MAX_PRESENTATION_BYTES = 65536;

export type Tone = "info" | "success" | "warning" | "danger" | "neutral";
export type ChartType = "bar" | "area" | "line" | "pie";
type Cell = string | number | boolean | null;
export type TableBlock = {
  type: "table"; caption?: string; headers: string[]; rows: Cell[][]; rowHeaderColumnIndex?: number;
};
export type ChartBlock = {
  type: "chart"; chartType: ChartType; title: string; categories: string[];
  series: { name: string; values: (number | null)[] }[];
};
export type Block = (TableBlock | ChartBlock | { type: "text" | "context"; text: string } | { type: "divider" }) & { alt: string };
export type Presentation = { title?: string; tone?: Tone; blocks: Block[] };
export type PresentationSdk = {
  normalize(raw: unknown): unknown;
  tableAlt(block: TableBlock): string;
  chartAlt(block: ChartBlock): string;
};

const record = (raw: unknown): Record<string, unknown> | undefined =>
  typeof raw === "object" && raw !== null && !Array.isArray(raw) ? raw as Record<string, unknown> : undefined;
const own = (raw: Record<string, unknown>, key: string): unknown => Object.hasOwn(raw, key) ? raw[key] : undefined;
const string = (raw: unknown): string => typeof raw === "string" ? raw.slice(0, MAX_STRING_CHARS) : "";
const cell = (raw: unknown): raw is Cell => raw === null || typeof raw === "string" || typeof raw === "boolean" ||
  (typeof raw === "number" && Number.isFinite(raw));
const finite = (raw: unknown): raw is number | null => raw === null || (typeof raw === "number" && Number.isFinite(raw));
const context = (text: string): Block | undefined => text.trim() ? { type: "context", text, alt: text } : undefined;
const tone = (raw: unknown): raw is Tone => typeof raw === "string" && ["info", "success", "warning", "danger", "neutral"].includes(raw);
const chartType = (raw: unknown): raw is ChartType => typeof raw === "string" && ["bar", "area", "line", "pie"].includes(raw);

function sanitizeBlock(raw: unknown, sdk: PresentationSdk): Block | undefined {
  const b = record(raw);
  if (!b) return undefined;
  const type = own(b, "type");
  if (type === "text" || type === "context") {
    const text = string(own(b, "text"));
    return text.trim() ? { type, text, alt: text } : undefined;
  }
  // Dividers need an audible, non-empty fallback even without SDK text.
  if (type === "divider") return { type, alt: "—" };
  if (type === "table") {
    const headers = own(b, "headers");
    const rows = own(b, "rows");
    const caption = string(own(b, "caption"));
    if (!Array.isArray(headers) || !Array.isArray(rows)) return context(caption);
    let valid = Array.from(headers as unknown[]).every((h: unknown) => typeof h === "string");
    const table: TableBlock = { type, headers: Array.from(headers as unknown[]).map((h: unknown) => string(h)), rows: [] };
    if (caption) table.caption = caption;
    for (const row of Array.from(rows as unknown[])) {
      if (!Array.isArray(row)) { valid = false; continue; }
      table.rows.push(Array.from(row as unknown[]).map((v) => {
        if (!cell(v)) { valid = false; return null; }
        return typeof v === "string" ? string(v) : v;
      }));
    }
    const index = own(b, "rowHeaderColumnIndex");
    if (typeof index === "number" && Number.isInteger(index) && index >= 0 && index < table.headers.length) {
      table.rowHeaderColumnIndex = index;
    }
    const alt = string(sdk.tableAlt(table)) || caption || "Table";
    if (!valid || headers.length > MAX_TABLE_COLUMNS || rows.length > MAX_TABLE_ROWS ||
      table.rows.some((row) => row.length > MAX_TABLE_COLUMNS)) return context(alt);
    return { type, ...(caption ? { caption } : {}), headers: table.headers, rows: table.rows,
      ...(table.rowHeaderColumnIndex !== undefined ? { rowHeaderColumnIndex: table.rowHeaderColumnIndex } : {}), alt };
  }
  if (type === "chart") {
    const kind = own(b, "chartType");
    const title = string(own(b, "title"));
    const categories = own(b, "categories");
    const series = own(b, "series");
    if (!chartType(kind) || !title || !Array.isArray(categories) || !Array.isArray(series)) return context(title);
    let valid = Array.from(categories as unknown[]).every((c: unknown) => typeof c === "string");
    const chart: ChartBlock = { type, chartType: kind, title, categories: Array.from(categories as unknown[]).map((c: unknown) => string(c)), series: [] };
    for (const entry of Array.from(series as unknown[])) {
      const s = record(entry);
      const values = s && own(s, "values");
      if (!s || !Array.isArray(values) || typeof own(s, "name") !== "string") { valid = false; continue; }
      chart.series.push({ name: string(own(s, "name")), values: Array.from(values as unknown[]).map((v) => {
        if (!finite(v)) { valid = false; return null; }
        return v;
      }) });
    }
    const alt = string(sdk.chartAlt(chart)) || title;
    if (!valid || series.length > MAX_CHART_SERIES || categories.length > MAX_CHART_CATEGORIES ||
      chart.series.some((s) => s.values.length !== chart.categories.length)) return context(alt);
    return { type, chartType: kind, title, categories: chart.categories, series: chart.series, alt };
  }
  return undefined;
}

function availableText(raw: unknown): string {
  const b = record(raw);
  if (!b) return "";
  const type = own(b, "type");
  if (type === "text" || type === "context") return string(own(b, "text"));
  if (type === "table") return string(own(b, "caption")) || "Table";
  if (type === "chart") return string(own(b, "title")) || "Chart";
  return type === "divider" ? "—" : "";
}

function availableFallback(raw: unknown): string {
  const fallback: string[] = [];
  try {
    const p = record(raw);
    if (!p) return "";
    const title = string(own(p, "title"));
    if (title.trim()) fallback.push(title);
    const blocks = own(p, "blocks");
    if (Array.isArray(blocks)) {
      for (let i = 0; i < Math.min(blocks.length, MAX_BLOCKS); i++) {
        try {
          const text = availableText(blocks[i]);
          if (text.trim()) fallback.push(text);
        } catch { /* Untrusted accessors may throw. */ }
      }
    }
  } catch { /* Untrusted accessors may throw. */ }
  return fallback.join("\n\n");
}

export function sanitizePresentation(raw: unknown, sdk: PresentationSdk): { presentation?: Presentation; fallbackText: string } {
  const fallback: string[] = [];
  try {
    const p = record(sdk.normalize(raw));
    if (!p) return { fallbackText: availableFallback(raw) };
    const title = string(own(p, "title"));
    if (title.trim()) fallback.push(title);
    const blocks: Block[] = [];
    let invalid = false;
    const input = own(p, "blocks");
    if (Array.isArray(input)) {
      for (let i = 0; i < Math.min(input.length, MAX_BLOCKS); i++) {
        try {
          const block = sanitizeBlock(input[i], sdk);
          if (block) {
            blocks.push(block);
            if (block.alt.trim()) fallback.push(block.alt);
          }
        } catch {
          invalid = true;
          try {
            const text = availableText(input[i]);
            if (text.trim()) fallback.push(text);
          } catch { /* Untrusted accessors may throw. */ }
        }
      }
    }
    const presentation: Presentation = { blocks };
    if (title) presentation.title = title;
    const t = own(p, "tone");
    if (typeof t === "string" && tone(t)) presentation.tone = t;
    const fallbackText = fallback.join("\n\n");
    if (invalid || !blocks.length || Buffer.byteLength(JSON.stringify(presentation), "utf8") > MAX_PRESENTATION_BYTES) {
      return { fallbackText };
    }
    return { presentation, fallbackText };
  } catch {
    return { fallbackText: fallback.join("\n\n") || availableFallback(raw) };
  }
}
