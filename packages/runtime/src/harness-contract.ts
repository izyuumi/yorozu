import type { HarnessOrigin } from "@yorozu/shared";
/** Private host↔whole-harness contract. Transport IDs are never admission IDs. */
export const HARNESS_PROTOCOL_VERSION = 1;
export const HARNESS_FRAME_BYTES = 256 * 1024;
export const HARNESS_PENDING_REQUESTS = 32;
export type HarnessPluginId = "hermes" | "openclaw";
/** Optional feature contract negotiated independently of the legacy protocol envelope. */
export interface HarnessExtensions {
  version: 1; connectedLifecycle: boolean; conversationActions: boolean; autonomousEvents: boolean; agentMessaging: boolean;
}
export type HarnessLifecycle = { version: 1; mode: "managed" } | { version: 1; mode: "connected"; connectionId: string };
export interface HarnessCapabilities {
  backgroundTasks: boolean;
  targetedSteer: boolean;
  taskStop: boolean;
  approvals: boolean;
  reconnect: boolean;
  attachments: boolean;
}
export type HarnessTaskState = "running" | "waiting" | "stopping" | "completed" | "failed" | "stopped" | "unknown";
export interface HarnessTask {
  taskId: string;
  parentTaskId?: string;
  originRunId: string;
  /** Host-stamped current opaque attempt, including harness-owned continuation attempts. */
  originAttemptId?: string;
  title: string;
  state: HarnessTaskState;
  text?: string;
  canSteer: boolean;
  canStop: boolean;
}
export interface HarnessEvent {
  protocolVersion: 1;
  eventId: string;
  conversationId: string;
  runId?: string;
  attemptId?: string;
  kind: "assistant.update" | "turn.started" | "turn.terminal" | "task.changed" | "request.open" | "request.cancel" | "runtime.closed" | "capability.unavailable"
    | "action.open" | "action.cancel" | "agent.message" | "agent.message.status";
  data: Record<string, unknown>;
}
export interface HarnessReady {
  protocolVersion: 1;
  pluginId: HarnessPluginId;
  upstreamVersion: string;
  capabilities: HarnessCapabilities;
  extensions?: HarnessExtensions;
  lifecycle?: HarnessLifecycle;
}
export interface HarnessReceipt {
  status: "accepted" | "busy" | "queued" | "requested" | "rejected" | "unsupported" | "unknown";
  /** Only a local preflight may prove no upstream execution handoff occurred. */
  handoff?: "not-submitted";
  reason?: string;
}
export interface HarnessConfiguration {
  pluginId: HarnessPluginId;
  /** Trusted local configuration; never supplied by a chat/event. */
  command: string;
  args: string[];
  initialize: Record<string, unknown>;
  upstreamVersion: string;
  /** Missing means a host-managed harness. The adapter process itself is always host-owned. */
  runtime?: HarnessLifecycle;
}
export interface HarnessActionRequest {
  version: 1; requestId: string; sessionId: string; workId?: string;
  kind: "approval" | "question" | "sign-in" | "open-ui"; title: string; text?: string;
  choices: Array<{ id: string; label: string }>; allowText?: boolean; ui?: { targetId: string; label: string };
}
/** The sender identity is deliberately absent: the host derives it from the owning session. */
export interface HarnessAgentMessage {
  version: 1; messageId: string; exchangeId?: string; toAgentId: string; text: string; sessionId: string; workId?: string;
}
export interface HarnessMessageDelivery {
  version: 1; messageId: string; exchangeId: string; deliveryId: string; attemptId: string; sessionId: string;
  origin: HarnessOrigin; fromAgentId: string; toAgentId: string; text: string; createdAt: number;
}
/** Durable host mailbox admission returned to the originating native tool request. */
export interface HarnessMessageReceipt {
  version: 1; messageId: string; status: "accepted" | "rejected" | "unknown"; exchangeId?: string; reason?: string;
}
const text = (v: unknown, max = 512): v is string => typeof v === "string" && v.length > 0 && v.length <= max && !/[\0\r\n]/.test(v);
const body = (v: unknown, max: number): v is string => typeof v === "string" && v.trim().length > 0 && v.length <= max && !v.includes("\0");
const object = (v: unknown, keys: string[]): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v) && Object.keys(v).every(k => keys.includes(k));
const kinds = new Set(["assistant.update", "turn.started", "turn.terminal", "task.changed", "request.open", "request.cancel", "runtime.closed", "capability.unavailable", "action.open", "action.cancel", "agent.message", "agent.message.status"]);
export function validHarnessLifecycle(value: unknown): value is HarnessLifecycle {
  return object(value, ["version", "mode", "connectionId"]) && value.version === 1
    && (value.mode === "managed" ? value.connectionId === undefined : value.mode === "connected" && text(value.connectionId, 128));
}
export function validHarnessExtensions(value: unknown): value is HarnessExtensions {
  return object(value, ["version", "connectedLifecycle", "conversationActions", "autonomousEvents", "agentMessaging"])
    && value.version === 1 && ["connectedLifecycle", "conversationActions", "autonomousEvents", "agentMessaging"].every(k => typeof value[k] === "boolean");
}
export function validHarnessActionRequest(value: unknown): value is HarnessActionRequest {
  if (!object(value, ["version", "requestId", "sessionId", "workId", "kind", "title", "text", "choices", "allowText", "ui"])) return false;
  return value.version === 1 && text(value.requestId, 128) && text(value.sessionId, 128)
    && (value.workId === undefined || text(value.workId, 128)) && ["approval", "question", "sign-in", "open-ui"].includes(value.kind as string)
    && text(value.title, 512) && (value.text === undefined || body(value.text, 8192))
    && (value.allowText === undefined || typeof value.allowText === "boolean")
    && Array.isArray(value.choices) && value.choices.length <= 32
    && value.choices.every(c => object(c, ["id", "label"]) && text(c.id, 128) && text(c.label, 256))
    && new Set(value.choices.map(c => c.id)).size === value.choices.length
    && (value.ui === undefined || object(value.ui, ["targetId", "label"]) && text(value.ui.targetId, 128) && text(value.ui.label, 256));
}
export function validHarnessAgentMessage(value: unknown): value is HarnessAgentMessage {
  return object(value, ["version", "messageId", "exchangeId", "toAgentId", "text", "sessionId", "workId"])
    && value.version === 1 && text(value.messageId, 128) && text(value.sessionId, 128)
    && typeof value.toAgentId === "string" && /^[a-z][a-z0-9_-]{0,63}$/.test(value.toAgentId)
    && body(value.text, 65536) && (value.exchangeId === undefined || text(value.exchangeId, 128))
    && (value.workId === undefined || text(value.workId, 128));
}
export function validHarnessEvent(value: unknown): value is HarnessEvent {
  if (!object(value, ["protocolVersion", "eventId", "conversationId", "runId", "attemptId", "kind", "data"])) return false;
  const v = value as unknown as HarnessEvent;
  return v.protocolVersion === 1 && text(v.eventId) && text(v.conversationId) && kinds.has(v.kind)
    && (v.runId === undefined || text(v.runId)) && (v.attemptId === undefined || text(v.attemptId))
    && !!v.data && typeof v.data === "object" && !Array.isArray(v.data)
    && (v.kind !== "action.open" || validHarnessActionRequest(v.data))
    && (v.kind !== "agent.message" || validHarnessAgentMessage(v.data))
    && (v.kind !== "action.cancel" || object(v.data, ["version", "requestId", "sessionId", "workId"])
      && v.data.version === 1 && text(v.data.requestId, 128) && text(v.data.sessionId, 128)
      && (v.data.workId === undefined || text(v.data.workId, 128)))
    && (v.kind !== "agent.message.status" || object(v.data, ["version", "messageId", "sessionId", "execution", "reason"])
      && v.data.version === 1 && text(v.data.messageId, 128) && text(v.data.sessionId, 128)
      && ["not-started", "running", "completed", "failed", "unknown"].includes(v.data.execution as string)
      && (v.data.reason === undefined || text(v.data.reason, 512)));
}
export function validHarnessTask(value: unknown): value is HarnessTask {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const v = value as HarnessTask;
  return text(v.taskId) && text(v.originRunId) && text(v.title, 2000)
    && (v.originAttemptId === undefined || text(v.originAttemptId))
    && (v.parentTaskId === undefined || text(v.parentTaskId))
    && ["running", "waiting", "stopping", "completed", "failed", "stopped", "unknown"].includes(v.state)
    && (v.text === undefined || typeof v.text === "string" && v.text.length <= 100_000)
    && typeof v.canSteer === "boolean" && typeof v.canStop === "boolean";
}
export const taskIsLive = (task: HarnessTask): boolean => ["running", "waiting", "stopping", "unknown"].includes(task.state);
