import { mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { env } from "node:process";
import { afterEach, beforeEach, expect, test } from "vitest";
import { defaultTools, runAgent } from "./index.js";
import { MEMORY_KINDS, openMemory, rememberTool, type Memory } from "./memory.js";
import type { Message, Provider } from "./provider.js";

let dir: string;
let memory: Memory;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-memory-"));
  memory = openMemory(dir);
});

afterEach(() => {
  memory.close();
  rmSync(dir, { recursive: true, force: true });
});

/** Writes a note behind the index's back, with an mtime the index cannot have seen. */
function writeNote(name: string, kind: string, body: string): void {
  const file = join(dir, name);
  writeFileSync(
    file,
    `---\nkind: ${kind}\ncreated: 2026-09-12T00:00:00.000Z\nthreadId: home\nagentId: main\n---\n\n${body}\n`,
  );
  const future = new Date(Date.now() + 5_000);
  utimesSync(file, future, future);
}

test("remember writes a markdown file with provenance", () => {
  const fact = memory.remember("user prefers dark mode", "preference", {
    threadId: "home",
    agentId: "main",
    now: new Date("2026-09-12T10:00:00.000Z"),
  });

  expect(fact.path).toBe("2026-09-12-user-prefers-dark-mode.md");
  expect(readFileSync(join(dir, fact.path), "utf8")).toBe(
    [
      "---",
      "kind: preference",
      "created: 2026-09-12T10:00:00.000Z",
      "threadId: home",
      "agentId: main",
      "---",
      "",
      "user prefers dark mode",
      "",
    ].join("\n"),
  );
  expect(memory.search("dark mode")).toEqual([fact]);
});

test("a second fact on the same day gets its own file", () => {
  const now = new Date("2026-09-12T10:00:00.000Z");
  expect(memory.remember("coffee before noon", "fact", { now }).path).toBe(
    "2026-09-12-coffee-before-noon.md",
  );
  expect(memory.remember("coffee before noon", "fact", { now }).path).toBe(
    "2026-09-12-coffee-before-noon-2.md",
  );
});

test("index rebuilds from files alone and ranks by bm25", () => {
  writeNote("a.md", "preference", "user prefers dark mode in the editor");
  writeNote("b.md", "fact", "user keeps dark chocolate in the kitchen");
  writeNote("c.md", "fact", "user lives in Kyoto");

  // A fresh instance has no index of its own: it must come back from the files.
  const rebuilt = openMemory(dir);
  try {
    expect(rebuilt.search("dark mode").map((f) => f.path)).toEqual(["a.md", "b.md"]);
    expect(rebuilt.search("Kyoto")).toEqual([
      {
        path: "c.md",
        kind: "fact",
        body: "user lives in Kyoto",
        created: "2026-09-12T00:00:00.000Z",
        threadId: "home",
        agentId: "main",
      },
    ]);
    expect(rebuilt.search("dark", { limit: 1 })).toHaveLength(1);
    expect(rebuilt.search("   ")).toEqual([]);
  } finally {
    rebuilt.close();
  }
});

test("a stale index is rebuilt: edits, additions and deletions on disk win", () => {
  const fact = memory.remember("user lives in Osaka", "fact");
  memory.close();

  writeNote(fact.path, "correction", "user lives in Kyoto");
  writeNote("extra.md", "fact", "user rides a bicycle");

  memory = openMemory(dir);
  expect(memory.search("Osaka")).toEqual([]);
  expect(memory.search("Kyoto").map((f) => f.kind)).toEqual(["correction"]);
  expect(memory.search("bicycle").map((f) => f.path)).toEqual(["extra.md"]);

  memory.close();
  rmSync(join(dir, "extra.md"));
  memory = openMemory(dir);
  expect(memory.search("bicycle")).toEqual([]);
});

test("vector search is a stub until embeddings land", () => {
  memory.remember("user lives in Kyoto", "fact");
  expect(memory.searchByEmbedding("Kyoto")).toEqual([]);
});

test("recallForPrompt is empty when nothing matches", () => {
  memory.remember("user lives in Kyoto", "fact");
  expect(memory.recallForPrompt("unrelated")).toBe("");
  expect(memory.recallForPrompt("Kyoto")).toBe(
    "Recalled from memory (may be relevant):\n- (fact) user lives in Kyoto",
  );
});

test("the remember tool writes through YOROZU_MEMORY_DIR", () => {
  const previous = env.YOROZU_MEMORY_DIR;
  env.YOROZU_MEMORY_DIR = dir;
  try {
    // index.test.ts pins the whole list; here it only matters that this tool is in it.
    expect(defaultTools.map((t) => t.name)).toContain("remember");
    expect(rememberTool.run({ fact: "user lives in Kyoto", kind: "bogus" })).toMatch(
      /^remembered: \d{4}-\d{2}-\d{2}-user-lives-in-kyoto\.md$/,
    );
    // Unknown kinds from the model are filed as plain facts.
    expect(openMemory(dir).search("Kyoto").map((f) => f.kind)).toEqual(["fact"]);
  } finally {
    if (previous === undefined) delete env.YOROZU_MEMORY_DIR;
    else env.YOROZU_MEMORY_DIR = previous;
  }
});

test("remember refuses a fact with nothing in it", () => {
  expect(() => memory.remember("   ", "fact")).toThrow("remember: fact is empty");

  const previous = env.YOROZU_MEMORY_DIR;
  env.YOROZU_MEMORY_DIR = dir;
  try {
    // The same refusal through the tool: the loop turns a throw into `error: …` for the model.
    expect(() => rememberTool.run({ fact: "  ", kind: "fact" })).toThrow("remember: fact is empty");
    expect(() => rememberTool.run({ kind: "fact" })).toThrow("remember: fact is empty");
  } finally {
    if (previous === undefined) delete env.YOROZU_MEMORY_DIR;
    else env.YOROZU_MEMORY_DIR = previous;
  }
});

test("a fact with no ascii in it still gets a file, and reads back intact", () => {
  const now = new Date("2026-09-12T10:00:00.000Z");

  // Nothing in the body can become a slug, so the name falls back rather than being empty.
  const japanese = memory.remember("ユーザーは京都に住んでいる", "fact", { now });
  expect(japanese.path).toBe("2026-09-12-fact.md");
  expect(readFileSync(join(dir, japanese.path), "utf8")).toContain("ユーザーは京都に住んでいる");

  // Mixed text tokenises on the spaces, so recall still reaches it.
  const mixed = memory.remember("user lives in 京都", "preference", { now });
  expect(mixed.path).toBe("2026-09-12-user-lives-in.md");
  expect(memory.search("京都")).toEqual([mixed]);
});

test("remember's schema names the fact and the kinds it will accept", () => {
  expect(rememberTool.name).toBe("remember");
  expect(rememberTool.parameters).toMatchObject({
    type: "object",
    required: ["fact", "kind"],
    properties: { kind: { enum: [...MEMORY_KINDS] } },
  });
});

test("remember is registered in the shared tool list, and a call by name reaches it", () => {
  const registered = defaultTools.find((tool) => tool.name === "remember");
  expect(registered).toBe(rememberTool);

  const previous = env.YOROZU_MEMORY_DIR;
  env.YOROZU_MEMORY_DIR = dir;
  try {
    expect(registered!.run({ fact: "user rides a bicycle", kind: "fact" })).toMatch(
      /^remembered: \d{4}-\d{2}-\d{2}-user-rides-a-bicycle\.md$/,
    );
    // The note is on disk, so the call went all the way through to the implementation.
    expect(memory.search("bicycle").map((f) => f.body)).toEqual(["user rides a bicycle"]);
  } finally {
    if (previous === undefined) delete env.YOROZU_MEMORY_DIR;
    else env.YOROZU_MEMORY_DIR = previous;
  }
});

test("runAgent prepends recall for the latest user message", async () => {
  memory.remember("user lives in Kyoto", "fact");
  const seen: Message[][] = [];
  const provider: Provider = {
    auth: async () => ({ ok: true }),
    async *stream(messages) {
      seen.push(messages);
      yield { type: "text", text: "ok" };
      yield { type: "done" };
    },
  };
  const messages: Message[] = [
    { role: "user", content: "where do I live?" },
    { role: "assistant", content: "Kyoto." },
    { role: "user", content: "and Kyoto weather?" },
  ];

  await Array.fromAsync(runAgent({ provider, system: "sys", messages, memory }));
  expect(seen[0]![0]).toEqual({
    role: "system",
    content: "Recalled from memory (may be relevant):\n- (fact) user lives in Kyoto\n\nsys",
  });

  // Without the option the system prompt is untouched.
  await Array.fromAsync(runAgent({ provider, system: "sys", messages }));
  expect(seen[1]![0]).toEqual({ role: "system", content: "sys" });
});
