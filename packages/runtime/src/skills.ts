/**
 * Skills in the AgentSkills format: `<state dir>/skills/<name>/SKILL.md`, frontmatter
 * `name` and `description`. Existing skill directories drop in unchanged — nothing is
 * copied or rewritten. Names and descriptions go into the main system prompt on startup;
 * the body is loaded on demand by the `skill` tool. See docs/spec-v1.html section 3.
 */

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { frontmatter } from "./frontmatter.js";
import type { Tool } from "./index.js";
import { stateDir } from "./memory.js";

export interface Skill {
  name: string;
  description: string;
  /** SKILL.md without its frontmatter: the instructions themselves. */
  body: string;
}

export const skillsDir = (dir = stateDir()): string => join(dir, "skills");

/** Every directory holding a readable SKILL.md, by name. A missing skills dir is empty. */
export function listSkills(dir = skillsDir()): Skill[] {
  if (!existsSync(dir)) return [];
  const skills: Skill[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    let text: string;
    try {
      text = readFileSync(join(dir, entry.name, "SKILL.md"), "utf8");
    } catch {
      // A directory without a SKILL.md is not a skill.
      continue;
    }
    const { fields, body } = frontmatter(text);
    // The frontmatter name wins, as the format says; the directory is the fallback.
    skills.push({
      name: fields.get("name") || entry.name,
      description: fields.get("description") ?? "",
      body,
    });
  }
  return skills.sort((a, b) => a.name.localeCompare(b.name));
}

/** The block appended to the main system prompt at startup. Empty when there are none. */
export const skillsPrompt = (skills: Skill[] = listSkills()): string =>
  skills.length
    ? [
        "Skills you can load with the skill tool, by name, when a task calls for one:",
        ...skills.map((s) => `- ${s.name}: ${s.description}`),
      ].join("\n")
    : "";

export const skillTool: Tool = {
  name: "skill",
  description:
    "Load a skill by name and follow its instructions. Skills are listed in the system prompt.",
  parameters: {
    type: "object",
    properties: { name: { type: "string" } },
    required: ["name"],
  },
  // Resolved through the listing, so a model-supplied name never reaches a path.
  run: ({ name }) => {
    const wanted = String(name ?? "");
    const skill = listSkills().find((s) => s.name === wanted);
    if (!skill) throw new Error(`no such skill: ${wanted}`);
    return skill.body;
  },
};
