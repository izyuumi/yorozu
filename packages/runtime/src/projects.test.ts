import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { isProjectFolder, listProjects } from "./projects.js";
import { createThread } from "./threads.js";

test("projects are the folders under the root, recents first, and nothing inside them", () => {
  const root = mkdtempSync(join(tmpdir(), "yorozu-projects-"));
  const dir = mkdtempSync(join(tmpdir(), "yorozu-projects-state-"));
  for (const name of ["zeta", "alpha", ".hidden", "mid"]) mkdirSync(join(root, name));
  writeFileSync(join(root, "notes.txt"), "not a folder");
  writeFileSync(join(root, "alpha", "secret.env"), "never listed");

  expect(listProjects(root, dir)).toEqual([
    { path: join(root, "alpha"), name: "alpha" },
    { path: join(root, "mid"), name: "mid" },
    { path: join(root, "zeta"), name: "zeta" },
  ]);

  // A thread started in a folder makes it a recent, ahead of the alphabet.
  const thread = createThread("Fix", dir, "cc", { agent: "claude-code", cwd: join(root, "zeta") });
  const listed = listProjects(root, dir);
  expect(listed.map((p) => p.name)).toEqual(["zeta", "alpha", "mid"]);
  expect(listed[0]!.lastUsed).toBe(Date.parse(thread.createdAt));
  expect(JSON.stringify(listed)).not.toContain("secret");

  // A folder the picker would offer, and the ones it would not.
  expect(isProjectFolder(join(root, "alpha"), root)).toBe(true);
  expect(isProjectFolder(join(root, "alpha", "src"), root)).toBe(false);
  expect(isProjectFolder(join(root, "notes.txt"), root)).toBe(false);
  expect(isProjectFolder("/etc", root)).toBe(false);
  expect(isProjectFolder(root, root)).toBe(false);

  // No root at all is an empty list, not a crash.
  expect(listProjects(join(root, "missing"), dir)).toEqual([]);
});
