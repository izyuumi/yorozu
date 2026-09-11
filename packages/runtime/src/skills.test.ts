import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { env } from "node:process";
import { afterEach, beforeEach, expect, test } from "vitest";
import { listSkills, skillsDir, skillsPrompt, skillTool } from "./skills.js";

let dir: string;
let previousStateDir: string | undefined;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-skills-"));
  previousStateDir = env.YOROZU_STATE_DIR;
  env.YOROZU_STATE_DIR = dir;
});

afterEach(() => {
  if (previousStateDir === undefined) delete env.YOROZU_STATE_DIR;
  else env.YOROZU_STATE_DIR = previousStateDir;
  rmSync(dir, { recursive: true, force: true });
});

function skill(folder: string, text: string): void {
  mkdirSync(join(dir, "skills", folder), { recursive: true });
  writeFileSync(join(dir, "skills", folder, "SKILL.md"), text);
}

test("skills load from AgentSkills directories, unchanged", () => {
  skill(
    "pdf-forms",
    ['---', 'name: pdf-forms', 'description: "Fill in PDF forms"', '---', '', 'Use pdftk.', ''].join("\n"),
  );
  // No name in the frontmatter: the directory is the name.
  skill("recipes", "---\ndescription: Cook from what is in the fridge\n---\n\nStart with the pantry.");
  mkdirSync(join(dir, "skills", "not-a-skill"), { recursive: true });

  expect(listSkills(skillsDir(dir))).toEqual([
    { name: "pdf-forms", description: "Fill in PDF forms", body: "Use pdftk." },
    { name: "recipes", description: "Cook from what is in the fridge", body: "Start with the pantry." },
  ]);
});

test("the startup prompt lists names and descriptions only", () => {
  expect(skillsPrompt([])).toBe("");
  expect(skillsPrompt([{ name: "recipes", description: "Cook", body: "Start with the pantry." }])).toBe(
    "Skills you can load with the skill tool, by name, when a task calls for one:\n- recipes: Cook",
  );
});

test("the skill tool returns the body, and only for a listed skill", async () => {
  skill("recipes", "---\nname: recipes\ndescription: Cook\n---\n\nStart with the pantry.");

  expect(await skillTool.run({ name: "recipes" })).toBe("Start with the pantry.");
  expect(await skillTool.run({ name: "missing" })).toBe("no such skill: missing");
  // The name is matched against the listing, so it never reaches a path.
  expect(await skillTool.run({ name: "../../../etc/passwd" })).toBe(
    "no such skill: ../../../etc/passwd",
  );
});

test("a state directory without skills is not an error", () => {
  expect(listSkills(skillsDir(dir))).toEqual([]);
  expect(skillsPrompt(listSkills(skillsDir(dir)))).toBe("");
});
