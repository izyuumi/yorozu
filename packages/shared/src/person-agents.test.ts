import { expect, test } from "vitest";
import { parsePersonAgentControl, parsePersonAgentRegistry, type PersonAgentControlData, type PersonAgentRegistry } from "./person-agents.js";

const agent = { id: "agent-a", name: "Ada", role: "Keep notes", pluginId: "hermes" as const,
  workspace: "/tmp/agent-a/workspace", memoryDir: "/tmp/agent-a/memory",
  allowedTools: ["file", "memory"] as const, directories: [], teamIds: [] };
const catalog = (): PersonAgentRegistry => ({ version: 1, revision: 2, defaultAgentId: agent.id,
  agents: [{ ...agent, allowedTools: [...agent.allowedTools] }], teams: [], journalRevision: 3 });

test("person-agent catalog and all settings actions share the bounded wire shape", () => {
  expect(parsePersonAgentRegistry(catalog())).toEqual(catalog());
  const requests: PersonAgentControlData[] = [
    { version: 1, expectedRevision: 2, action: "create", agent: { name: "Ada", role: "Keep notes", pluginId: "hermes", allowedTools: ["file"] } },
    { version: 1, expectedRevision: 2, action: "update", agentId: "agent-a", patch: { model: "subscription/model" } },
    { version: 1, expectedRevision: 2, action: "update", agentId: "agent-a", patch: { clear: ["model", "accountBindingId"] } },
    { version: 1, expectedRevision: 2, action: "default", agentId: "agent-a" },
    { version: 1, expectedRevision: 2, action: "create-team", team: { name: "Notes", agentIds: ["agent-a"] } },
    { version: 1, expectedRevision: 2, action: "update-team", teamId: "team-a", patch: { agentIds: ["agent-a"] } },
    { version: 1, expectedRevision: 2, action: "remember", expectedJournalRevision: 3, preference: { allAgents: true, text: "Use short paragraphs.\nAvoid repetition." } },
    { version: 1, expectedRevision: 2, action: "share-knowledge", expectedJournalRevision: 3, knowledge: { fromAgentId: "agent-a", toAgentIds: ["agent-b"], text: "The meeting is on Tuesday." } },
  ];
  for (const request of requests) expect(parsePersonAgentControl(JSON.parse(JSON.stringify(request)))).toEqual(request);
});

test("settings controls reject credentials, grants in preferences, wrong audiences and malformed bounds", () => {
  const create = { version: 1, expectedRevision: 2, action: "create", agent: { name: "Ada", role: "Keep notes", pluginId: "hermes", allowedTools: ["file"] } };
  const invalid = [
    { ...create, version: 2 }, { ...create, expectedRevision: -1 }, { ...create, expectedRevision: Number.MAX_SAFE_INTEGER + 1 },
    { ...create, agent: { ...create.agent, apiKey: "synthetic" } },
    { ...create, agent: { ...create.agent, workspace: "/tmp/arbitrary" } },
    { ...create, agent: { ...create.agent, name: "😀".repeat(41) } },
    { ...create, agent: { ...create.agent, allowedTools: ["file", "file"] } },
    { ...create, agent: { ...create.agent, allowedTools: ["anything"] } },
    { ...create, agent: { ...create.agent, model: null } },
    { version: 1, expectedRevision: 2, action: "update", agentId: "agent-a", patch: { clear: ["model"], model: "conflict" } },
    { version: 1, expectedRevision: 2, action: "update", agentId: "agent-a", patch: { clear: ["model", "model"] } },
    { version: 1, expectedRevision: 2, action: "update", agentId: "agent-a", patch: { clear: ["directories"] } },
    { ...create, agent: { ...create.agent, directories: [{ path: "/tmp/../outside", access: "write" }] } },
    { version: 1, expectedRevision: 2, action: "default", agentId: "Unknown Agent" },
    { version: 1, expectedRevision: 2, action: "default", agentId: "agent-a\n" },
    { version: 1, expectedRevision: 2, action: "remember", preference: { allAgents: true, text: "Short answers" } },
    { version: 1, expectedRevision: 2, action: "remember", expectedJournalRevision: 3, preference: { allAgents: true, agentId: "agent-a", text: "Short answers" } },
    { version: 1, expectedRevision: 2, action: "remember", expectedJournalRevision: 3, preference: { allAgents: true, text: "Short answers", allowedTools: ["terminal"] } },
    { version: 1, expectedRevision: 2, action: "share-knowledge", expectedJournalRevision: 3, knowledge: { fromAgentId: "agent-a", toAgentIds: [], text: "Note" } },
  ];
  for (const request of invalid) expect(() => parsePersonAgentControl(request)).toThrow();
});

test("catalog validates default and team membership rather than trusting labels", () => {
  const team = { id: "team-a", name: "Notes", agentIds: ["agent-a"] };
  const valid = catalog();
  valid.agents[0].teamIds = ["team-a"]; valid.teams = [team];
  expect(parsePersonAgentRegistry(valid)).toEqual(valid);
  for (const invalid of [
    { ...catalog(), defaultAgentId: "missing" },
    { ...catalog(), agents: [catalog().agents[0], catalog().agents[0]] },
    { ...catalog(), teams: [team] },
    { ...catalog(), teams: [{ ...team, agentIds: ["missing"] }] },
    { ...catalog(), journalRevision: -1 },
    { ...catalog(), lastControlResult: { operationId: "request", revision: 2, status: "queued" } },
  ]) expect(() => parsePersonAgentRegistry(invalid)).toThrow();
});
