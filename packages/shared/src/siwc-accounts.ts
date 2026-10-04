/** Safe account settings only. The containing event ID is the operation ID.
 * Authorization URLs, callbacks, registration identity and credentials stay on the host. */
export type SiwcAccountControlData = { version: 1 } & (
  | { method: "sign-in"; bindingId?: string; returning?: boolean }
  | { method: "cancel"; attemptId: string }
  | { method: "verify-pending" | "select" | "sign-out"; bindingId: string }
  | { method: "status" }
);
export type SiwcAccountReason = "unsupported" | "invalid" | "identity" | "permission" | "conflict"
  | "unknown" | "signed-out" | "local-sign-in-required" | "busy";
export interface SiwcAccountControlResult {
  operationId: string; status: "pending" | "completed" | "rejected" | "unknown";
  attemptId?: string; reason?: SiwcAccountReason;
}
export interface SiwcAccountSummary {
  accountBindingId: string; phase: "ready" | "signed-out" | "unknown";
  planUse: boolean; active: boolean; remoteRevocation?: "confirmed" | "unconfirmed";
}
export interface SiwcAccountStatusData {
  version: 1; productionReady: false; nativeIntegration: "unwired" | "wired-unverified";
  available: boolean; state: "available" | "unsupported" | "unknown";
  revision?: number; activeAccountBindingId?: string; accounts: SiwcAccountSummary[];
  lastControlResult?: SiwcAccountControlResult;
}

function object(value: unknown, allowed: readonly string[]): asserts value is Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)
    || Object.keys(value).some(k => !allowed.includes(k) || value[k as keyof typeof value] === null))
    throw new Error("Invalid account settings data");
}
export function validSiwcAccountOpaqueId(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_.:-]{1,128}$/.test(value) && !/[\r\n]/.test(value);
}
function id(value: unknown): asserts value is string {
  if (!validSiwcAccountOpaqueId(value)) throw new Error("Invalid account settings identifier");
}
const REASONS: readonly string[] = ["unsupported", "invalid", "identity", "permission", "conflict",
  "unknown", "signed-out", "local-sign-in-required", "busy"];

export function parseSiwcAccountControl(value: unknown): SiwcAccountControlData {
  object(value, ["version", "method", "bindingId", "returning", "attemptId"]);
  if (value.version !== 1) throw new Error("Unsupported account settings version");
  switch (value.method) {
    case "sign-in":
      object(value, ["version", "method", "bindingId", "returning"]);
      if (value.bindingId !== undefined) id(value.bindingId);
      if (value.returning !== undefined && typeof value.returning !== "boolean"
        || value.returning === true && value.bindingId === undefined) throw new Error("Invalid returning account request");
      break;
    case "cancel": object(value, ["version", "method", "attemptId"]); id(value.attemptId); break;
    case "verify-pending": case "select": case "sign-out":
      object(value, ["version", "method", "bindingId"]); id(value.bindingId); break;
    case "status": object(value, ["version", "method"]); break;
    default: throw new Error("Invalid account settings method");
  }
  return value as SiwcAccountControlData;
}

export function parseSiwcAccountStatus(value: unknown): SiwcAccountStatusData {
  object(value, ["version", "productionReady", "nativeIntegration", "available", "state", "revision",
    "activeAccountBindingId", "accounts", "lastControlResult"]);
  if (value.version !== 1 || value.productionReady !== false || !["unwired", "wired-unverified"].includes(value.nativeIntegration as string)
    || typeof value.available !== "boolean" || !["available", "unsupported", "unknown"].includes(value.state as string)
    || value.available !== (value.state === "available") || !Array.isArray(value.accounts) || value.accounts.length > 32)
    throw new Error("Invalid account status");
  if (value.revision !== undefined && (!Number.isSafeInteger(value.revision) || (value.revision as number) < 0)
    || value.available && value.revision === undefined) throw new Error("Invalid account status revision");
  if (value.activeAccountBindingId !== undefined) id(value.activeAccountBindingId);
  const known = new Set<string>();
  let active: string | undefined;
  for (const row of value.accounts) {
    object(row, ["accountBindingId", "phase", "planUse", "active", "remoteRevocation"]);
    id(row.accountBindingId);
    if (known.has(row.accountBindingId) || !["ready", "signed-out", "unknown"].includes(row.phase as string)
      || typeof row.planUse !== "boolean" || typeof row.active !== "boolean" || row.planUse && row.phase !== "ready"
      || row.remoteRevocation !== undefined && !["confirmed", "unconfirmed"].includes(row.remoteRevocation as string))
      throw new Error("Invalid saved account status");
    known.add(row.accountBindingId);
    if (row.active) { if (active !== undefined) throw new Error("Duplicate active account"); active = row.accountBindingId; }
  }
  if (active !== value.activeAccountBindingId || !value.available && (known.size > 0 || value.activeAccountBindingId !== undefined))
    throw new Error("Invalid active account status");
  if (value.lastControlResult !== undefined) {
    object(value.lastControlResult, ["operationId", "status", "attemptId", "reason"]);
    const result = value.lastControlResult;
    id(result.operationId);
    if (!["pending", "completed", "rejected", "unknown"].includes(result.status as string)
      || result.reason !== undefined && !REASONS.includes(result.reason as string)) throw new Error("Invalid account operation result");
    if (result.attemptId !== undefined) { id(result.attemptId); if (result.status !== "pending") throw new Error("Invalid account attempt result"); }
  }
  return value as unknown as SiwcAccountStatusData;
}
