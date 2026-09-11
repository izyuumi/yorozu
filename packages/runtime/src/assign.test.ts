import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test } from "vitest";
import { agentsDir, parseAgent } from "./agents.js";
import {
  ASSIGN_JOB_ID,
  autoAssign,
  revertAssign,
  setAssignCron,
  unifiedDiff,
} from "./assign.js";
import { catalogCacheFile } from "./catalog.js";
import type { Provider, ProviderEvent } from "./provider.js";
import { listJobs } from "./scheduler.js";

let dir: string;
let agents: string;

const MAIN = "You are Yorozu, a personal assistant.\n";
const BROWSER = "---\ndescription: drives web pages\nmodel: openai/gpt-4o-mini\n---\nYou use the web.\n";

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-assign-"));
  agents = agentsDir(dir);
  mkdirSync(agents, { recursive: true });
  writeFileSync(join(agents, "main.md"), MAIN);
  writeFileSync(join(agents, "browser.md"), BROWSER);
  // A fresh cache keeps loadCatalog off the network for the whole test.
  writeFileSync(
    catalogCacheFile(dir),
    JSON.stringify([
      {
        id: "claude-cli/claude-opus-5",
        provider: "anthropic",
        inputPer1M: 5,
        outputPer1M: 25,
        contextK: 1000,
        strengths: ["agentic"],
        updated: "2026-09-12",
      },
    ]),
  );
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

/** A provider answering each turn with the next scripted text, the last one repeating. */
function scripted(...texts: string[]): Provider {
  const queue = [...texts];
  return {
    auth: async () => ({ ok: true }),
    async *stream(): AsyncGenerator<ProviderEvent> {
      yield { type: "text", text: queue.length > 1 ? queue.shift()! : (queue[0] ?? "") };
      yield { type: "done", reason: "stop" };
    },
  };
}

const fixed = (text: string): Provider => scripted(text);

const ANSWER = JSON.stringify({
  main: { model: "claude-cli/claude-opus-5", reason: "talks to the user all day" },
  browser: { model: "claude-cli/claude-sonnet-5", reason: "page reading is cheap work" },
});

test("assign writes model: frontmatter and returns a diff, and revert puts it back", async () => {
  const diff = await autoAssign({ dir, provider: fixed(`Here you go:\n${ANSWER}`) });

  // A file with no frontmatter gets one; an existing head keeps its other fields.
  const main = parseAgent("main", readFileSync(join(agents, "main.md"), "utf8"));
  expect(main.model).toBe("claude-cli/claude-opus-5");
  expect(main.prompt).toBe(MAIN.trim());

  const browser = parseAgent("browser", readFileSync(join(agents, "browser.md"), "utf8"));
  expect(browser.model).toBe("claude-cli/claude-sonnet-5");
  expect(browser.description).toBe("drives web pages");
  expect(browser.prompt).toBe("You use the web.");

  expect(diff).toContain("--- a/agents/browser.md");
  expect(diff).toContain("-model: openai/gpt-4o-mini");
  expect(diff).toContain("+model: claude-cli/claude-sonnet-5");
  expect(diff).toContain("+++ b/agents/main.md");
  // The one-line reason rides ahead of each file's header.
  expect(diff).toContain("# main: talks to the user all day");

  expect(revertAssign(dir)).toBe("reverted 2 agent file(s)");
  expect(readFileSync(join(agents, "main.md"), "utf8")).toBe(MAIN);
  expect(readFileSync(join(agents, "browser.md"), "utf8")).toBe(BROWSER);
  expect(revertAssign(dir)).toBe("nothing to revert");
});

test("an agent the model left out, or already on that model, is not touched", async () => {
  const diff = await autoAssign({
    dir,
    provider: fixed(JSON.stringify({ browser: { model: "openai/gpt-4o-mini" } })),
  });
  expect(diff).toBe("");
  expect(readFileSync(join(agents, "main.md"), "utf8")).toBe(MAIN);
  expect(revertAssign(dir)).toBe("nothing to revert");
});

test("a reply with no JSON in it fails loudly rather than writing half the files", async () => {
  await expect(autoAssign({ dir, provider: fixed("I could not decide.") })).rejects.toThrow(
    /no JSON/,
  );
  expect(readFileSync(join(agents, "main.md"), "utf8")).toBe(MAIN);
});

test("research mode writes the overlay and never the catalog", async () => {
  const rows = [
    {
      id: "openai/gpt-4o-mini",
      provider: "openai",
      inputPer1M: 0.15,
      outputPer1M: 0.6,
      contextK: 128,
      strengths: ["cheap"],
      updated: "2026-09-12",
    },
  ];
  // Two turns: the research array first, then the assignment object.
  await autoAssign({
    dir,
    mode: "research",
    tools: [],
    provider: scripted(`Read the pricing pages:\n${JSON.stringify(rows)}`, ANSWER),
  });

  expect(JSON.parse(readFileSync(join(dir, "catalog.overlay.json"), "utf8"))).toEqual(rows);
  expect(
    (JSON.parse(readFileSync(catalogCacheFile(dir), "utf8")) as { id: string }[]).map(
      (entry) => entry.id,
    ),
  ).toEqual(["claude-cli/claude-opus-5"]);
});

test("the cron field creates, updates and removes exactly one job", () => {
  expect(setAssignCron("0 4 * * 1", "research", dir)).toBe("auto-assign scheduled: 0 4 * * 1");
  const job = listJobs(dir).find((entry) => entry.id === ASSIGN_JOB_ID)!;
  expect(job).toMatchObject({ cron: "0 4 * * 1", threadId: "system" });
  expect(job.instruction).toContain("auto_assign_models");
  expect(job.instruction).toContain("research");

  setAssignCron("0 5 * * *", "catalog", dir);
  const jobs = listJobs(dir).filter((entry) => entry.id === ASSIGN_JOB_ID);
  expect(jobs).toHaveLength(1);
  expect(jobs[0]!.cron).toBe("0 5 * * *");

  expect(() => setAssignCron("nope", "catalog", dir)).toThrow("5 fields");
  expect(setAssignCron("", "catalog", dir)).toBe("auto-assign unscheduled");
  expect(listJobs(dir).map((entry) => entry.id)).not.toContain(ASSIGN_JOB_ID);
});

test("an unchanged file diffs to nothing", () => {
  expect(unifiedDiff("a.md", "x\n", "x\n")).toBe("");
  expect(unifiedDiff("a.md", "x\ny\n", "x\nz\n")).toBe(
    ["--- a/a.md", "+++ b/a.md", "@@ -1,3 +1,3 @@", " x", "-y", "+z", " ", ""].join("\n"),
  );
});
