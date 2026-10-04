/** Host-only SIWC Responses relay. It owns neither an agent loop nor account onboarding.
 * Contract checked against OpenAI's public SIWC preview on 2026-10-04:
 * https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
 * https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
 * Flat function tools use the documented additional_tools input form (names and call IDs unchanged):
 * https://developers.openai.com/api/docs/guides/tools-tool-search#add-tools-at-a-specific-point-in-the-input
 * This subset still needs authorized native onboarding + real Hermes/provider validation before release.
 */
import { randomBytes, timingSafeEqual } from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { PersonAgent } from "./agent-store.js";
import { validAgentId } from "./agent-scope.js";
import type { PersonAgentExecution } from "./person-agent-runtime.js";
import type { SelectedAgentBroker } from "./curated-agent-runtime.js";

export const SIWC_RESPONSES_URL = "https://api.openai.com/v1/responses" as const;
export const SIWC_ONBOARDING = Object.freeze({ status: "unsupported" as const,
  reason: "Native app-specific SIWC registration, consent, identity validation and protected token storage are not wired",
  documentation: "https://developers.openai.com/siwc/token-sharing-open-source/sign-in" });
export interface SiwcAccountIdentity {
  accountBindingId: string; clientId: string; subject: string;
  /** Attestation from trusted host onboarding; this module does not verify JWT signatures or storage. */
  verification: "host-validated-siwc-v1"; storage: "os-protected";
}
export interface SiwcAccessToken extends SiwcAccountIdentity {
  audience: "https://api.openai.com/v1"; scopes: readonly string[]; expiresAt: number; accessToken: string;
}
export interface SiwcBrokerBudget {
  maxRequests: number; maxConcurrent: number; maxRequestBytes: number; maxResponseBytes: number;
  maxTotalBytes: number; maxEventBytes: number; requestTimeoutMs: number; expiresAt: number;
}
export interface SiwcExecutionGrant {
  agentId: string; executionId: string; model: string; scopeDigest: string;
  account: SiwcAccountIdentity; allowedFunctionNames: readonly string[]; budget: SiwcBrokerBudget;
  /** Host callbacks only; no client, prompt, environment or filesystem token lookup. */
  getAccessToken(signal: AbortSignal): Promise<SiwcAccessToken>;
  isCurrent(): boolean;
}
export interface SiwcTransportRequest {
  url: typeof SIWC_RESPONSES_URL; method: "POST";
  headers: Readonly<{ authorization: string; "content-type": "application/json"; accept: "text/event-stream" }>;
  body: string; signal: AbortSignal;
}
export interface SiwcTransportResponse { status: number; contentType: string; body: AsyncIterable<Uint8Array> }
export type SiwcTransport = (request: SiwcTransportRequest) => Promise<SiwcTransportResponse>;
export interface SiwcLocalRequest {
  method: string; path: string; host: string; remoteAddress: string;
  authorization?: string; contentType?: string; contentEncoding?: string;
  body: AsyncIterable<Uint8Array>; signal?: AbortSignal;
}
export interface SiwcResponseSink {
  start(status: number, headers: Readonly<Record<string, string>>): void;
  /** Must resolve only when the downstream can accept another chunk. */
  write(chunk: Uint8Array): Promise<void>; end(): void;
}
export class SiwcBrokerError extends Error {
  constructor(readonly code: "unsupported" | "unauthorized" | "binding" | "budget" | "unknown", readonly status: number) {
    super(`SIWC broker ${code}`); this.name = "SiwcBrokerError";
  }
}
const object = (v: unknown): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v);
const fields = (v: unknown, allowed: readonly string[]): v is Record<string, any> => object(v) && Object.keys(v).every(k => allowed.includes(k));
const textId = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_.:-]{1,128}$/.test(v);
const toolName = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(v);
function fail(code: SiwcBrokerError["code"], status = 400): never { throw new SiwcBrokerError(code, status); }
const requiredScopes = ["chatgpt.tokens.use.direct", "resource.invoke"];
function account(v: unknown): v is SiwcAccountIdentity {
  return fields(v, ["accountBindingId", "clientId", "subject", "verification", "storage"]) && textId(v.accountBindingId)
    && typeof v.clientId === "string" && /^oaiapp_[A-Za-z0-9_-]{1,128}$/.test(v.clientId)
    && typeof v.subject === "string" && /^[A-Za-z0-9_.:@|-]{1,256}$/.test(v.subject)
    && v.verification === "host-validated-siwc-v1" && v.storage === "os-protected";
}
function sameAccount(a: SiwcAccountIdentity, b: SiwcAccountIdentity): boolean {
  return a.accountBindingId === b.accountBindingId && a.clientId === b.clientId && a.subject === b.subject
    && a.verification === b.verification && a.storage === b.storage;
}
function grantCopy(v: SiwcExecutionGrant): SiwcExecutionGrant {
  if (!fields(v, ["agentId", "executionId", "model", "scopeDigest", "account", "allowedFunctionNames", "budget", "getAccessToken", "isCurrent"])
    || !validAgentId(v.agentId) || !/^[a-f0-9]{64}$/.test(v.executionId) || !textId(v.model) || !/^[a-f0-9]{64}$/.test(v.scopeDigest)
    || !account(v.account) || !Array.isArray(v.allowedFunctionNames) || v.allowedFunctionNames.length > 128
    || !v.allowedFunctionNames.every(toolName) || new Set(v.allowedFunctionNames).size !== v.allowedFunctionNames.length
    || typeof v.getAccessToken !== "function" || typeof v.isCurrent !== "function"
    || !fields(v.budget, ["maxRequests", "maxConcurrent", "maxRequestBytes", "maxResponseBytes", "maxTotalBytes", "maxEventBytes", "requestTimeoutMs", "expiresAt"])) fail("binding");
  const limits: Array<[keyof SiwcBrokerBudget, number, number]> = [
    ["maxRequests", 1, 1000], ["maxConcurrent", 1, 8], ["maxRequestBytes", 256, 4 * 1024 * 1024],
    ["maxResponseBytes", 256, 32 * 1024 * 1024], ["maxTotalBytes", 256, 64 * 1024 * 1024],
    ["maxEventBytes", 128, 1024 * 1024], ["requestTimeoutMs", 10, 120_000], ["expiresAt", 1, Number.MAX_SAFE_INTEGER],
  ];
  if (limits.some(([k, min, max]) => !Number.isSafeInteger(v.budget[k]) || v.budget[k] < min || v.budget[k] > max)
    || v.budget.maxEventBytes > v.budget.maxResponseBytes || v.budget.maxConcurrent > v.budget.maxRequests) fail("budget");
  return Object.freeze({ ...v, account: Object.freeze({ ...v.account }),
    allowedFunctionNames: Object.freeze([...v.allowedFunctionNames]), budget: Object.freeze({ ...v.budget }) });
}
const requestFields = ["model", "input", "instructions", "store", "stream", "tools", "tool_choice", "parallel_tool_calls", "reasoning", "text", "include", "prompt_cache_key", "service_tier"];
function boundedJson(v: unknown, depth = 0): void {
  if (depth > 32 || typeof v === "number" && !Number.isFinite(v)) fail("unsupported");
  if (Array.isArray(v)) { if (v.length > 8192) fail("unsupported"); for (const child of v) boundedJson(child, depth + 1); }
  else if (object(v)) {
    if (Object.keys(v).length > 2048 || ["__proto__", "prototype", "constructor"].some(k => Object.hasOwn(v, k))) fail("unsupported");
    for (const child of Object.values(v)) boundedJson(child, depth + 1);
  }
}
function inputItem(v: any, allowed: ReadonlySet<string>): void {
  if (!object(v)) fail("unsupported");
  if ((!v.type || v.type === "message") && ["user", "assistant", "developer"].includes(v.role)) {
    if (!fields(v, ["type", "role", "content", "id", "status", "phase"]) || typeof v.content !== "string" && !Array.isArray(v.content)) fail("unsupported");
    if (Array.isArray(v.content) && v.content.some((c: any) => !fields(c, ["type", "text", "annotations"]) || !["input_text", "output_text"].includes(c.type) || typeof c.text !== "string")) fail("unsupported");
    return;
  }
  if (v.type === "function_call") {
    if (!fields(v, ["type", "name", "arguments", "call_id", "id", "status"]) || !allowed.has(v.name) || typeof v.arguments !== "string" || !textId(v.call_id)) fail("unsupported");
    return;
  }
  if (v.type === "function_call_output") {
    if (!fields(v, ["type", "call_id", "output", "id", "status"]) || !textId(v.call_id) || typeof v.output !== "string") fail("unsupported");
    return;
  }
  if (v.type === "reasoning") {
    if (!fields(v, ["type", "id", "summary", "encrypted_content", "status"]) || !Array.isArray(v.summary)
      || v.summary.some((s: any) => !fields(s, ["type", "text"]) || s.type !== "summary_text" || typeof s.text !== "string")
      || v.encrypted_content !== undefined && typeof v.encrypted_content !== "string") fail("unsupported");
    return;
  }
  fail("unsupported"); // Includes system, tool_search, additional_tools and hosted actions from a client.
}
/** Only the documented eager-function subset; no names, call IDs or tool result semantics change. */
export function normalizeSiwcRequest(value: unknown, model: string, allowedFunctionNames: readonly string[]): Record<string, any> {
  if (!textId(model) || !Array.isArray(allowedFunctionNames) || allowedFunctionNames.length > 128 || !allowedFunctionNames.every(toolName)) fail("binding");
  boundedJson(value);
  if (!fields(value, requestFields) || value.model !== model || !Array.isArray(value.input) || !value.input.length
    || value.input.length > 4096 || value.store !== undefined && value.store !== false || value.stream !== true
    || value.instructions !== undefined && typeof value.instructions !== "string"
    || value.service_tier !== undefined && !["default", "normal"].includes(value.service_tier)) fail("unsupported");
  const allowed = new Set(allowedFunctionNames);
  value.input.forEach((item: any) => inputItem(item, allowed));
  if (value.tool_choice !== undefined && !["auto", "none"].includes(value.tool_choice)
    || value.parallel_tool_calls !== undefined && typeof value.parallel_tool_calls !== "boolean"
    || value.reasoning !== undefined && (!fields(value.reasoning, ["effort", "summary"]) || value.reasoning.effort !== undefined && !["none", "minimal", "low", "medium", "high", "xhigh"].includes(value.reasoning.effort)
      || value.reasoning.summary !== undefined && !["auto", "concise", "detailed"].includes(value.reasoning.summary))
    || value.text !== undefined && (!fields(value.text, ["verbosity"]) || !["low", "medium", "high"].includes(value.text.verbosity))
    || value.include !== undefined && (!Array.isArray(value.include) || value.include.length > 1 || value.include.some((s: any) => s !== "reasoning.encrypted_content"))
    || value.prompt_cache_key !== undefined && (typeof value.prompt_cache_key !== "string" || value.prompt_cache_key.length > 64)) fail("unsupported");
  if (value.tools !== undefined && (!Array.isArray(value.tools) || value.tools.length > 128)) fail("unsupported");
  const tools = value.tools ?? [];
  const seen = new Set<string>();
  for (const tool of tools) {
    if (!fields(tool, ["type", "name", "description", "parameters", "strict"]) || tool.type !== "function" || !toolName(tool.name)
      || !allowed.has(tool.name) || seen.has(tool.name) || typeof tool.description !== "string" && tool.description !== undefined
      || !object(tool.parameters) || tool.parameters.type !== "object" || tool.strict !== undefined && typeof tool.strict !== "boolean") fail("unsupported");
    seen.add(tool.name);
  }
  const out = structuredClone(value);
  delete out.tools;
  if (tools.length) out.input.unshift({ type: "additional_tools", role: "developer", tools: structuredClone(tools) });
  out.store = false; out.stream = true; out.service_tier = "default";
  return out;
}
function signalBound<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(new SiwcBrokerError("unknown", 502));
  return new Promise((resolve, reject) => {
    const stop = (): void => { reject(new SiwcBrokerError("unknown", 502)); };
    signal.addEventListener("abort", stop, { once: true });
    promise.then(resolve, reject).finally(() => signal.removeEventListener("abort", stop));
  });
}
async function nextChunk(iterator: AsyncIterator<Uint8Array>, signal: AbortSignal): Promise<IteratorResult<Uint8Array>> {
  return signalBound(iterator.next(), signal);
}
async function boundedBody(source: AsyncIterable<Uint8Array>, limit: number, signal: AbortSignal): Promise<Buffer> {
  const chunks: Buffer[] = []; let bytes = 0;
  const iterator = source[Symbol.asyncIterator]();
  try {
    while (true) { const next = await nextChunk(iterator, signal); if (next.done) break;
      if (!(next.value instanceof Uint8Array) || (bytes += next.value.byteLength) > limit) fail("budget", 413);
      chunks.push(Buffer.from(next.value));
    }
  } finally { void iterator.return?.().catch(() => {}); }
  return Buffer.concat(chunks, bytes);
}
function safeError(code: SiwcBrokerError["code"]): string {
  return JSON.stringify({ error: { type: "yorozu_siwc_broker", code, message: `SIWC request ${code}; no fallback or replay was attempted` } });
}
function tokenValid(token: SiwcAccessToken | undefined, identity: SiwcAccountIdentity, now: number): token is SiwcAccessToken {
  return fields(token, ["accountBindingId", "clientId", "subject", "verification", "storage", "audience", "scopes", "expiresAt", "accessToken"])
    && sameAccount(token, identity) && token.audience === "https://api.openai.com/v1" && Array.isArray(token.scopes)
    && requiredScopes.every(s => token.scopes.includes(s)) && Number.isSafeInteger(token.expiresAt) && token.expiresAt > now + 1000
    && typeof token.accessToken === "string" && /^[A-Za-z0-9._~-]{16,32768}$/.test(token.accessToken);
}
export interface SiwcExecutionBroker {
  dispatch(request: SiwcLocalRequest, sink: SiwcResponseSink): Promise<void>;
  handler(request: IncomingMessage, response: ServerResponse): void;
  /** Call only after trusted host code acquired this exact numeric loopback endpoint. */
  selected(host: "127.0.0.1", port: number): SelectedAgentBroker;
  status(): Readonly<{ onboarding: "unsupported"; released: boolean; requests: number; active: number; bytes: number }>;
  close(): void;
}
/** No sockets/network/storage are opened by construction. All authority comes from trusted host grant. */
export function createSiwcExecutionBroker(supplied: SiwcExecutionGrant, transport: SiwcTransport, now = Date.now): SiwcExecutionBroker {
  const grant = grantCopy(supplied);
  if (typeof transport !== "function") fail("unsupported");
  const localBearer = randomBytes(32).toString("hex"), controllers = new Set<AbortController>();
  let endpoint: number | undefined, released = false, requests = 0, active = 0, bytes = 0;
  const current = (): boolean => { try { return !released && now() < grant.budget.expiresAt && grant.isCurrent() === true; } catch { return false; } };
  const charge = (n: number): void => { if ((bytes += n) > grant.budget.maxTotalBytes) fail("budget", 429); };
  const dispatch = async (request: SiwcLocalRequest, sink: SiwcResponseSink): Promise<void> => {
    let started = false, admitted = false, token: SiwcAccessToken | undefined, iterator: AsyncIterator<Uint8Array> | undefined;
    const controller = new AbortController(); controllers.add(controller);
    const canceled = (): void => controller.abort(); request.signal?.addEventListener("abort", canceled, { once: true });
    if (request.signal?.aborted) controller.abort();
    const timer = setTimeout(canceled, Math.max(0, Math.min(grant.budget.requestTimeoutMs, grant.budget.expiresAt - now()))); timer.unref();
    try {
      if (!endpoint || request.host !== `127.0.0.1:${endpoint}` || request.remoteAddress !== "127.0.0.1"
        || request.method !== "POST" || request.path !== "/v1/responses") fail("unsupported", 404);
      const credential = request.authorization?.startsWith("Bearer ") ? request.authorization.slice(7) : "";
      if (!/^[a-f0-9]{64}$/.test(credential) || !timingSafeEqual(Buffer.from(credential), Buffer.from(localBearer))) fail("unauthorized", 401);
      if (!current()) fail("binding", 403);
      if (request.contentType?.split(";")[0].trim().toLowerCase() !== "application/json" || request.contentEncoding && request.contentEncoding !== "identity") fail("unsupported", 415);
      if (active >= grant.budget.maxConcurrent || requests >= grant.budget.maxRequests) fail("budget", 429);
      active++; admitted = true; // Reservations include body readers so slow uploads cannot exceed concurrency.
      const raw = await boundedBody(request.body, grant.budget.maxRequestBytes, controller.signal);
      let parsed: unknown; try { parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw)); } catch { fail("unsupported"); }
      const body = JSON.stringify(normalizeSiwcRequest(parsed, grant.model, grant.allowedFunctionNames));
      if (Buffer.byteLength(body) > grant.budget.maxRequestBytes) fail("budget", 413);
      if (!current()) fail("binding", 403);
      charge(Buffer.byteLength(body)); requests++; // Reserved before any asynchronous token/transport admission. Never replayed.
      try { token = await signalBound(Promise.resolve().then(() => grant.getAccessToken(controller.signal)), controller.signal); }
      catch { fail("unauthorized", 401); }
      if (!tokenValid(token, grant.account, now()) || !current()) fail("unauthorized", 401);
      if (body.includes(token.accessToken) || body.includes(localBearer)) fail("unsupported");
      const upstream = await signalBound(Promise.resolve().then(() => transport({ url: SIWC_RESPONSES_URL, method: "POST",
        headers: Object.freeze({ authorization: `Bearer ${token!.accessToken}`, "content-type": "application/json", accept: "text/event-stream" }),
        body, signal: controller.signal })), controller.signal);
      if (!current()) fail("binding", 403);
      if (upstream.status !== 200 || upstream.contentType.split(";")[0].trim().toLowerCase() !== "text/event-stream") {
        void upstream.body[Symbol.asyncIterator]().return?.().catch(() => {});
        fail(upstream.status === 401 || upstream.status === 403 ? "unauthorized" : "unknown", upstream.status === 429 ? 429 : 502);
      }
      sink.start(200, { "content-type": "text/event-stream", "cache-control": "no-store" }); started = true;
      iterator = upstream.body[Symbol.asyncIterator]();
      let pending = "", responseBytes = 0, terminal = false;
      const decoder = new TextDecoder("utf-8", { fatal: true });
      const emit = async (frame: string): Promise<void> => {
        if (!frame.trim() || frame.split("\n").every(line => !line || line.startsWith(":"))) return;
        if (!current() || terminal) fail("unknown", 502);
        const lines = frame.split("\n"), data = lines.filter(line => line.startsWith("data:")).map(line => line.slice(5).trimStart()).join("\n");
        if (!data || data === "[DONE]" || lines.some(line => line && !line.startsWith("data:") && !line.startsWith("event:") && !line.startsWith(":"))) fail("unknown", 502);
        let event: any; try { event = JSON.parse(data); boundedJson(event); } catch { fail("unknown", 502); }
        if (!object(event) || typeof event.type !== "string" || !/^response\.(created|queued|in_progress|completed|incomplete|failed|error|output_item\.(added|done)|content_part\.(added|done)|output_text\.(delta|done|annotation\.added)|refusal\.(delta|done)|function_call_arguments\.(delta|done)|reasoning_summary_(part\.(added|done)|text\.(delta|done))|reasoning_(part\.(added|done)|text\.(delta|done)))$/.test(event.type)) fail("unknown", 502);
        if (event.type === "response.failed" || event.type === "response.error" || event.error || event.response?.error) fail("unknown", 502);
        if (event.type === "response.completed" && event.response?.status !== "completed" || event.type === "response.incomplete") fail("unknown", 502);
        const encoded = JSON.stringify(event);
        if (encoded.includes(token!.accessToken) || encoded.includes(localBearer) || event.response?.service_tier && event.response.service_tier !== "default") fail("unknown", 502);
        for (const item of [event.item, ...(event.response?.output ?? [])]) {
          if (item?.type === "function_call" && (!grant.allowedFunctionNames.includes(item.name) || !textId(item.call_id))) fail("unknown", 502);
          if (item?.type && /tool_search|computer|mcp|shell_call|code_interpreter|image_generation/.test(item.type)) fail("unknown", 502);
        }
        await signalBound(sink.write(Buffer.from(`event: ${event.type}\ndata: ${encoded}\n\n`)), controller.signal);
        if (event.type === "response.completed") terminal = true;
      };
      while (!terminal) {
        const next = await nextChunk(iterator, controller.signal); if (next.done) break;
        if (!(next.value instanceof Uint8Array) || (responseBytes += next.value.byteLength) > grant.budget.maxResponseBytes) fail("budget", 502);
        charge(next.value.byteLength); pending += decoder.decode(next.value, { stream: true }); pending = pending.replace(/\r\n/g, "\n");
        let split: number;
        while ((split = pending.indexOf("\n\n")) >= 0) {
          const frame = pending.slice(0, split); pending = pending.slice(split + 2);
          if (Buffer.byteLength(frame) > grant.budget.maxEventBytes) fail("budget", 502);
          await emit(frame);
          if (terminal) break;
        }
        if (Buffer.byteLength(pending) > grant.budget.maxEventBytes) fail("budget", 502);
      }
      if (!terminal) fail("unknown", 502);
      sink.end();
    } catch (error) {
      const safe = error instanceof SiwcBrokerError ? error : new SiwcBrokerError("unknown", 502);
      try {
        if (!started) { sink.start(safe.status, { "content-type": "application/json", "cache-control": "no-store" }); await signalBound(sink.write(Buffer.from(safeError(safe.code))), controller.signal); }
        else await signalBound(sink.write(Buffer.from(`event: error\ndata: ${safeError(safe.code)}\n\n`)), controller.signal);
        sink.end();
      } catch { try { sink.end(); } catch {} /* A closed consumer receives no synthetic terminal success. */ }
    } finally {
      controller.abort(); clearTimeout(timer); controllers.delete(controller);
      request.signal?.removeEventListener("abort", canceled);
      if (iterator) void iterator.return?.().catch(() => {});
      if (admitted) active--;
    }
  };
  return Object.freeze({ dispatch,
    handler: (request: IncomingMessage, response: ServerResponse): void => {
      const cancel = new AbortController();
      request.once("aborted", () => cancel.abort()); response.once("close", () => { if (!response.writableEnded) cancel.abort(); });
      void dispatch({ method: request.method ?? "", path: request.url ?? "", host: request.headers.host ?? "", remoteAddress: request.socket.remoteAddress ?? "",
        authorization: request.headers.authorization, contentType: request.headers["content-type"], contentEncoding: request.headers["content-encoding"] as string | undefined,
        body: request, signal: cancel.signal }, {
        start: (status, headers) => response.writeHead(status, headers),
        write: chunk => new Promise<void>((resolve, reject) => {
          if (response.destroyed || cancel.signal.aborted) return reject(new SiwcBrokerError("unknown", 502));
          if (response.write(chunk)) return resolve();
          const cleanup = (): void => { response.removeListener("drain", drained); response.removeListener("close", closed); };
          const drained = (): void => { cleanup(); resolve(); }, closed = (): void => { cleanup(); reject(new SiwcBrokerError("unknown", 502)); };
          response.once("drain", drained); response.once("close", closed);
        }), end: () => response.end(),
      });
    },
    selected: (host: "127.0.0.1", port: number): SelectedAgentBroker => {
      if (host !== "127.0.0.1" || !Number.isInteger(port) || port < 1024 || port > 65535 || !current() || endpoint && endpoint !== port) fail("binding");
      endpoint = port;
      return Object.freeze({ kind: "host-inference-broker-v1", agentId: grant.agentId, executionId: grant.executionId,
        accountBindingId: grant.account.accountBindingId, host, port, model: grant.model, bearer: localBearer });
    },
    status: () => Object.freeze({ onboarding: "unsupported", released, requests, active, bytes }),
    close: () => { released = true; controllers.forEach(controller => controller.abort()); },
  });
}
export interface SiwcBrokerEndpoint { host: "127.0.0.1"; port: number; close(): void | Promise<void> }
export interface SiwcBrokerSelectorConfiguration {
  /** Returns nothing until trusted onboarding/consent/storage and exact execution scope are available. */
  selectGrant(agent: Readonly<PersonAgent>, execution: Readonly<PersonAgentExecution>, signal: AbortSignal): SiwcExecutionGrant | undefined | Promise<SiwcExecutionGrant | undefined>;
  transport: SiwcTransport;
  /** Host integration acquires an approved numeric loopback endpoint. This module never opens a socket. */
  openEndpoint(handler: (request: IncomingMessage, response: ServerResponse) => void, identity: Readonly<{ agentId: string; executionId: string }>, signal: AbortSignal): Promise<SiwcBrokerEndpoint>;
}
async function closeEndpoint(endpoint: SiwcBrokerEndpoint): Promise<void> {
  const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 5000); timer.unref();
  try { await signalBound(Promise.resolve().then(() => endpoint.close()), controller.signal); } catch {} finally { clearTimeout(timer); }
}
export function createSiwcBrokerSelector(config: SiwcBrokerSelectorConfiguration): {
  selectBroker(agent: Readonly<PersonAgent>, execution: Readonly<PersonAgentExecution>): Promise<SelectedAgentBroker | undefined>;
  /** Retires this execution permanently; reacquisition requires a fresh execution ID. */
  release(agentId: string, executionId: string): Promise<void>;
  close(): Promise<void>;
} {
  if (!fields(config, ["selectGrant", "transport", "openEndpoint"]) || [config.selectGrant, config.transport, config.openEndpoint].some(fn => typeof fn !== "function")) fail("binding");
  const selectGrant = config.selectGrant, transport = config.transport, openEndpoint = config.openEndpoint;
  const pending = new Map<string, Promise<SelectedAgentBroker | undefined>>();
  const owned = new Map<string, { broker: SiwcExecutionBroker; endpoint: SiwcBrokerEndpoint }>();
  const selecting = new Map<string, AbortController>(), instanceKeys = new Map<string, string>(), retired = new Set<string>(); let closed = false;
  return Object.freeze({ selectBroker: async (agent: Readonly<PersonAgent>, execution: Readonly<PersonAgentExecution>) => {
    if (closed) fail("binding");
    if (!validAgentId(agent.id) || !/^[a-f0-9]{64}$/.test(execution.id) || !textId(agent.accountBindingId)) return undefined;
    const key = JSON.stringify([agent.id, execution.id, agent.accountBindingId, agent.model ?? null]);
    const instance = `${agent.id}:${execution.id}`;
    if (retired.has(instance) || instanceKeys.has(instance) && instanceKeys.get(instance) !== key) fail("binding");
    if (!pending.has(key)) {
      if (pending.size >= 128) fail("budget");
      instanceKeys.set(instance, key);
      const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 5000); timer.unref();
      selecting.set(instance, controller);
      pending.set(key, (async () => {
        let broker: SiwcExecutionBroker | undefined;
        let endpoint: SiwcBrokerEndpoint | undefined;
        try {
          let grant: SiwcExecutionGrant | undefined;
          try { grant = await signalBound(Promise.resolve().then(() => selectGrant(Object.freeze(structuredClone(agent)), Object.freeze(structuredClone(execution)), controller.signal)), controller.signal); }
          catch { fail("unauthorized", 401); }
          if (!grant) return undefined;
          const validated = grantCopy(grant);
          if (validated.agentId !== agent.id || validated.executionId !== execution.id || validated.account.accountBindingId !== agent.accountBindingId
            || agent.model !== undefined && validated.model !== agent.model) fail("binding");
          if (closed || retired.has(instance)) fail("binding");
          broker = createSiwcExecutionBroker(validated, transport);
          const opening = Promise.resolve().then(() => openEndpoint(broker!.handler, Object.freeze({ agentId: agent.id, executionId: execution.id }), controller.signal));
          void opening.then(value => { if (controller.signal.aborted) void closeEndpoint(value); }, () => {});
          endpoint = await signalBound(opening, controller.signal);
          if (closed || retired.has(instance) || !fields(endpoint, ["host", "port", "close"]) || typeof endpoint.close !== "function") fail("unsupported", 503);
          const record = broker.selected(endpoint.host, endpoint.port); owned.set(instance, { broker, endpoint }); return record;
        } catch (error) {
          broker?.close(); if (endpoint) await closeEndpoint(endpoint);
          if (!broker && error instanceof SiwcBrokerError) throw error;
          fail("unsupported", 503);
        } finally { clearTimeout(timer); selecting.delete(instance); }
      })());
    }
    return pending.get(key)!;
  }, release: async (agentId: string, executionId: string) => {
    if (!validAgentId(agentId) || !/^[a-f0-9]{64}$/.test(executionId)) fail("binding");
    const instance = `${agentId}:${executionId}`; retired.add(instance); selecting.get(instance)?.abort();
    const value = owned.get(instance); owned.delete(instance);
    if (value) { value.broker.close(); await closeEndpoint(value.endpoint); }
  }, close: async () => {
    closed = true; selecting.forEach(controller => controller.abort()); owned.forEach(value => value.broker.close());
    const endpoints = [...owned.values()].map(value => value.endpoint); owned.clear();
    await Promise.allSettled(endpoints.map(closeEndpoint));
  } });
}
