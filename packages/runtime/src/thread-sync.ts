/** Byte offsets let sync pages seek into JSONL without retaining message/attachment bodies. */
import { closeSync, fstatSync, openSync, readSync } from "node:fs";
import type { YorozuEvent } from "@yorozu/shared";

interface Index { stamp: string; after: Map<string, number> }
// ponytail: retain metadata for 16 recently synced logs; use a disk index if many active
// threads or millions of event ids make rebuilding/metadata memory significant.
const indexes = new Map<string, Index>();

/** Decode only complete lines, including UTF-8 characters split across read boundaries. */
function* lines(fd: number, start: number, size: number): Generator<{ text: string; end: number }> {
  const chunk = Buffer.allocUnsafe(64 * 1024);
  let pieces: Buffer[] = [];
  let position = start;
  while (position < size) {
    const count = readSync(fd, chunk, 0, Math.min(chunk.length, size - position), position);
    if (!count) break;
    let from = 0;
    for (let at = 0; at < count; at++) {
      if (chunk[at] !== 10) continue;
      const part = chunk.subarray(from, at);
      const text = pieces.length ? Buffer.concat([...pieces, part]).toString("utf8") : part.toString("utf8");
      pieces = [];
      yield { text, end: position + at + 1 };
      from = at + 1;
    }
    if (from < count) pieces.push(Buffer.from(chunk.subarray(from, count)));
    position += count;
  }
  if (pieces.length) yield { text: Buffer.concat(pieces).toString("utf8"), end: position };
}

function parse(text: string): YorozuEvent | undefined {
  try {
    const event = JSON.parse(text) as YorozuEvent;
    return event && typeof event.id === "string" && typeof event.ts === "number" ? event : undefined;
  } catch { return undefined; }
}

export function syncPage(file: string, afterId: string | undefined, minTs: number, limit: number): YorozuEvent[] {
  let fd: number;
  try { fd = openSync(file, "r"); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") { indexes.delete(file); return []; }
    throw error;
  }
  try {
    const stat = fstatSync(fd, { bigint: true });
    const stamp = `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeNs}:${stat.ctimeNs}`;
    let index = indexes.get(file);
    if (index?.stamp !== stamp) {
      index = { stamp, after: new Map() };
      // Last occurrence wins: progress cards legitimately reuse their event id.
      for (const line of lines(fd, 0, Number(stat.size))) {
        const event = parse(line.text);
        if (event) index.after.set(event.id, line.end);
      }
    }
    indexes.delete(file);
    indexes.set(file, index);
    if (indexes.size > 16) indexes.delete(indexes.keys().next().value!);
    const page: YorozuEvent[] = [];
    const start = afterId ? index.after.get(afterId) ?? 0 : 0;
    for (const line of lines(fd, start, Number(stat.size))) {
      const event = parse(line.text);
      if (!event || event.ts < minTs) continue;
      page.push(event);
      if (page.length === limit) break;
    }
    return page;
  } finally { closeSync(fd); }
}
