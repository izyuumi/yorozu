/** Private host↔whole-harness contract. Transport IDs are never admission IDs. */
export const HARNESS_PROTOCOL_VERSION = 1;
export const HARNESS_FRAME_BYTES = 256 * 1024;
export const HARNESS_PENDING_REQUESTS = 32;
export type HarnessPluginId = "hermes" | "openclaw";
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
  kind: "assistant.update" | "turn.started" | "turn.terminal" | "task.changed" | "request.open" | "request.cancel" | "runtime.closed" | "capability.unavailable";
  data: Record<string, unknown>;
}
export interface HarnessReady {
  protocolVersion: 1;
  pluginId: HarnessPluginId;
  upstreamVersion: string;
  capabilities: HarnessCapabilities;
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
}
const text = (v: unknown, max = 512): v is string => typeof v === "string" && v.length > 0 && v.length <= max;
const kinds = new Set(["assistant.update", "turn.started", "turn.terminal", "task.changed", "request.open", "request.cancel", "runtime.closed", "capability.unavailable"]);
export function validHarnessEvent(value: unknown): value is HarnessEvent {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const v = value as HarnessEvent;
  return v.protocolVersion === 1 && text(v.eventId) && text(v.conversationId) && kinds.has(v.kind)
    && (v.runId === undefined || text(v.runId)) && (v.attemptId === undefined || text(v.attemptId))
    && !!v.data && typeof v.data === "object" && !Array.isArray(v.data);
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
