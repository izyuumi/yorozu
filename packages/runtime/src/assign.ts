/**
 * Auto-assign: the default model reads every agent file plus the catalog and picks a model
 * for each one, which is written into the file's `model:` frontmatter and returned as a
 * unified diff. The replaced texts are kept in `assign.backup.json`, so Revert is one call.
 * Research mode first sends the model at the web with its own tools and writes what it
 * finds into the catalog overlay — never into the catalog. See docs/spec-v1.html section 2.
 */

import { existsSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { agentsDir, parseAgent } from "./agents.js";
import {
  loadCatalog,
  mergeById,
  writeOverlay,
  type CatalogEntry,
} from "./catalog.js";
import { chainFromEnv } from "./chain.js";
import { parseCron } from "./cron.js";
import { setField } from "./frontmatter.js";
import type { Tool } from "./index.js";
import { stateDir } from "./memory.js";
import type { Provider } from "./provider.js";
import { listJobs, saveJobs, SYSTEM_THREAD } from "./scheduler.js";

/** Where the picks come from: the published catalog, or the model's own web research. */
export type AssignMode = "catalog" | "research";

export const ASSIGN_TOOL = "auto_assign_models";

/** Stable id, so the Mac app's cron field updates one job rather than adding another. */
export const ASSIGN_JOB_ID = "auto-assign-models";

const BACKUP_FILE = "assign.backup.json";

/**
 * What research mode may use. `web_search` and `fetch` are the search ticket's tools; the
 * browser is what the runtime has today. Whichever exist are offered, the rest ignored.
 */
const RESEARCH_TOOLS = [
  "web_search",
  "fetch",
  "browser.open",
  "browser.snapshot",
  "browser.close",
];

const ASSIGN_SYSTEM = [
  "You assign one model to each of the user's agents.",
  "Pick from the catalog ids only. Match the model to the work: the cheapest model that can",
  "do an agent's job is the right one, and the strongest model is for agents whose work",
  "actually needs it. Leave an agent out of your answer to leave its file alone.",
  "Answer with JSON and nothing else: an object keyed by agent name, each value",
  '{"model": "<catalog id>", "reason": "<one line>"}.',
].join(" ");

const RESEARCH_SYSTEM = [
  "You refresh model prices for a local catalog overlay.",
  "Use your tools to read the providers' current public pricing pages, and report only rows",
  "you actually read. Use null for any price or context size you could not confirm.",
  "Answer with JSON and nothing else: an array of rows",
  '{"id", "provider", "inputPer1M", "outputPer1M", "contextK", "strengths", "updated"},',
  "where id is a provider spec such as claude-cli/claude-opus-5 or openai/gpt-5.6-sol.",
].join(" ");

/**
 * The loop lives in index.ts, which puts this file's tool in `defaultTools`. A static
 * import back would be a cycle that leaves `autoAssignTool` in its temporal dead zone
 * whenever this module is the one loaded first — which is what `serve.js` does. Importing
 * it on use is a live binding either way.
 */
const loop = () => import("./index.js");

/** One model's pick for one agent. Both fields are model output: neither is trusted. */
interface Assignment {
  model?: unknown;
  reason?: unknown;
}

/** Model output is prose around JSON as often as not: take the outermost block. */
function parseJsonIn(text: string, open: "{" | "["): unknown {
  const close = open === "{" ? "}" : "]";
  const start = text.indexOf(open);
  const end = text.lastIndexOf(close);
  if (start < 0 || end < start) throw new Error(`auto_assign: no JSON in the model's reply`);
  return JSON.parse(text.slice(start, end + 1));
}

/** One turn, returning its final text. Tools are only offered to research mode. */
async function ask(
  provider: Provider,
  system: string,
  task: string,
  tools: Tool[],
): Promise<string> {
  const { runAgent } = await loop();
  let text = "";
  for await (const event of runAgent({
    provider,
    system,
    messages: [{ role: "user", content: task }],
    tools,
    maxTurns: tools.length ? 8 : 2,
  })) {
    if (event.type === "final") text = event.text;
  }
  return text;
}

/**
 * A unified diff of one file. Only ever a single contiguous edit here — one frontmatter
 * line — so trimming the common prefix and suffix is the whole algorithm.
 */
export function unifiedDiff(path: string, before: string, after: string): string {
  const a = before.split("\n");
  const b = after.split("\n");
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length;
  let endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) {
    endA--;
    endB--;
  }
  if (start === endA && start === endB) return "";

  const context = 3;
  const from = Math.max(0, start - context);
  const toA = Math.min(a.length, endA + context);
  const toB = Math.min(b.length, endB + context);
  return [
    `--- a/${path}`,
    `+++ b/${path}`,
    `@@ -${from + 1},${toA - from} +${from + 1},${toB - from} @@`,
    ...a.slice(from, start).map((line) => ` ${line}`),
    ...a.slice(start, endA).map((line) => `-${line}`),
    ...b.slice(start, endB).map((line) => `+${line}`),
    ...a.slice(endA, toA).map((line) => ` ${line}`),
    "",
  ].join("\n");
}

export interface AssignOptions {
  mode?: AssignMode;
  /** State directory: agents, catalog, overlay and backup all live under it. */
  dir?: string;
  /** Defaults to the model chain configured from the environment. */
  provider?: Provider;
  /** Tools research mode may use. Defaults to the runtime's web-facing ones. */
  tools?: Tool[];
}

/** Research mode: the model reads the web and the result lands in the overlay. */
async function research(
  provider: Provider,
  catalog: CatalogEntry[],
  tools: Tool[],
  dir: string,
): Promise<CatalogEntry[]> {
  const text = await ask(
    provider,
    RESEARCH_SYSTEM,
    `Today is ${new Date().toISOString().slice(0, 10)}. The rows in use now:\n` +
      JSON.stringify(catalog, null, 2),
    tools,
  );
  const rows = parseJsonIn(text, "[") as CatalogEntry[];
  return writeOverlay(
    rows.filter((row) => row && typeof row.id === "string"),
    dir,
  );
}

const describe = (name: string, text: string): string => {
  const agent = parseAgent(name, text);
  const summary = agent.description ?? agent.prompt.split("\n")[0] ?? "";
  return `- ${name} (model now: ${agent.model ?? "inherited"}): ${summary}`;
};

/**
 * Assigns a model to every agent and writes it. Returns the unified diff of what changed,
 * empty when the model left everything as it was.
 */
export async function autoAssign(options: AssignOptions = {}): Promise<string> {
  const dir = options.dir ?? stateDir();
  const agents = agentsDir(dir);
  const provider = options.provider ?? chainFromEnv();

  let catalog = await loadCatalog({ dir });
  if (options.mode === "research") {
    const tools =
      options.tools ??
      (await loop()).defaultTools.filter((tool) => RESEARCH_TOOLS.includes(tool.name));
    catalog = mergeById(catalog, await research(provider, catalog, tools, dir));
  }

  const files = existsSync(agents)
    ? readdirSync(agents).filter((file) => file.endsWith(".md")).sort()
    : [];
  const before = new Map(files.map((file) => [file, readFileSync(join(agents, file), "utf8")]));
  if (!before.size) return "";

  const answer = parseJsonIn(
    await ask(
      provider,
      ASSIGN_SYSTEM,
      `Catalog:\n${JSON.stringify(catalog, null, 2)}\n\nAgents:\n${[...before]
        .map(([file, text]) => describe(file.slice(0, -3), text))
        .join("\n")}`,
      [],
    ),
    "{",
  ) as Record<string, Assignment | undefined>;

  const backup: Record<string, string> = {};
  let diff = "";
  for (const [file, text] of before) {
    const pick = answer[file.slice(0, -3)];
    const model = typeof pick?.model === "string" ? pick.model.trim() : "";
    if (!model) continue;
    const next = setField(text, "model", model);
    if (next === text) continue;
    writeFileSync(join(agents, file), next);
    backup[file] = text;
    const reason = typeof pick?.reason === "string" ? pick.reason.trim() : "";
    // Prose before the `---` header is ignored by patch tools, so the reason rides along.
    diff += `${reason ? `# ${file.slice(0, -3)}: ${reason}\n` : ""}${unifiedDiff(
      `agents/${file}`,
      text,
      next,
    )}`;
  }

  if (Object.keys(backup).length) {
    writeFileSync(join(dir, BACKUP_FILE), `${JSON.stringify(backup, null, 2)}\n`);
  }
  return diff;
}

/** Puts back exactly what the last run replaced. One revert per run. */
export function revertAssign(dir = stateDir()): string {
  const file = join(dir, BACKUP_FILE);
  let backup: Record<string, string>;
  try {
    backup = JSON.parse(readFileSync(file, "utf8")) as Record<string, string>;
  } catch {
    return "nothing to revert";
  }
  const agents = agentsDir(dir);
  // Our own file, but it still names paths: only ever write inside the agents directory.
  for (const [name, text] of Object.entries(backup)) {
    writeFileSync(join(agents, basename(name)), text);
  }
  rmSync(file, { force: true });
  return `reverted ${Object.keys(backup).length} agent file(s)`;
}

/** Creates or updates the repeating auto-assign job. An empty expression removes it. */
export function setAssignCron(
  cron: string,
  mode: AssignMode = "catalog",
  dir = stateDir(),
): string {
  const expression = cron.trim();
  const jobs = listJobs(dir).filter((job) => job.id !== ASSIGN_JOB_ID);
  if (!expression) {
    saveJobs(jobs, dir);
    return "auto-assign unscheduled";
  }
  parseCron(expression);
  saveJobs(
    [
      ...jobs,
      {
        id: ASSIGN_JOB_ID,
        threadId: SYSTEM_THREAD,
        cron: expression,
        createdBy: "system",
        instruction:
          `Call ${ASSIGN_TOOL} with mode "${mode}", then say in one line which agents ` +
          "changed model, or say nothing if none did.",
      },
    ],
    dir,
  );
  return `auto-assign scheduled: ${expression}`;
}

export const autoAssignTool: Tool = {
  name: ASSIGN_TOOL,
  description:
    "Assign a model to every agent from the model catalog, writing model: into each agent " +
    "file and returning the diff. Mode research refreshes prices from the web into the " +
    "local catalog overlay first.",
  parameters: {
    type: "object",
    properties: {
      mode: { type: "string", enum: ["catalog", "research"] },
    },
    required: [],
  },
  run: async ({ mode }) =>
    (await autoAssign({ mode: mode === "research" ? "research" : "catalog" })) ||
    "no changes",
};
