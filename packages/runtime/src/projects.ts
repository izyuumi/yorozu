/**
 * The folders a coding agent's thread can be started in: every directory directly under
 * `~/Projects`, with the ones threads were recently started in first. Only names and paths are
 * listed — never what is inside them.
 */

import { readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ProjectFolder } from "@yorozu/shared";
import { stateDir } from "./memory.js";
import { listThreads } from "./threads.js";

export const projectsRoot = (): string => process.env.YOROZU_PROJECTS_DIR ?? join(homedir(), "Projects");

/**
 * Recents first, by when a thread was last started in them, then the rest by name. A thread's
 * folder that is no longer under the root — or no longer exists — is left out: the picker offers
 * what can be started in now.
 */
export function listProjects(root = projectsRoot(), dir = stateDir()): ProjectFolder[] {
  let names: string[] = [];
  try {
    names = readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
      .map((entry) => entry.name);
  } catch {
    // No such root: nothing to offer, which the picker says.
  }
  const lastUsed = new Map<string, number>();
  for (const thread of listThreads(dir)) {
    if (!thread.cwd) continue;
    const at = Date.parse(thread.createdAt) || 0;
    lastUsed.set(thread.cwd, Math.max(lastUsed.get(thread.cwd) ?? 0, at));
  }
  return names
    .map((name) => {
      const path = join(root, name);
      const used = lastUsed.get(path);
      return { path, name, ...(used ? { lastUsed: used } : {}) };
    })
    .sort((a, b) => (b.lastUsed ?? 0) - (a.lastUsed ?? 0) || a.name.localeCompare(b.name));
}

/** Whether `cwd` is a folder the picker would have offered: under the root and a directory. */
export function isProjectFolder(cwd: string, root = projectsRoot()): boolean {
  if (!cwd.startsWith(`${root}/`) || cwd.slice(root.length + 1).includes("/")) return false;
  try {
    return statSync(cwd).isDirectory();
  } catch {
    return false;
  }
}
