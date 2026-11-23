export type HermesErrorKind = "unavailable" | "auth" | "not_found" | "conflict" | "http";

export class HermesError extends Error {
  readonly kind: HermesErrorKind;
  readonly status?: number;
  readonly code?: string;

  constructor(kind: HermesErrorKind, message: string, status?: number, code?: string) {
    super(message);
    this.name = "HermesError";
    this.kind = kind;
    this.status = status;
    this.code = code;
  }
}

export type RunStatus = {
  status: string;
  admissionId?: string;
  generation?: number;
  output?: string;
  usage?: { inputTokens?: number; outputTokens?: number; totalTokens?: number };
  pendingControls: { id: string; kind: string; tool?: string }[];
};

export type RunEvent = { event: string; seq?: number; data: Record<string, unknown> };

export interface HermesClient {
  createRun(req: { key: string; body: string }): Promise<{ runId: string; status: string; replayed: boolean }>;
  status(runId: string): Promise<RunStatus>;
  events(runId: string, signal?: AbortSignal): AsyncIterable<RunEvent>;
  deny(runId: string, requestId: string, generation: number): Promise<void>;
  resolveUnknown(runId: string, admissionId: string, generation: number): Promise<void>;
  stop(runId: string): Promise<void>;
}

const RUNS = "/v1/runs";
const TERMINAL = new Set(["run.completed", "run.failed", "run.cancelled", "run.interrupted"]);
const runPath = (runId: string): string => RUNS + "/" + encodeURIComponent(runId);
type Method = "GET" | "POST";
const LOOPBACK = new Set(["127.0.0.1", "[::1]", "localhost"]);

function object(value: unknown): Record<string, unknown> | undefined {
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return undefined;
}

function parseObject(text: string): Record<string, unknown> | undefined {
  try {
    return object(JSON.parse(text));
  } catch {
    return undefined;
  }
}

function errorKind(status: number, code: unknown): HermesErrorKind {
  if (status === 429 || status === 503) return "unavailable";
  if (status === 401 || status === 403) return "auth";
  if (status === 404) return "not_found";
  if (status === 409 && code === "idempotency_key_conflict") return "conflict";
  return "http";
}

function mapStatus(data: Record<string, unknown>, status: string): RunStatus {
  const run: RunStatus = { status, pendingControls: [] };
  if (typeof data.admission_id === "string") run.admissionId = data.admission_id;
  if (typeof data.execution_generation === "number") run.generation = data.execution_generation;
  if (typeof data.output === "string") run.output = data.output;
  const usage = object(data.usage);
  if (usage) {
    run.usage = {};
    if (typeof usage.input_tokens === "number") run.usage.inputTokens = usage.input_tokens;
    if (typeof usage.output_tokens === "number") run.usage.outputTokens = usage.output_tokens;
    if (typeof usage.total_tokens === "number") run.usage.totalTokens = usage.total_tokens;
  }
  if (Array.isArray(data.pending_controls)) {
    for (const item of data.pending_controls) {
      const control = object(item);
      if (typeof control?.request_id !== "string" || typeof control.kind !== "string") continue;
      const { request_id: id, kind, tool } = control;
      run.pendingControls.push({ id, kind, ...(typeof tool === "string" && { tool }) });
    }
  }
  return run;
}

export function createHermesClient(
  { url, key }: { url: URL; key: string },
  { timeoutMs = 30_000, idleMs = 60_000 }: { timeoutMs?: number; idleMs?: number } = {},
): HermesClient {
  if (url.protocol !== "http:" || !LOOPBACK.has(url.hostname) || url.username || url.password) {
    throw new Error("The Hermes base URL must be http on loopback (127.0.0.1, [::1] or localhost).");
  }
  function failure(kind: HermesErrorKind, method: Method, path: string, status?: number, code?: string): HermesError {
    const safePath = key ? path.replaceAll(encodeURIComponent(key), "[redacted]") : path;
    const safeCode = key && code?.includes(key) ? undefined : code;
    const message = [method, safePath, status, safeCode].filter((part) => part !== undefined).join(" ");
    return new HermesError(kind, message, status, safeCode);
  }

  async function readJson(response: Response, method: Method, path: string) {
    try {
      return parseObject(await response.text());
    } catch {
      throw failure("unavailable", method, path, response.status);
    }
  }

  async function request(method: Method, path: string, signal: AbortSignal, body?: string, requestKey?: string) {
    const headers: Record<string, string> = { Authorization: "Bearer " + key };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (requestKey !== undefined) headers["Idempotency-Key"] = requestKey;
    let response: Response;
    try {
      response = await fetch(new URL(path, url), { method, headers, body, redirect: "manual", signal });
    } catch {
      throw failure("unavailable", method, path);
    }
    if (!response.ok) {
      const data = await readJson(response, method, path);
      const code = object(data?.error)?.code;
      throw failure(errorKind(response.status, code), method, path, response.status,
        typeof code === "string" ? code : undefined);
    }
    return response;
  }

  async function jsonRequest(method: Method, path: string, body?: string, requestKey?: string) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await request(method, path, controller.signal, body, requestKey);
      const data = await readJson(response, method, path);
      return { status: response.status, data };
    } finally {
      clearTimeout(timer);
    }
  }

  return {
    async createRun(req) {
      const { status, data } = await jsonRequest("POST", RUNS, req.body, req.key);
      if (typeof data?.run_id !== "string" || typeof data.status !== "string") {
        throw failure("http", "POST", RUNS, status, "bad_response");
      }
      return { runId: data.run_id, status: data.status, replayed: data.replayed === true };
    },
    async status(runId) {
      const path = runPath(runId);
      const { status, data } = await jsonRequest("GET", path);
      if (typeof data?.status !== "string") throw failure("http", "GET", path, status, "bad_response");
      return mapStatus(data, data.status);
    },
    async *events(runId, callerSignal) {
      if (callerSignal?.aborted) return;
      const path = runPath(runId) + "/events";
      const controller = new AbortController();
      const signal = callerSignal ? AbortSignal.any([callerSignal, controller.signal]) : controller.signal;
      let timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const response = await request("GET", path, signal);
        if (!response.body) return;
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let pending = "";
        let skipLF = false;
        let dataLines: string[] = [];
        const armIdle = () => {
          clearTimeout(timer);
          timer = setTimeout(() => controller.abort(), idleMs);
        };
        armIdle();
        try {
          while (!signal.aborted) {
            const chunkRead = await reader.read().catch(() => ({ done: true } as const));
            if (chunkRead.done || signal.aborted) return;
            const { value } = chunkRead;
            if (!value.byteLength) continue;
            armIdle();
            const chunk = decoder.decode(value, { stream: true });
            if (!chunk) continue;
            const lines = (pending + (skipLF && chunk.startsWith("\n") ? chunk.slice(1) : chunk)).split(/\r\n|\r|\n/);
            pending = lines.pop() ?? "";
            skipLF = chunk.endsWith("\r");
            for (const line of lines) {
              if (signal.aborted || line === ": stream closed") return;
              if (line.startsWith("data:")) dataLines.push(line.slice(line[5] === " " ? 6 : 5));
              if (line !== "" || !dataLines.length) continue;
              const data = parseObject(dataLines.join("\n"));
              dataLines = [];
              if (typeof data?.event !== "string") continue;
              const { event, seq } = data;
              yield { event, ...(typeof seq === "number" && { seq }), data };
              if (TERMINAL.has(event)) return;
            }
          }
        } finally {
          reader.releaseLock();
        }
      } catch (error) {
        if (!callerSignal?.aborted) throw error;
      } finally {
        clearTimeout(timer);
        controller.abort();
      }
    },
    async deny(runId, requestId, generation) {
      await jsonRequest("POST", runPath(runId) + "/approval",
        JSON.stringify({ request_id: requestId, execution_generation: generation, choice: "deny" }));
    },
    async resolveUnknown(runId, admissionId, generation) {
      await jsonRequest("POST", runPath(runId) + "/resolve-unknown",
        JSON.stringify({ admission_id: admissionId, execution_generation: generation }));
    },
    async stop(runId) {
      await jsonRequest("POST", runPath(runId) + "/stop");
    },
  };
}
