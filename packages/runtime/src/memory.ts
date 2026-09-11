/**
 * Durable facts as plain markdown. The files are the truth: user-editable,
 * Obsidian-openable, git-able. The SQLite index is derived and rebuilt from
 * them whenever it is missing or stale. See docs/spec-v1.html section 5.
 */

import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { env } from "node:process";
import { DatabaseSync } from "node:sqlite";
import type { Tool } from "./index.js";

export const MEMORY_KINDS = [
  "preference",
  "decision",
  "correction",
  "fact",
  "approval",
] as const;

export type MemoryKind = (typeof MEMORY_KINDS)[number];

export interface Fact {
  /** File name inside the memory directory; the fact's stable ID. */
  path: string;
  kind: MemoryKind;
  body: string;
  /** ISO 8601. */
  created: string;
  threadId: string;
  agentId: string;
}

/** Where a fact came from. Every fact carries date and thread provenance. */
export interface Provenance {
  threadId?: string;
  agentId?: string;
  /** Injectable for tests. */
  now?: Date;
}

export interface SearchOptions {
  limit?: number;
}

/** Dot-prefixed so the derived index does not show up as a note. */
const INDEX_FILE = ".index.sqlite";

const DEFAULT_LIMIT = 5;

export function stateDir(): string {
  return (
    env.YOROZU_STATE_DIR ?? join(homedir(), "Library", "Application Support", "Yorozu")
  );
}

export function memoryDir(): string {
  return env.YOROZU_MEMORY_DIR ?? join(stateDir(), "memory");
}

function serialize(fact: Fact): string {
  return [
    "---",
    `kind: ${fact.kind}`,
    `created: ${fact.created}`,
    `threadId: ${fact.threadId}`,
    `agentId: ${fact.agentId}`,
    "---",
    "",
    fact.body,
    "",
  ].join("\n");
}

/** Tolerant of hand-edited files: unknown keys are ignored, missing ones default. */
function parse(path: string, text: string): Fact {
  const head = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text);
  const fields = new Map<string, string>();
  for (const line of head?.[1]?.split(/\r?\n/) ?? []) {
    const colon = line.indexOf(":");
    if (colon > 0) fields.set(line.slice(0, colon).trim(), line.slice(colon + 1).trim());
  }
  const kind = fields.get("kind") as MemoryKind;
  return {
    path,
    kind: MEMORY_KINDS.includes(kind) ? kind : "fact",
    body: text.slice(head?.[0]?.length ?? 0).trim(),
    created: fields.get("created") ?? "",
    threadId: fields.get("threadId") ?? "",
    agentId: fields.get("agentId") ?? "",
  };
}

export interface Memory {
  /** Absolute path of the memory directory this instance indexes. */
  dir: string;
  remember(fact: string, kind: MemoryKind, provenance?: Provenance): Fact;
  /** Ranked by FTS5 bm25, best first. */
  search(query: string, options?: SearchOptions): Fact[];
  searchByEmbedding(query: string, options?: SearchOptions): Fact[];
  recallForPrompt(query: string, limit?: number): string;
  rebuild(): void;
  close(): void;
}

export function openMemory(dir = memoryDir()): Memory {
  mkdirSync(dir, { recursive: true });
  const db = new DatabaseSync(join(dir, INDEX_FILE));
  db.exec(`
    create table if not exists facts(
      path text primary key,
      kind text not null,
      body text not null,
      created text not null,
      threadId text not null,
      agentId text not null,
      mtimeMs real not null
    );
    create virtual table if not exists facts_fts using fts5(
      body, kind, content='facts', content_rowid='rowid'
    );
  `);

  const insertFact = db.prepare(
    `insert into facts(path, kind, body, created, threadId, agentId, mtimeMs)
     values(?, ?, ?, ?, ?, ?, ?)`,
  );
  // Reading the row back keeps the FTS rowid aligned with the content table.
  const insertFts = db.prepare(
    "insert into facts_fts(rowid, body, kind) select rowid, body, kind from facts where path = ?",
  );
  const matchFacts = db.prepare(
    `select f.path, f.kind, f.body, f.created, f.threadId, f.agentId
       from facts_fts join facts f on f.rowid = facts_fts.rowid
      where facts_fts match ?
      order by bm25(facts_fts)
      limit ?`,
  );
  const allIndexed = db.prepare("select path, mtimeMs from facts");

  function index(fact: Fact, mtimeMs: number): void {
    insertFact.run(
      fact.path,
      fact.kind,
      fact.body,
      fact.created,
      fact.threadId,
      fact.agentId,
      mtimeMs,
    );
    insertFts.run(fact.path);
  }

  /** File name -> mtime for every note in the directory. */
  function notes(): Map<string, number> {
    const found = new Map<string, number>();
    for (const name of readdirSync(dir)) {
      if (name.endsWith(".md")) found.set(name, statSync(join(dir, name)).mtimeMs);
    }
    return found;
  }

  function rebuild(): void {
    db.exec("delete from facts");
    db.exec("insert into facts_fts(facts_fts) values('delete-all')");
    for (const [name, mtimeMs] of notes()) {
      index(parse(name, readFileSync(join(dir, name), "utf8")), mtimeMs);
    }
  }

  /** The index is derived: any note added, removed or touched behind our back wins. */
  function stale(): boolean {
    const disk = notes();
    const indexed = allIndexed.all() as unknown as { path: string; mtimeMs: number }[];
    return (
      indexed.length !== disk.size ||
      indexed.some((row) => disk.get(row.path) !== row.mtimeMs)
    );
  }

  function fileName(created: string, body: string): string {
    const slug =
      body
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-|-$/g, "")
        .split("-")
        .slice(0, 6)
        .join("-") || "fact";
    const stem = `${created.slice(0, 10)}-${slug}`;
    for (let n = 1; ; n++) {
      const name = n === 1 ? `${stem}.md` : `${stem}-${n}.md`;
      if (!existsSync(join(dir, name))) return name;
    }
  }

  function search(query: string, options: SearchOptions = {}): Fact[] {
    // Quote each term and OR them: recall should degrade to the best partial
    // match rather than to nothing, and quoting keeps FTS5 operators out of
    // whatever the model or user typed.
    const terms = query.match(/[\p{L}\p{N}]+/gu) ?? [];
    if (!terms.length) return [];
    return matchFacts.all(
      terms.map((term) => `"${term}"`).join(" OR "),
      options.limit ?? DEFAULT_LIMIT,
    ) as unknown as Fact[];
  }

  function recallForPrompt(query: string, limit = DEFAULT_LIMIT): string {
    const facts = search(query, { limit });
    if (!facts.length) return "";
    return [
      "Recalled from memory (may be relevant):",
      ...facts.map((f) => `- (${f.kind}) ${f.body}`),
    ].join("\n");
  }

  if (stale()) rebuild();

  return {
    dir,
    rebuild,
    search,
    recallForPrompt,

    remember(fact, kind, provenance = {}) {
      const body = fact.trim();
      if (!body) throw new Error("remember: fact is empty");
      const created = (provenance.now ?? new Date()).toISOString();
      const record: Fact = {
        path: fileName(created, body),
        kind,
        body,
        created,
        threadId: provenance.threadId ?? "",
        agentId: provenance.agentId ?? "",
      };
      const file = join(dir, record.path);
      writeFileSync(file, serialize(record));
      index(record, statSync(file).mtimeMs);
      return record;
    },

    /**
     * Stub: there is no vector index yet. A later ticket plugs in sqlite-vec or
     * provider embeddings behind this exact shape; until then it returns [] so
     * callers can already blend it with `search`.
     */
    searchByEmbedding(_query, _options = {}) {
      return [];
    },

    close: () => db.close(),
  };
}

let shared: Memory | undefined;

/** Process-wide instance for the `remember` tool. Reopens if the directory changes. */
export function defaultMemory(): Memory {
  if (shared?.dir !== memoryDir()) shared = openMemory();
  return shared;
}

/** Compact block to prepend to a system prompt. Empty when nothing matches. */
export const recallForPrompt = (query: string, limit?: number): string =>
  defaultMemory().recallForPrompt(query, limit);

export const rememberTool: Tool = {
  name: "remember",
  description:
    "Store a durable fact about the user so that later threads can recall it.",
  parameters: {
    type: "object",
    properties: {
      fact: { type: "string", description: "The fact, in one sentence." },
      kind: { type: "string", enum: [...MEMORY_KINDS] },
    },
    required: ["fact", "kind"],
  },
  run: ({ fact, kind }) => {
    // Model output: anything unrecognised is filed as a plain fact.
    const k = kind as MemoryKind;
    const record = defaultMemory().remember(
      String(fact ?? ""),
      MEMORY_KINDS.includes(k) ? k : "fact",
    );
    return `remembered: ${record.path}`;
  },
};
