import { randomUUID } from "node:crypto";
import { closeSync, constants, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, rmdirSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { agentScopeAllowsPath, intersectAgentScopes, normalizeDirectoryGrants, pathWithin, safeAgentPath, validAgentId, validateTools,
  type DirectoryGrant, type EffectiveAgentScope, type ScopeSelection } from "./agent-scope.js";

export type PersonAgentPlugin = "hermes" | "openclaw";
export interface PersonAgent {
  id: string; name: string; role: string; pluginId: PersonAgentPlugin;
  model?: string; accountBindingId?: string;
  workspace: string; memoryDir: string;
  allowedTools: string[]; directories: DirectoryGrant[]; teamIds: string[];
}
export interface PersonAgentInput {
  id?: string; name: string; role: string; pluginId: PersonAgentPlugin;
  model?: string; accountBindingId?: string;
  allowedTools: string[]; directories?: DirectoryGrant[];
}
export type PersonAgentPatch = Partial<Omit<PersonAgentInput, "id">> & { clear?: Array<"model" | "accountBindingId"> };
export interface AgentTeam { id: string; name: string; agentIds: string[] }
export interface AgentRegistry { version: 1; revision: number; defaultAgentId?: string; agents: PersonAgent[]; teams: AgentTeam[] }
export interface PersonAgentPaths { workspace: string; memoryDir: string; runtimeDir: string }
export interface AgentKnowledgeEntry {
  id: string; kind: "preference" | "shared-knowledge"; text: string; createdAt: string;
  agentId?: string; allAgents?: true; fromAgentId?: string; toAgentIds?: string[];
}
export interface AgentKnowledgeJournal { version: 1; revision: number; entries: AgentKnowledgeEntry[] }
export interface PersonAgentStoreOptions { resourceRoots?: DirectoryGrant[]; protectedRoots?: readonly string[] }

const MAX_AGENTS = 64, MAX_TEAMS = 32, MAX_JOURNAL = 512, MAX_BYTES = 2 * 1024 * 1024;
const clone = <T>(value: T): T => structuredClone(value);
function text(value: unknown, label: string, max = 256): string {
  if (typeof value !== "string" || !value.trim() || value.length > max || /[\0\r\n]/.test(value)) throw new Error(`Invalid ${label}`);
  return value.trim();
}
function keys(value: unknown, allowed: string[]): asserts value is Record<string, any> {
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).some(key => !allowed.includes(key))) throw new Error("Unexpected agent fields");
}
function ids(value: unknown, max: number): string[] {
  if (!Array.isArray(value) || value.length > max || value.some(id => !validAgentId(id)) || new Set(value).size !== value.length) throw new Error("Invalid agent identifiers");
  return [...value].sort();
}
function revision(value: unknown): asserts value is number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) throw new Error("Invalid agent revision");
}

/** Host-only authority registry. Never expose this state directory to a harness.
 * Resource roots are supplied by the trusted host after explicit selection/authorization.
 * Path checks reject observed symlinks; mandatory OS/tool enforcement remains the caller's job.
 */
export class PersonAgentStore {
  readonly root: string;
  private readonly resourceRoots: DirectoryGrant[];
  private readonly protectedRoots: string[];
  private readonly scopes = new WeakSet<object>();
  constructor(stateDir: string, options: PersonAgentStoreOptions = {}) {
    safeAgentPath(stateDir);
    mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    this.root = safeAgentPath(join(stateDir, "agents-v1"));
    mkdirSync(this.root, { recursive: true, mode: 0o700 });
    this.assertRoot();
    this.resourceRoots = normalizeDirectoryGrants(options.resourceRoots ?? []);
    if (options.protectedRoots !== undefined && (!Array.isArray(options.protectedRoots) || options.protectedRoots.length > 16)) throw new Error("Invalid host protected roots");
    this.protectedRoots = [...new Set((options.protectedRoots ?? []).map(path => safeAgentPath(path)))];
    if (this.resourceRoots.some(g => pathWithin(g.path, this.root) || pathWithin(this.root, g.path))) throw new Error("Agent state cannot be a shared resource");
    this.readRegistry(); this.readJournal(); // Corruption never silently resets permissions.
  }
  private assertRoot(): void {
    safeAgentPath(this.root, true);
    if (!lstatSync(this.root).isDirectory()) throw new Error("Invalid agent store directory");
  }
  private read<T>(name: string, empty: T): T {
    this.assertRoot();
    const path = safeAgentPath(join(this.root, name));
    let fd: number;
    try { fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return clone(empty); throw error; }
    try {
      const stat = fstatSync(fd);
      if (!stat.isFile() || stat.nlink !== 1 || stat.size > MAX_BYTES) throw new Error("Invalid agent store file");
      return JSON.parse(readFileSync(fd, "utf8"));
    } finally { closeSync(fd); }
  }
  private write(name: string, value: unknown): void {
    this.assertRoot();
    const path = safeAgentPath(join(this.root, name));
    const encoded = JSON.stringify(value) + "\n";
    if (Buffer.byteLength(encoded) > MAX_BYTES) throw new Error("Agent store budget exceeded");
    const tmp = join(this.root, `.pending-${randomUUID()}`);
    const fd = openSync(tmp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try {
      try { writeFileSync(fd, encoded); fsyncSync(fd); } finally { closeSync(fd); }
      this.assertRoot(); safeAgentPath(path);
      renameSync(tmp, path);
      const dir = openSync(this.root, constants.O_RDONLY | constants.O_NOFOLLOW);
      try { fsyncSync(dir); } finally { closeSync(dir); }
    } finally { try { unlinkSync(tmp); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; } }
  }
  private locked<T>(action: () => T): T {
    this.assertRoot();
    const lock = safeAgentPath(join(this.root, ".writer-lock"));
    try { mkdirSync(lock, { mode: 0o700 }); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "EEXIST") throw new Error("Agent store writer busy; no automatic stale-lock takeover"); throw error; }
    try { return action(); } finally { safeAgentPath(lock, true); rmdirSync(lock); }
  }
  private derived(id: string): PersonAgentPaths {
    if (!validAgentId(id)) throw new Error("Invalid agent ID");
    const root = join(this.root, "private", id);
    const paths = { workspace: safeAgentPath(join(root, "workspace")), memoryDir: safeAgentPath(join(root, "memory")), runtimeDir: safeAgentPath(join(root, "runtime")) };
    for (const path of Object.values(paths)) {
      try { if (!lstatSync(path).isDirectory()) throw new Error("Agent private root is not a directory"); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    }
    return paths;
  }
  private validateAgent(value: unknown): PersonAgent {
    keys(value, ["id", "name", "role", "pluginId", "model", "accountBindingId", "workspace", "memoryDir", "allowedTools", "directories", "teamIds"]);
    if (!validAgentId(value.id) || !["hermes", "openclaw"].includes(value.pluginId)) throw new Error("Invalid person agent identity");
    const paths = this.derived(value.id);
    if (value.workspace !== paths.workspace || value.memoryDir !== paths.memoryDir) throw new Error("Agent private roots are host-derived");
    const directories = normalizeDirectoryGrants(value.directories);
    const own = [{ path: paths.workspace, access: "write" as const }, { path: paths.memoryDir, access: "write" as const }];
    const permitted = [...own, ...this.resourceRoots];
    if (directories.some(g => !permitted.some(p => pathWithin(p.path, g.path) && (p.access === "write" || g.access === "read"))))
      throw new Error("Directory grant exceeds host-selected resources or enters private agent state");
    return { id: value.id, name: text(value.name, "agent name", 80), role: text(value.role, "agent role", 512), pluginId: value.pluginId,
      ...(value.model !== undefined ? { model: text(value.model, "model", 128) } : {}),
      ...(value.accountBindingId !== undefined ? { accountBindingId: text(value.accountBindingId, "account binding", 256) } : {}),
      workspace: paths.workspace, memoryDir: paths.memoryDir,
      allowedTools: validateTools(value.allowedTools), directories, teamIds: ids(value.teamIds, MAX_TEAMS) };
  }
  private readRegistry(): AgentRegistry {
    const state = this.read<AgentRegistry>("registry.json", { version: 1, revision: 0, agents: [], teams: [] });
    keys(state, ["version", "revision", "defaultAgentId", "agents", "teams"]);
    revision(state.revision);
    if (state.version !== 1 || !Array.isArray(state.agents) || state.agents.length > MAX_AGENTS || !Array.isArray(state.teams) || state.teams.length > MAX_TEAMS) throw new Error("Damaged agent registry");
    state.agents = state.agents.map(a => this.validateAgent(a));
    if (new Set(state.agents.map(a => a.id)).size !== state.agents.length) throw new Error("Duplicate agent ID");
    state.teams = state.teams.map(team => {
      keys(team, ["id", "name", "agentIds"]);
      if (!validAgentId(team.id)) throw new Error("Invalid team ID");
      return { id: team.id, name: text(team.name, "team name", 80), agentIds: ids(team.agentIds, MAX_AGENTS) };
    });
    if (new Set(state.teams.map(t => t.id)).size !== state.teams.length || state.teams.some(t => !t.agentIds.length || t.agentIds.some(id => !state.agents.some(a => a.id === id)))) throw new Error("Damaged agent teams");
    if (state.agents.some(a => JSON.stringify(a.teamIds) !== JSON.stringify(state.teams.filter(t => t.agentIds.includes(a.id)).map(t => t.id).sort()))) throw new Error("Team membership mismatch");
    if (state.agents.length && !state.agents.some(a => a.id === state.defaultAgentId) || !state.agents.length && state.defaultAgentId !== undefined) throw new Error("Invalid default agent");
    return state;
  }
  private mutate(expectedRevision: number, action: (state: AgentRegistry) => void): AgentRegistry {
    revision(expectedRevision);
    return this.locked(() => {
      const state = this.readRegistry();
      if (state.revision !== expectedRevision) throw new Error("Agent revision conflict");
      action(state); state.revision++;
      revision(state.revision); this.write("registry.json", state); return clone(state);
    });
  }
  list(): AgentRegistry { return clone(this.readRegistry()); }
  paths(id: string): PersonAgentPaths {
    if (!this.readRegistry().agents.some(a => a.id === id)) throw new Error("Unknown agent ID");
    return this.derived(id);
  }
  create(input: PersonAgentInput, expectedRevision: number): AgentRegistry {
    keys(input, ["id", "name", "role", "pluginId", "model", "accountBindingId", "allowedTools", "directories"]);
    return this.mutate(expectedRevision, state => {
      if (state.agents.length >= MAX_AGENTS) throw new Error("Agent count budget exceeded");
      const id = input.id ?? `agent-${randomUUID()}`;
      if (state.agents.some(a => a.id === id)) throw new Error("Agent ID already exists");
      const paths = this.derived(id);
      const agent = this.validateAgent({ ...input, id, workspace: paths.workspace, memoryDir: paths.memoryDir, teamIds: [], directories: input.directories ?? [] });
      for (const path of Object.values(paths)) { safeAgentPath(path); mkdirSync(path, { recursive: true, mode: 0o700 }); safeAgentPath(path, true); }
      state.agents.push(agent); state.defaultAgentId ??= id;
    });
  }
  update(id: string, patch: PersonAgentPatch, expectedRevision: number): AgentRegistry {
    keys(patch, ["name", "role", "pluginId", "model", "accountBindingId", "allowedTools", "directories", "clear"]);
    const { clear = [], ...selected } = patch;
    if (!Array.isArray(clear) || clear.length > 2 || new Set(clear).size !== clear.length
      || clear.some(k => !["model", "accountBindingId"].includes(k) || patch[k] !== undefined))
      throw new Error("Invalid agent clear fields");
    return this.mutate(expectedRevision, state => {
      const index = state.agents.findIndex(a => a.id === id);
      if (index < 0) throw new Error("Unknown agent ID");
      const candidate = { ...state.agents[index], ...selected };
      for (const key of clear) delete candidate[key];
      state.agents[index] = this.validateAgent(candidate);
    });
  }
  default(id: string, expectedRevision: number): AgentRegistry {
    return this.mutate(expectedRevision, state => {
      if (!state.agents.some(a => a.id === id)) throw new Error("Unknown default agent ID");
      state.defaultAgentId = id;
    });
  }
  createTeam(input: { id?: string; name: string; agentIds: string[] }, expectedRevision: number): AgentRegistry {
    keys(input, ["id", "name", "agentIds"]);
    return this.mutate(expectedRevision, state => {
      const id = input.id ?? `team-${randomUUID()}`;
      if (!validAgentId(id) || state.teams.some(t => t.id === id) || state.teams.length >= MAX_TEAMS) throw new Error("Invalid team identity or budget");
      const members = ids(input.agentIds, MAX_AGENTS);
      if (!members.length || members.some(id => !state.agents.some(a => a.id === id))) throw new Error("Unknown team member");
      state.teams.push({ id, name: text(input.name, "team name", 80), agentIds: members });
      for (const agent of state.agents) if (members.includes(agent.id)) agent.teamIds = [...agent.teamIds, id].sort();
    });
  }
  updateTeam(id: string, patch: { name?: string; agentIds?: string[] }, expectedRevision: number): AgentRegistry {
    keys(patch, ["name", "agentIds"]);
    return this.mutate(expectedRevision, state => {
      const team = state.teams.find(t => t.id === id);
      if (!team) throw new Error("Unknown team ID");
      const members = patch.agentIds === undefined ? team.agentIds : ids(patch.agentIds, MAX_AGENTS);
      if (!members.length || members.some(id => !state.agents.some(a => a.id === id))) throw new Error("Unknown team member");
      team.name = patch.name === undefined ? team.name : text(patch.name, "team name", 80); team.agentIds = members;
      for (const agent of state.agents) agent.teamIds = state.teams.filter(t => t.agentIds.includes(agent.id)).map(t => t.id).sort();
    });
  }
  private mint(agent: PersonAgent, state: AgentRegistry, selected: ScopeSelection, chain: string[], priorDenied: string[] = []): EffectiveAgentScope {
    const deniedRoots = [...new Set([...priorDenied, ...this.protectedRoots, ...state.agents.filter(a => a.id !== agent.id).map(a => join(this.root, "private", a.id)),
      join(this.root, "registry.json"), join(this.root, "journal.json"), join(this.root, ".writer-lock"), this.derived(agent.id).runtimeDir])].sort();
    const scope: EffectiveAgentScope = { version: 1, agentId: agent.id, revision: state.revision, chain, ...selected, deniedRoots };
    Object.freeze(scope.allowedTools); for (const grant of scope.directories) Object.freeze(grant); Object.freeze(scope.directories); Object.freeze(scope.knowledgeIds); Object.freeze(scope.chain); Object.freeze(scope.deniedRoots); Object.freeze(scope);
    this.scopes.add(scope); return scope;
  }
  resolveScope(id: string, requestScope?: ScopeSelection): EffectiveAgentScope {
    const state = this.readRegistry(), agent = state.agents.find(a => a.id === id);
    if (!agent) throw new Error("Unknown agent ID");
    const grants = { allowedTools: agent.allowedTools, directories: [
      { path: agent.workspace, access: "write" as const },
      ...(agent.allowedTools.includes("memory") ? [{ path: agent.memoryDir, access: "write" as const }] : []), ...agent.directories],
      knowledgeIds: this.readJournal().entries.filter(entry => entry.kind === "shared-knowledge" ? entry.fromAgentId === id || entry.toAgentIds?.includes(id)
        : entry.allAgents === true || entry.agentId === id).map(entry => entry.id) };
    // Normalize duplicate own grants through intersection rather than treating them as extra authority.
    grants.directories = [...new Map(grants.directories.map(g => [g.path, g])).values()];
    return this.mint(agent, state, requestScope ? intersectAgentScopes(grants, requestScope) : intersectAgentScopes(grants), [id]);
  }
  delegateScope(origin: EffectiveAgentScope, handoff: ScopeSelection, teammateId: string): EffectiveAgentScope {
    const state = this.readRegistry();
    if (!this.scopes.has(origin) || origin.revision !== state.revision || !origin.allowedTools.includes("delegation")) throw new Error("Forged, stale or unauthorized delegation scope");
    const from = state.agents.find(a => a.id === origin.agentId), to = state.agents.find(a => a.id === teammateId);
    if (!from || !to || !from.teamIds.some(id => to.teamIds.includes(id)) || origin.chain.length >= 8) throw new Error("Unknown teammate or delegation depth exceeded");
    const target = this.resolveScope(teammateId);
    return this.mint(to, state, intersectAgentScopes(origin, handoff, target), [...origin.chain, teammateId], origin.deniedRoots);
  }
  private readJournal(): AgentKnowledgeJournal {
    const journal = this.read<AgentKnowledgeJournal>("journal.json", { version: 1, revision: 0, entries: [] });
    keys(journal, ["version", "revision", "entries"]); revision(journal.revision);
    if (journal.version !== 1 || !Array.isArray(journal.entries) || journal.entries.length > MAX_JOURNAL) throw new Error("Damaged agent knowledge journal");
    const known = new Set(this.readRegistry().agents.map(a => a.id));
    for (const entry of journal.entries) {
      keys(entry, ["id", "kind", "text", "createdAt", "agentId", "allAgents", "fromAgentId", "toAgentIds"]);
      if (!validAgentId(entry.id) || !["preference", "shared-knowledge"].includes(entry.kind) || typeof entry.text !== "string" || !entry.text.trim() || entry.text.length > 8192 || entry.text.includes("\0")
        || typeof entry.createdAt !== "string" || !Number.isFinite(Date.parse(entry.createdAt))) throw new Error("Damaged agent knowledge entry");
      if (entry.kind === "preference" ? !(entry.allAgents === true && entry.agentId === undefined || validAgentId(entry.agentId) && entry.allAgents === undefined)
        || entry.fromAgentId !== undefined || entry.toAgentIds !== undefined : !validAgentId(entry.fromAgentId) || !ids(entry.toAgentIds, MAX_AGENTS).length || entry.agentId !== undefined || entry.allAgents !== undefined)
        throw new Error("Damaged knowledge audience");
      if (entry.agentId !== undefined && !known.has(entry.agentId) || entry.fromAgentId !== undefined && !known.has(entry.fromAgentId)
        || entry.toAgentIds?.some(id => !known.has(id))) throw new Error("Unknown stored knowledge audience");
    }
    if (new Set(journal.entries.map(e => e.id)).size !== journal.entries.length) throw new Error("Duplicate knowledge entry");
    return journal;
  }
  journal(): AgentKnowledgeJournal { return clone(this.readJournal()); }
  private append(entry: Omit<AgentKnowledgeEntry, "id" | "createdAt">, expectedRevision: number): AgentKnowledgeJournal {
    revision(expectedRevision);
    return this.locked(() => {
      this.readRegistry(); const journal = this.readJournal();
      if (journal.revision !== expectedRevision) throw new Error("Knowledge revision conflict");
      if (journal.entries.length >= MAX_JOURNAL || typeof entry.text !== "string" || !entry.text.trim() || entry.text.length > 8192 || entry.text.includes("\0")) throw new Error("Knowledge entry budget exceeded");
      journal.entries.push({ ...entry, id: `entry-${randomUUID()}`, createdAt: new Date().toISOString() }); journal.revision++;
      this.write("journal.json", journal); return clone(journal);
    });
  }
  remember(input: { agentId?: string; allAgents?: true; text: string }, expectedJournalRevision: number): AgentKnowledgeJournal {
    keys(input, ["agentId", "allAgents", "text"]);
    if (!(input.allAgents === true && input.agentId === undefined || input.allAgents === undefined && this.readRegistry().agents.some(a => a.id === input.agentId))) throw new Error("Invalid preference audience");
    return this.append({ ...input, kind: "preference" }, expectedJournalRevision);
  }
  shareKnowledge(input: { fromAgentId: string; toAgentIds: string[]; text: string }, expectedJournalRevision: number): AgentKnowledgeJournal {
    keys(input, ["fromAgentId", "toAgentIds", "text"]);
    const state = this.readRegistry(), toAgentIds = ids(input.toAgentIds, MAX_AGENTS);
    if (!state.agents.some(a => a.id === input.fromAgentId) || !toAgentIds.length || toAgentIds.some(id => !state.agents.some(a => a.id === id))) throw new Error("Unknown knowledge audience");
    return this.append({ ...input, toAgentIds, kind: "shared-knowledge" }, expectedJournalRevision);
  }
  /** For direct conversations the host may project preferences/shared snapshots as untrusted reference text.
   * Delegated calls receive shared snapshots only, never the teammate's private memory journal.
   */
  knowledgeFor(id: string, scope?: EffectiveAgentScope): AgentKnowledgeEntry[] {
    this.paths(id);
    if (scope && (!this.scopes.has(scope) || scope.agentId !== id || scope.revision !== this.readRegistry().revision)) throw new Error("Forged or stale memory scope");
    if (scope && !scope.allowedTools.includes("memory")) return [];
    return this.readJournal().entries.filter(entry => (!scope || scope.knowledgeIds?.includes(entry.id)) && (entry.kind === "shared-knowledge" ? entry.toAgentIds?.includes(id)
      : entry.allAgents === true || entry.agentId === id && (!scope || scope.chain.length === 1 && agentScopeAllowsPath(scope, this.derived(id).memoryDir, "read")))).map(clone);
  }
}
