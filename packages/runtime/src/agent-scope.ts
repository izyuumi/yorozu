import { lstatSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";

/** Admission policy only. A runtime must enforce it below the harness before launch. */
export const PERSON_AGENT_TOOLS = ["file", "terminal", "delegation", "memory", "web", "browser", "team", "computer"] as const;
export type PersonAgentTool = typeof PERSON_AGENT_TOOLS[number];
export interface DirectoryGrant { path: string; access: "read" | "write" }
export interface ScopeSelection { allowedTools: string[]; directories: DirectoryGrant[]; knowledgeIds?: string[] }
export interface EffectiveAgentScope extends ScopeSelection {
  version: 1;
  agentId: string;
  revision: number;
  chain: string[];
  deniedRoots: string[];
}

export function validAgentId(value: unknown): value is string {
  return typeof value === "string" && /^[a-z][a-z0-9_-]{0,63}$/.test(value);
}
export function validateTools(values: unknown): PersonAgentTool[] {
  if (!Array.isArray(values) || values.length > PERSON_AGENT_TOOLS.length
    || values.some(value => typeof value !== "string" || !PERSON_AGENT_TOOLS.includes(value as PersonAgentTool)))
    throw new Error("Unknown or excessive agent tool grants");
  if (new Set(values).size !== values.length) throw new Error("Duplicate agent tool grants");
  return [...values].sort() as PersonAgentTool[];
}
export function validateKnowledgeIds(values: unknown): string[] {
  if (values === undefined) return [];
  if (!Array.isArray(values) || values.length > 512 || values.some(id => !validAgentId(id)) || new Set(values).size !== values.length)
    throw new Error("Invalid shared knowledge selection");
  return [...values].sort();
}
export function pathWithin(parent: string, child: string): boolean {
  const rel = relative(parent, child);
  return rel === "" || rel !== ".." && !rel.startsWith(".." + sep) && !isAbsolute(rel);
}

/** Reject symlinks in every existing component, including ancestors and dangling links.
 * Missing suffixes are allowed for future files. This is not an openat/OS sandbox guarantee.
 */
export function safeAgentPath(input: string, mustExist = false): string {
  if (typeof input !== "string" || !isAbsolute(input) || input.length > 4096 || /[\0\r\n]/.test(input)
    || input.split(/[\\/]/).includes("..")) throw new Error("Invalid agent path");
  const target = resolve(input);
  const components: string[] = [];
  for (let path = target;; path = dirname(path)) {
    components.push(path);
    if (dirname(path) === path) break;
  }
  let missing = false;
  for (const path of components.reverse()) {
    if (missing) continue;
    try {
      const stat = lstatSync(path);
      if (stat.isSymbolicLink()) throw new Error("Symlink in agent path");
      if (path !== target && !stat.isDirectory()) throw new Error("Non-directory agent path ancestor");
      if (realpathSync(path) !== path) throw new Error("Agent path changed identity");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      missing = true;
    }
  }
  if (mustExist && missing) throw new Error("Agent path does not exist");
  return target;
}

export function normalizeDirectoryGrants(values: unknown): DirectoryGrant[] {
  if (!Array.isArray(values) || values.length > 64) throw new Error("Excessive directory grants");
  const out: DirectoryGrant[] = [];
  for (const value of values) {
    if (!value || typeof value !== "object" || Object.keys(value).some(k => !["path", "access"].includes(k))
      || typeof value.path !== "string" || !["read", "write"].includes(value.access)) throw new Error("Invalid directory grant");
    const next: DirectoryGrant = { path: safeAgentPath(value.path), access: value.access };
    try { if (!lstatSync(next.path).isDirectory()) throw new Error("Directory grant is not a directory"); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    if (out.some(g => g.path === next.path)) throw new Error("Duplicate directory grants");
    out.push(next);
  }
  return out.sort((a, b) => a.path.localeCompare(b.path));
}

/** Narrower path and weaker right win. Write includes read. Never unions authority. */
export function intersectDirectoryGrants(left: DirectoryGrant[], right: DirectoryGrant[]): DirectoryGrant[] {
  const found = new Map<string, DirectoryGrant>();
  for (const a of normalizeDirectoryGrants(left)) for (const b of normalizeDirectoryGrants(right)) {
    const path = pathWithin(a.path, b.path) ? b.path : pathWithin(b.path, a.path) ? a.path : undefined;
    if (!path) continue;
    const access = a.access === "write" && b.access === "write" ? "write" : "read";
    const old = found.get(path);
    if (!old || access === "write") found.set(path, { path, access });
  }
  // Remove redundant descendants, but retain a narrower write grant under broad read.
  const grants = [...found.values()];
  return grants.filter(g => !grants.some(other => other !== g && pathWithin(other.path, g.path)
    && (other.access === "write" || g.access === "read"))).sort((a, b) => a.path.localeCompare(b.path));
}

export function intersectAgentScopes(...scopes: ScopeSelection[]): ScopeSelection {
  if (!scopes.length) return { allowedTools: [], directories: [] };
  let allowedTools: string[] = validateTools(scopes[0].allowedTools);
  let directories = normalizeDirectoryGrants(scopes[0].directories);
  let knowledgeIds = validateKnowledgeIds(scopes[0].knowledgeIds);
  for (const scope of scopes.slice(1)) {
    const tools = validateTools(scope.allowedTools);
    allowedTools = allowedTools.filter(tool => tools.includes(tool as PersonAgentTool));
    directories = intersectDirectoryGrants(directories, scope.directories);
    const selected = validateKnowledgeIds(scope.knowledgeIds);
    knowledgeIds = knowledgeIds.filter(id => selected.includes(id));
  }
  return { allowedTools, directories, knowledgeIds };
}

export function agentScopeAllowsPath(scope: EffectiveAgentScope, input: string, access: "read" | "write"): boolean {
  if (!["read", "write"].includes(access)) return false;
  try {
    const path = safeAgentPath(input);
    if (scope.deniedRoots.some(root => pathWithin(safeAgentPath(root), path))) return false;
    return normalizeDirectoryGrants(scope.directories).some(grant => pathWithin(grant.path, path)
      && (access === "read" || grant.access === "write"));
  } catch { return false; }
}
