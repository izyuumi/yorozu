/** Small host tool boundary. Actor identity is captured at launch, never parsed from a tool call. */
export interface WorkerMemoryCapability {
  read(ownerId: string, key: string): string | undefined;
  write(key: string, body: string, operationId: string): void;
  search(ownerId: string, query: string): Array<{ key: string; body: string }>;
  grant(toAgentId: string, key: string, operationId: string): void;
  revoke(toAgentId: string, key: string, operationId: string): void;
}
export type WorkerMemoryRequest =
  | { action: "read"; ownerId: string; key: string }
  | { action: "search"; ownerId: string; query: string }
  | { action: "write"; key: string; body: string; operationId: string }
  | { action: "grant" | "revoke"; toAgentId: string; key: string; operationId: string };
export type WorkerShareRequest = Extract<WorkerMemoryRequest, { action: "grant" | "revoke" }>;
const fields = {
  read: ["action", "ownerId", "key"], search: ["action", "ownerId", "query"],
  write: ["action", "key", "body", "operationId"],
  grant: ["action", "toAgentId", "key", "operationId"], revoke: ["action", "toAgentId", "key", "operationId"],
} as const;
export function parseWorkerMemoryRequest(value: unknown): WorkerMemoryRequest {
  if (!value || typeof value !== "object" || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) throw new Error("Invalid worker memory request");
  const v = value as Record<string, unknown>;
  if (typeof v.action !== "string" || !Object.hasOwn(fields, v.action)) throw new Error("Invalid worker memory action");
  const keys = fields[v.action as keyof typeof fields] as readonly string[];
  if (Object.keys(v).length !== keys.length || Object.keys(v).some(k => !keys.includes(k))
    || keys.some(k => typeof v[k] !== "string" || !(v[k] as string).trim() || (v[k] as string).includes("\0")))
    throw new Error("Invalid worker memory fields");
  if (JSON.stringify(v).length > 40_000) throw new Error("Worker memory request exceeds limit");
  for (const k of ["ownerId", "toAgentId"]) if (v[k] !== undefined && (!/^[a-z][a-z0-9_-]{0,63}$/.test(v[k] as string) || /[\r\n]/.test(v[k] as string)))
    throw new Error("Invalid memory owner");
  for (const k of ["key", "operationId"]) if (v[k] !== undefined && (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/.test(v[k] as string) || /[\r\n]/.test(v[k] as string)))
    throw new Error("Invalid memory identity");
  if (typeof v.body === "string" && Buffer.byteLength(v.body) > 16_384 || typeof v.query === "string" && Buffer.byteLength(v.query) > 256)
    throw new Error("Worker memory content exceeds limit");
  return structuredClone(v) as WorkerMemoryRequest;
}

export class WorkerToolPreconditionError extends Error {}

/** Approval is an exact one-shot native action, not a model boolean or global tool bypass. */
export function workerMemoryTools(memory: WorkerMemoryCapability, current: () => void,
  approve: (request: WorkerShareRequest, apply: () => void, signal: AbortSignal) => Promise<void>) {
  return async (method: string, params: unknown, signal: AbortSignal): Promise<unknown> => {
    if (method !== "worker.memory") throw new Error("Unsupported worker tool");
    const request = parseWorkerMemoryRequest(params);
    const check = () => { try { signal.throwIfAborted(); current(); }
      catch { throw new WorkerToolPreconditionError("Worker tool authority is no longer current"); } };
    check();
    switch (request.action) {
      case "read": return { value: memory.read(request.ownerId, request.key) ?? null };
      case "search": return { entries: memory.search(request.ownerId, request.query).slice(0, 16)
        .map(entry => ({ key: entry.key, body: entry.body.slice(0, 2048) })) };
      case "write": memory.write(request.key, request.body, request.operationId); return { ok: true };
      case "revoke": memory.revoke(request.toAgentId, request.key, request.operationId); return { ok: true };
      case "grant":
        await approve(request, () => { check(); memory.grant(request.toAgentId, request.key, request.operationId); }, signal);
        return { ok: true };
    }
  };
}

/** Private adapter-to-host currency; never accepted from model tool arguments. */
export interface WorkerExecution { sessionId: string; runId: string; attemptId: string }
export interface WorkerWork extends WorkerExecution { signal: AbortSignal; current(): boolean }
export function parseWorkerMemoryEnvelope(value: unknown): { execution: WorkerExecution; request: WorkerMemoryRequest } {
  const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v)
    && [Object.prototype, null].includes(Object.getPrototypeOf(v));
  if (!object(value) || Object.keys(value).length !== 2 || !Object.hasOwn(value, "execution") || !Object.hasOwn(value, "request"))
    throw new Error("Worker memory requires exact execution provenance");
  const e = value.execution;
  if (!object(e) || Object.keys(e).length !== 3 || ["sessionId", "runId", "attemptId"].some(k =>
    !Object.hasOwn(e, k) || typeof e[k] !== "string" || !e[k].trim() || e[k].length > 512 || /[\0\r\n]/.test(e[k])))
    throw new Error("Invalid worker execution provenance");
  return { execution: { sessionId: e.sessionId as string, runId: e.runId as string, attemptId: e.attemptId as string },
    request: parseWorkerMemoryRequest(value.request) };
}
