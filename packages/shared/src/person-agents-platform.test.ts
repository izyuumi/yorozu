import { expect, test } from "vitest";
import { parsePersonAgentControl, parsePersonAgentRegistry, projectPersonAgentRegistry, type PersonAgentRegistry } from "./person-agents.js";
import { harnessActionAcceptsAnswer, parseHarnessAction, parseHarnessActionAnswer, parseAgentExchange,
  parseAgentExchangeStatus, projectPlatformEvent, type YorozuEvent, type HarnessOrigin } from "./events.js";

const origin: HarnessOrigin = { version: 1, agentId: "agent-a", pluginId: "hermes", conversationId: "conversation-a", sessionId: "host-alias", bindingEpoch: "epoch-1" };
const action = { version: 1, requestId: "native-action", origin, kind: "approval", title: "Send the note?",
  choices: [{ id: "yes", label: "Send" }, { id: "no", label: "Decline" }], state: "pending", ui: { targetId: "ui-1", label: "Open harness" } };
const create = { version: 1, expectedRevision: 0, action: "create", agent: { name: "Ada", role: "Secretary", pluginId: "openclaw", allowedTools: [] } };

test("legacy managed controls and opaque connection references remain compatible without exposing execution details", () => {
  expect(parsePersonAgentControl(create)).toEqual(create);
  const connected = { ...create, agent: { ...create.agent, runtime: { version: 1, mode: "connected", connectionId: "connection-a" } } };
  expect(parsePersonAgentControl(connected)).toEqual(connected);
  for (const runtime of [
    { version: 1, mode: "connected" }, { version: 2, mode: "managed" },
    { version: 1, mode: "managed", connectionId: "connection-a" },
    { version: 1, mode: "connected", connectionId: "connection-a", endpoint: "ws://localhost:1" },
    { version: 1, mode: "connected", connectionId: "connection-a", token: "synthetic" },
    { version: 1, mode: "connected", connectionId: "connection-a", command: "/tmp/agent" },
  ]) expect(() => parsePersonAgentControl({ ...create, agent: { ...create.agent, runtime } })).toThrow();
});

test("catalog default must refer to an available managed harness", () => {
  const registry = { version: 1, revision: 0, agents: [], teams: [], harnesses: [
    { id: "hermes", label: "Hermes", available: true, modes: ["managed"], capabilities: ["harness-actions-v1"] }
  ], defaultHarnessId: "hermes", connections: [{ id: "connection-a", pluginId: "openclaw", label: "Existing agent", available: true }] };
  expect(parsePersonAgentRegistry(registry)).toEqual(registry);
  for (const bad of [
    { ...registry, defaultHarnessId: "openclaw" },
    { ...registry, harnesses: [{ ...registry.harnesses[0], available: false }] },
    { ...registry, harnesses: [{ ...registry.harnesses[0], modes: ["connected"] }] },
    { ...registry, connections: [{ ...registry.connections[0], credential: "synthetic" }] },
    { ...registry, connections: [registry.connections[0], registry.connections[0]] },
  ]) expect(() => parsePersonAgentRegistry(bad)).toThrow();
});

test("native answers bind full origin and one explicitly offered choice or opaque UI target", () => {
  const pending = parseHarnessAction(action);
  const answer = parseHarnessActionAnswer({ version: 1, requestId: "native-action", origin, choiceId: "yes" });
  expect(harnessActionAcceptsAnswer(pending, answer)).toBe(true);
  for (const wrong of [
    { ...answer, origin: { ...origin, bindingEpoch: "retired-epoch" } },
    { ...answer, origin: { ...origin, sessionId: "another-session" } },
    { ...answer, origin: { ...origin, agentId: "agent-b" } },
    { ...answer, choiceId: "always" }, { ...answer, text: "Allow everything" },
  ]) expect(harnessActionAcceptsAnswer(pending, wrong)).toBe(false);
  expect(harnessActionAcceptsAnswer(pending, parseHarnessActionAnswer({ version: 1, requestId: "native-action", origin, uiTargetId: "ui-1" }))).toBe(true);
  expect(harnessActionAcceptsAnswer(pending, parseHarnessActionAnswer({ version: 1, requestId: "native-action", origin, uiTargetId: "https://example.test" }))).toBe(false);
  for (const bad of [ { ...answer, rule: { decision: "always" } }, { ...answer, uiTargetId: "ui-1" }, { ...answer, origin: { ...origin, token: "synthetic" } } ])
    expect(() => parseHarnessActionAnswer(bad)).toThrow();
});

test("agent exchanges reject forged sender and keep host acceptance distinct from execution", () => {
  const exchange = { version: 1, exchangeId: "exchange-1", messageId: "native-message-1", deliveryId: "delivery-1", origin,
    fromAgentId: "agent-a", toAgentId: "agent-b", text: "Please check the draft", createdAt: 1 };
  expect(parseAgentExchange(exchange)).toEqual(exchange);
  for (const bad of [ { ...exchange, fromAgentId: "agent-b" }, { ...exchange, createdAt: -1 }, { ...exchange, rule: { decision: "always" } } ])
    expect(() => parseAgentExchange(bad)).toThrow();
  const receipt = { version: 1, exchangeId: "exchange-1", messageId: "native-message-1", deliveryId: "delivery-1", delivery: "accepted", execution: "not-started" };
  expect(parseAgentExchangeStatus(receipt)).toEqual(receipt);
  expect(parseAgentExchangeStatus({ ...receipt, delivery: "unknown", execution: "unknown", attemptId: "attempt-1" }).delivery).toBe("unknown");
  for (const bad of [ { ...receipt, delivery: "delivered", execution: "completed", handoff: "not-submitted" }, { ...receipt, delivery: "rejected", execution: "running" } ])
    expect(() => parseAgentExchangeStatus(bad)).toThrow();
});

test("legacy peer projection hides new ownership fields and separate exchange history without mutating retained data", () => {
  const registry: PersonAgentRegistry = { version: 1, revision: 2, defaultAgentId: "agent-a", teams: [], agents: [{
    id: "agent-a", name: "Ada", role: "Secretary", pluginId: "hermes", allowedTools: [], directories: [], teamIds: [],
    workspace: "/tmp/agent-a/workspace", memoryDir: "/tmp/agent-a/memory", conversationId: "conversation-a",
    runtime: { version: 1, mode: "managed" }
  }], harnesses: [{ id: "hermes", label: "Hermes", available: true, modes: ["managed"], capabilities: [] }], defaultHarnessId: "hermes", connections: [] };
  const legacy = projectPersonAgentRegistry(registry, ["person-agents-v1"])!;
  expect(legacy.agents[0]).not.toHaveProperty("runtime"); expect(legacy.agents[0]).not.toHaveProperty("conversationId");
  expect(legacy).not.toHaveProperty("harnesses"); expect(legacy).not.toHaveProperty("connections");
  expect(registry.agents[0].conversationId).toBe("conversation-a");
  expect(projectPersonAgentRegistry(registry, [])).toBeUndefined();
  expect(projectPersonAgentRegistry(registry, ["person-agents-v1", "person-agent-runtime-v1"])).toBe(registry);
  const base = { id: "snapshot-1", threadId: "main", ts: 1, agentId: "host", syncCursor: "opaque-cursor" };
  const list: YorozuEvent = { ...base, kind: "thread_list", data: { personAgents: registry, threads: [
    { id: "conversation-a", title: "Ada", archived: false, lastActivity: 1 },
    { id: "agent-exchange-1", title: "Agent exchange", archived: false, lastActivity: 1,
      personAgentExchange: { version: 1, exchangeId: "exchange-1", fromAgentId: "agent-a", toAgentId: "agent-b" } }
  ] } };
  const projected = projectPlatformEvent(list, ["person-agents-v1"]);
  expect(projected?.kind === "thread_list" && projected.data.threads.map(t => t.id)).toEqual(["conversation-a"]);
  expect(projected?.syncCursor).toBe("opaque-cursor");
  const nativeAction: YorozuEvent = { ...base, kind: "harness_action", data: parseHarnessAction(action) };
  const user: YorozuEvent = { ...base, id: "message-1", kind: "message", data: { role: "user", text: "Hi" } };
  const page: YorozuEvent = { ...base, kind: "sync_delta", data: { events: [user, nativeAction], current: [nativeAction] } };
  const oldPage = projectPlatformEvent(page, []);
  expect(oldPage?.kind === "sync_delta" && oldPage.data.events).toEqual([user]);
  expect(oldPage?.kind === "sync_delta" && oldPage.data.current).toEqual([]);
  expect(projectPlatformEvent(nativeAction, ["harness-actions-v1"])).toBe(nativeAction);
});
