/** Host-owned configuration identifiers and text only; account bindings contain no credentials. */
export const PERSON_AGENT_TOOLS = ["file", "terminal", "delegation", "memory", "web", "browser", "team", "computer"] as const;
export type PersonAgentTool = typeof PERSON_AGENT_TOOLS[number];
export type PersonAgentPlugin = "hermes" | "openclaw";
export interface PersonAgentDirectoryGrant { path: string; access: "read" | "write" }
export interface PersonAgentInput {
  id?: string; name: string; role: string; pluginId: PersonAgentPlugin;
  model?: string; accountBindingId?: string;
  allowedTools: PersonAgentTool[]; directories?: PersonAgentDirectoryGrant[];
}
export type PersonAgentPatch = Partial<Omit<PersonAgentInput, "id">> & { clear?: Array<"model" | "accountBindingId"> };
export interface PersonAgent extends Omit<PersonAgentInput, "id" | "directories"> {
  id: string; workspace: string; memoryDir: string;
  directories: PersonAgentDirectoryGrant[]; teamIds: string[];
}
export interface PersonAgentTeam { id: string; name: string; agentIds: string[] }
export interface PersonAgentTeamInput { id?: string; name: string; agentIds: string[] }
export interface PersonAgentTeamPatch { name?: string; agentIds?: string[] }
export type PersonAgentPreference = { text: string } & (
  | { agentId: string; allAgents?: never } | { allAgents: true; agentId?: never });
export interface PersonAgentSharedKnowledge { fromAgentId: string; toAgentIds: string[]; text: string }
export interface PersonAgentControlResult {
  operationId: string; status: "applied" | "rejected" | "unknown"; revision: number; reason?: string;
}
export interface PersonAgentRegistry {
  version: 1; revision: number; defaultAgentId?: string; agents: PersonAgent[]; teams: PersonAgentTeam[];
  journalRevision?: number; lastControlResult?: PersonAgentControlResult;
}
type ControlBase = { version: 1; expectedRevision: number };
/** The containing event ID is the operation ID. These controls never belong to chat history. */
export type PersonAgentControlData = ControlBase & (
  | { action: "create"; agent: PersonAgentInput }
  | { action: "update"; agentId: string; patch: PersonAgentPatch }
  | { action: "default"; agentId: string }
  | { action: "create-team"; team: PersonAgentTeamInput }
  | { action: "update-team"; teamId: string; patch: PersonAgentTeamPatch }
  | { action: "remember"; expectedJournalRevision: number; preference: PersonAgentPreference }
  | { action: "share-knowledge"; expectedJournalRevision: number; knowledge: PersonAgentSharedKnowledge }
);

const AGENT_KEYS = ["name", "role", "pluginId", "model", "accountBindingId", "allowedTools", "directories"];
function object(value: unknown, allowed: string[]): asserts value is Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).some(k => !allowed.includes(k)))
    throw new Error("Invalid person-agent fields");
}
function text(value: unknown, max: number): asserts value is string {
  if (typeof value !== "string" || !value.trim() || value.length > max || /[\0\r\n]/.test(value))
    throw new Error("Invalid person-agent text");
}
export function validPersonAgentId(value: unknown): value is string {
  return typeof value === "string" && /^[a-z][a-z0-9_-]{0,63}$/.test(value) && !/[\r\n]/.test(value);
}
function id(value: unknown): asserts value is string {
  if (!validPersonAgentId(value)) throw new Error("Invalid person-agent identifier");
}
function revision(value: unknown): asserts value is number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) throw new Error("Invalid person-agent revision");
}
function ids(value: unknown, max: number, nonempty = false): asserts value is string[] {
  if (!Array.isArray(value) || value.length > max || nonempty && !value.length ||
      value.some(v => !validPersonAgentId(v)) || new Set(value).size !== value.length)
    throw new Error("Invalid person-agent identifiers");
}
function path(value: unknown): asserts value is string {
  text(value, 4096);
  if (!value.startsWith("/") || value.split(/[\\/]/).includes("..")) throw new Error("Invalid person-agent path");
}
function directories(value: unknown): asserts value is PersonAgentDirectoryGrant[] {
  if (!Array.isArray(value) || value.length > 64) throw new Error("Invalid person-agent directories");
  const seen = new Set<string>();
  for (const grant of value) {
    object(grant, ["path", "access"]); path(grant.path);
    if (!["read", "write"].includes(grant.access as string) || seen.has(grant.path))
      throw new Error("Invalid person-agent directory grant");
    seen.add(grant.path);
  }
}
function tools(value: unknown): asserts value is PersonAgentTool[] {
  if (!Array.isArray(value) || value.length > PERSON_AGENT_TOOLS.length || new Set(value).size !== value.length ||
      value.some(tool => !PERSON_AGENT_TOOLS.includes(tool))) throw new Error("Invalid person-agent tools");
}
function config(value: unknown, patch = false): void {
  object(value, patch ? [...AGENT_KEYS, "clear"] : ["id", ...AGENT_KEYS]);
  if (!patch || value.name !== undefined) text(value.name, 80);
  if (!patch || value.role !== undefined) text(value.role, 512);
  if ((!patch || value.pluginId !== undefined) && !["hermes", "openclaw"].includes(value.pluginId as string))
    throw new Error("Invalid person-agent plugin");
  if (value.id !== undefined) id(value.id);
  if (value.model !== undefined) text(value.model, 128);
  if (value.accountBindingId !== undefined) text(value.accountBindingId, 256);
  if (patch && value.clear !== undefined && (!Array.isArray(value.clear) || value.clear.length > 2
    || new Set(value.clear).size !== value.clear.length || value.clear.some(k => !["model", "accountBindingId"].includes(k) || value[k] !== undefined)))
    throw new Error("Invalid person-agent clear fields");
  if (!patch || value.allowedTools !== undefined) tools(value.allowedTools);
  if (value.directories !== undefined) directories(value.directories);
}
function team(value: unknown, patch = false): void {
  object(value, patch ? ["name", "agentIds"] : ["id", "name", "agentIds"]);
  if (value.id !== undefined) id(value.id);
  if (!patch || value.name !== undefined) text(value.name, 80);
  if (!patch || value.agentIds !== undefined) ids(value.agentIds, 64, true);
}
function knowledgeText(value: unknown): void {
  if (typeof value !== "string" || !value.trim() || value.length > 8192 || value.includes("\0"))
    throw new Error("Invalid person-agent knowledge text");
}

/** Structural admission only. The host store still checks authority, paths, membership and CAS. */
export function parsePersonAgentControl(value: unknown): PersonAgentControlData {
  object(value, ["version", "expectedRevision", "action", "agent", "agentId", "patch", "team", "teamId",
    "expectedJournalRevision", "preference", "knowledge"]);
  if (value.version !== 1) throw new Error("Unsupported person-agent control version");
  revision(value.expectedRevision);
  const base = ["version", "expectedRevision", "action"];
  switch (value.action) {
    case "create": object(value, [...base, "agent"]); config(value.agent); break;
    case "update": object(value, [...base, "agentId", "patch"]); id(value.agentId); config(value.patch, true); break;
    case "default": object(value, [...base, "agentId"]); id(value.agentId); break;
    case "create-team": object(value, [...base, "team"]); team(value.team); break;
    case "update-team": object(value, [...base, "teamId", "patch"]); id(value.teamId); team(value.patch, true); break;
    case "remember":
      object(value, [...base, "expectedJournalRevision", "preference"]); revision(value.expectedJournalRevision);
      object(value.preference, ["agentId", "allAgents", "text"]);
      knowledgeText(value.preference.text);
      if (value.preference.allAgents === true && value.preference.agentId === undefined) break;
      if (value.preference.allAgents === undefined) { id(value.preference.agentId); break; }
      throw new Error("Invalid person-agent preference audience");
    case "share-knowledge":
      object(value, [...base, "expectedJournalRevision", "knowledge"]); revision(value.expectedJournalRevision);
      object(value.knowledge, ["fromAgentId", "toAgentIds", "text"]);
      id(value.knowledge.fromAgentId); ids(value.knowledge.toAgentIds, 64, true); knowledgeText(value.knowledge.text); break;
    default: throw new Error("Invalid person-agent action");
  }
  return value as PersonAgentControlData;
}

export function parsePersonAgentRegistry(value: unknown): PersonAgentRegistry {
  object(value, ["version", "revision", "defaultAgentId", "agents", "teams", "journalRevision", "lastControlResult"]);
  if (value.version !== 1) throw new Error("Unsupported person-agent registry version");
  revision(value.revision);
  if (value.journalRevision !== undefined) revision(value.journalRevision);
  if (!Array.isArray(value.agents) || value.agents.length > 64 || !Array.isArray(value.teams) || value.teams.length > 32)
    throw new Error("Invalid person-agent registry budget");
  const known = new Set<string>(), memberships = new Map<string, string[]>();
  for (const agent of value.agents) {
    object(agent, ["id", ...AGENT_KEYS, "workspace", "memoryDir", "teamIds"]);
    const { workspace, memoryDir, teamIds, ...input } = agent;
    config(input); id(agent.id); path(workspace); path(memoryDir); directories(agent.directories); ids(teamIds, 32);
    if (known.has(agent.id)) throw new Error("Duplicate person-agent identifier");
    known.add(agent.id); memberships.set(agent.id, teamIds);
  }
  const teams = new Map<string, string[]>();
  for (const entry of value.teams) {
    team(entry); id(entry.id); ids(entry.agentIds, 64, true);
    if (teams.has(entry.id) || entry.agentIds.some((agentId: string) => !known.has(agentId))) throw new Error("Invalid person-agent team");
    teams.set(entry.id, entry.agentIds);
  }
  if (known.size ? !known.has(value.defaultAgentId as string) : value.defaultAgentId !== undefined)
    throw new Error("Invalid default person agent");
  for (const [agentId, declared] of memberships) {
    const actual = [...teams].filter(([, members]) => members.includes(agentId)).map(([teamId]) => teamId).sort();
    if (JSON.stringify([...declared].sort()) !== JSON.stringify(actual)) throw new Error("Invalid person-agent membership");
  }
  if (value.lastControlResult !== undefined) {
    object(value.lastControlResult, ["operationId", "status", "revision", "reason"]);
    text(value.lastControlResult.operationId, 128); revision(value.lastControlResult.revision);
    if (!["applied", "rejected", "unknown"].includes(value.lastControlResult.status as string))
      throw new Error("Invalid person-agent control result");
    if (value.lastControlResult.reason !== undefined) text(value.lastControlResult.reason, 512);
  }
  if (Buffer.byteLength(JSON.stringify(value)) > 2 * 1024 * 1024) throw new Error("Invalid person-agent registry byte budget");
  return value as unknown as PersonAgentRegistry;
}
