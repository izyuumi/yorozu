import { appendFileSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { env } from "node:process";
import type { YorozuEvent } from "@yorozu/shared";
import { afterEach, beforeEach, expect, test } from "vitest";
import {
  appendTranscript,
  readTranscripts,
  readTranscriptsTool,
  transcriptDir,
} from "./transcripts.js";

let dir: string;
let previousStateDir: string | undefined;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-transcripts-"));
  previousStateDir = env.YOROZU_STATE_DIR;
  env.YOROZU_STATE_DIR = dir;
});

afterEach(() => {
  if (previousStateDir === undefined) delete env.YOROZU_STATE_DIR;
  else env.YOROZU_STATE_DIR = previousStateDir;
  rmSync(dir, { recursive: true, force: true });
});

const at = (iso: string) => Date.parse(iso);

const message = (iso: string, text: string): YorozuEvent => ({
  id: `e-${iso}`,
  threadId: "home",
  ts: at(iso),
  agentId: "main",
  kind: "message",
  data: { role: "user", text },
});

test("events round-trip through one JSONL file per day", () => {
  const logs = transcriptDir(dir);
  expect(logs).toBe(join(dir, "transcripts"));

  appendTranscript(message("2026-09-12T00:10:00Z", "today"), logs);
  appendTranscript(message("2026-09-11T23:50:00Z", "yesterday"), logs);

  expect(readdirSync(logs).sort()).toEqual(["2026-09-11.jsonl", "2026-09-12.jsonl"]);

  const all = readTranscripts(new Date(at("2026-09-11T00:00:00Z")), logs);
  expect(all.map((e) => e.kind === "message" && e.data.text)).toEqual(["yesterday", "today"]);
  expect(all[1]).toEqual(message("2026-09-12T00:10:00Z", "today"));

  // `since` filters within a day as well as across days.
  expect(
    readTranscripts(new Date(at("2026-09-12T00:00:00Z")), logs).map((e) => e.id),
  ).toEqual(["e-2026-09-12T00:10:00Z"]);
  expect(readTranscripts(new Date(at("2026-09-13T00:00:00Z")), logs)).toEqual([]);
});

test("a missing directory and a half-written line read as nothing lost", () => {
  expect(readTranscripts(new Date(0), join(dir, "never-written"))).toEqual([]);

  const logs = transcriptDir(dir);
  appendTranscript(message("2026-09-12T09:00:00Z", "first"), logs);
  appendFileSync(join(logs, "2026-09-12.jsonl"), '{"id":"broken"\n');
  appendTranscript(message("2026-09-12T09:01:00Z", "second"), logs);

  expect(readTranscripts(new Date(0), logs).map((e) => e.id)).toEqual([
    "e-2026-09-12T09:00:00Z",
    "e-2026-09-12T09:01:00Z",
  ]);
});

test("the read_transcripts tool reads a window of the state dir's log", () => {
  const logs = transcriptDir(dir);
  const now = Date.now();
  appendTranscript({ ...message("2026-09-12T09:00:00Z", "recent"), ts: now - 3_600_000 }, logs);
  appendTranscript({ ...message("2026-09-12T09:00:00Z", "old"), ts: now - 72 * 3_600_000 }, logs);

  const window = readTranscriptsTool.run({});
  expect(window).toContain("[home] user: recent");
  expect(window).not.toContain("user: old");

  expect(readTranscriptsTool.run({ hours: 96 })).toContain("user: old");
  // Nonsense from the model falls back to the 24h default rather than reading nothing.
  expect(readTranscriptsTool.run({ hours: "lots" })).toContain("user: recent");
  expect(readTranscriptsTool.run({ hours: 0.0001 })).toBe("no transcripts in that window");
});
