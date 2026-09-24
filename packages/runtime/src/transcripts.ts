/**
 * Append-only event log, one JSONL file per UTC day in `<state dir>/transcripts`.
 * The nightly consolidation job reads it back to promote durable facts into memory.
 * See docs/spec-v1.html section 5.
 */

import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import type { YorozuEvent } from "@yorozu/shared";
import type { Tool } from "./index.js";
import { stateDir } from "./memory.js";

/** How much of the log one `read_transcripts` call may hand the model. */
const MAX_EVENTS = 200;

export function transcriptDir(dir = stateDir()): string {
  return join(dir, "transcripts");
}

const day = (ts: number): string => new Date(ts).toISOString().slice(0, 10);

export function appendTranscript(event: YorozuEvent, dir = transcriptDir()): void {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  appendFileSync(join(dir, `${day(event.ts)}.jsonl`), `${JSON.stringify(event)}\n`, { mode: 0o600 });
}

/** Every logged event at or after `since`, oldest first. Unreadable lines are skipped. */
export function readTranscripts(since: Date, dir = transcriptDir()): YorozuEvent[] {
  if (!existsSync(dir)) return [];
  const from = day(since.getTime());
  const events: YorozuEvent[] = [];
  for (const name of readdirSync(dir).sort()) {
    // File names are dates, so a lexical compare skips whole days that are too old.
    if (!name.endsWith(".jsonl") || name.slice(0, 10) < from) continue;
    for (const line of readFileSync(join(dir, name), "utf8").split("\n")) {
      if (!line.trim()) continue;
      try {
        const event = JSON.parse(line) as YorozuEvent;
        if (event.ts >= since.getTime()) events.push(event);
      } catch {
        // A half-written last line must not lose the rest of the day.
      }
    }
  }
  return events.sort((a, b) => a.ts - b.ts);
}

/** One readable line per event; message text is what consolidation actually needs. */
export const formatTranscript = (events: YorozuEvent[]): string =>
  events
    .map((event) => {
      const text = event.kind === "message" ? `${event.data.role}: ${event.data.text}` : event.kind;
      return `${new Date(event.ts).toISOString()} [${event.threadId}] ${text}`;
    })
    .join("\n");

export const readTranscriptsTool: Tool = {
  name: "read_transcripts",
  description:
    "Read the recent conversation log across all threads, oldest first. Used to find facts worth remembering.",
  parameters: {
    type: "object",
    properties: {
      hours: { type: "number", description: "How far back to read. Defaults to 24." },
    },
    required: [],
  },
  run: ({ hours }) => {
    const back = Number(hours);
    const since = new Date(Date.now() - (Number.isFinite(back) && back > 0 ? back : 24) * 3_600_000);
    const events = readTranscripts(since).slice(-MAX_EVENTS);
    return events.length ? formatTranscript(events) : "no transcripts in that window";
  },
};
