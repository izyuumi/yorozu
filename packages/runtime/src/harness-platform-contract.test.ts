import { expect, test } from "vitest";
import { validHarnessEvent, validHarnessExtensions, validHarnessLifecycle } from "./harness-contract.js";

const event = (kind: string, data: unknown) => ({ protocolVersion: 1, eventId: "event-1", conversationId: "conversation-a", kind, data });
const action = { version: 1, requestId: "request-1", sessionId: "native-session", kind: "approval", title: "Continue?", choices: [{ id: "yes", label: "Continue" }] };
const message = { version: 1, messageId: "message-1", sessionId: "native-session", toAgentId: "agent-b", text: "Please check the draft" };

test("extension negotiation preserves legacy events while rejecting incomplete or version-mismatched claims", () => {
  expect(validHarnessEvent(event("assistant.update", { text: "Legacy reply" }))).toBe(true);
  const extensions = { version: 1, connectedLifecycle: true, conversationActions: true, autonomousEvents: false, agentMessaging: true };
  expect(validHarnessExtensions(extensions)).toBe(true);
  for (const invalid of [{ ...extensions, version: 2 }, { ...extensions, agentMessaging: undefined }, { ...extensions, autoApprove: true }])
    expect(validHarnessExtensions(invalid)).toBe(false);
  expect(validHarnessLifecycle({ version: 1, mode: "managed" })).toBe(true);
  expect(validHarnessLifecycle({ version: 1, mode: "connected", connectionId: "connection-a" })).toBe(true);
  for (const invalid of [{ version: 1, mode: "connected" }, { version: 1, mode: "managed", connectionId: "connection-a" },
    { version: 1, mode: "connected", connectionId: "connection-a", endpoint: "ws://localhost:1" }])
    expect(validHarnessLifecycle(invalid)).toBe(false);
});

test("adapter actions and peer messages carry session provenance without claiming host or sender identity", () => {
  expect(validHarnessEvent(event("action.open", action))).toBe(true);
  expect(validHarnessEvent(event("agent.message", message))).toBe(true);
  for (const invalid of [
    event("action.open", { ...action, origin: { agentId: "forged" } }),
    event("action.open", { ...action, rule: { decision: "always" } }),
    event("action.open", { ...action, choices: [action.choices[0], action.choices[0]] }),
    event("agent.message", { ...message, fromAgentId: "another-agent" }),
    event("agent.message", { ...message, origin: { bindingEpoch: "forged" } }),
    { ...event("agent.message", message), bindingEpoch: "forged" },
  ]) expect(validHarnessEvent(invalid)).toBe(false);
});
