/**
 * Agents are markdown: `<state dir>/agents/<name>.md`, body is the system prompt.
 * Frontmatter is opt-in restriction only — `model`, `tools` allowlist, `memory` scope —
 * and an absent field inherits the main agent's. See docs/spec-v1.html section 3.
 */

import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { frontmatter } from "./frontmatter.js";
import { stateDir } from "./memory.js";

/** The agent that talks to the user. Its file is the main system prompt. */
export const MAIN_AGENT = "main";

export interface AgentConfig {
  /** File stem; the name `delegate` takes. */
  name: string;
  /** The file body: this agent's system prompt. Never inherited. */
  prompt: string;
  /** One line for the delegate tool's agent list. Never inherited. */
  description?: string;
  /** Provider spec as `chainFromEnv` takes it, e.g. `claude-cli/claude-sonnet-5`. */
  model?: string;
  /** Allowlist of tool names. Absent means every tool the main agent has. */
  tools?: string[];
  /** Subdirectory of the memory directory this agent recalls from. */
  memory?: string;
}

export const agentsDir = (dir = stateDir()): string => join(dir, "agents");

/** The agents shipped with the package, next to `dist/` and `src/` alike. */
const BUNDLED = fileURLToPath(new URL("../agents", import.meta.url));

/**
 * Installs the bundled agents into the state directory. A file the user edited is never
 * written over; a file still identical to the copy last installed is refreshed when the
 * bundle changes, so prompt fixes reach users who never touched their agents. The shadow
 * copies under `.bundled/` are what "still identical" is measured against; a deleted
 * agent comes back, since only the file's absence means missing.
 */
export function installAgents(dir = agentsDir(), bundled = BUNDLED): string {
  mkdirSync(dir, { recursive: true });
  if (!existsSync(bundled)) return dir;
  const shadow = join(dir, ".bundled");
  mkdirSync(shadow, { recursive: true });
  for (const name of readdirSync(bundled).filter((f) => f.endsWith(".md"))) {
    const next = readFileSync(join(bundled, name), "utf8");
    const installed = join(dir, name);
    const previous = join(shadow, name);
    const untouched =
      !existsSync(installed) ||
      (existsSync(previous) && readFileSync(installed, "utf8") === readFileSync(previous, "utf8"));
    if (untouched) writeFileSync(installed, next);
    writeFileSync(previous, next);
  }
  return dir;
}

export function parseAgent(name: string, text: string): AgentConfig {
  const { fields, body } = frontmatter(text);
  const tools = fields.get("tools");
  const description = fields.get("description");
  const model = fields.get("model");
  const memory = fields.get("memory");
  return {
    name,
    prompt: body,
    ...(description ? { description } : {}),
    ...(model ? { model } : {}),
    ...(memory ? { memory } : {}),
    // `a, b` and `[a, b]` both read as an allowlist; an empty list means no tools at all.
    ...(tools === undefined
      ? {}
      : {
          tools: tools
            .replace(/^\[|\]$/g, "")
            .split(",")
            .map((entry) => entry.trim())
            .filter(Boolean),
        }),
  };
}

/** Every readable agent file, by name. Unreadable files are skipped, not fatal. */
export function listAgents(dir = agentsDir()): AgentConfig[] {
  if (!existsSync(dir)) return [];
  const agents: AgentConfig[] = [];
  for (const file of readdirSync(dir).sort()) {
    if (!file.endsWith(".md")) continue;
    try {
      agents.push(parseAgent(file.slice(0, -3), readFileSync(join(dir, file), "utf8")));
    } catch {
      // A file being written right now must not break the listing.
    }
  }
  return agents;
}

/** Looked up through the listing so a model-supplied name never reaches a path. */
export const loadAgent = (name: string, dir = agentsDir()): AgentConfig | undefined =>
  listAgents(dir).find((agent) => agent.name === name);

/**
 * Restrictions the specialist did not state are the main agent's: absent means inherit.
 * Name, prompt and description are the specialist's own and never inherit.
 */
export const inherit = (agent: AgentConfig, main: AgentConfig): AgentConfig => ({
  model: main.model,
  tools: main.tools,
  memory: main.memory,
  ...agent,
});
