import { describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { createSiwcBrokerSelector, createSiwcExecutionBroker, normalizeSiwcRequest, SIWC_ONBOARDING, SIWC_RESPONSES_URL,
  type SiwcAccessToken, type SiwcExecutionGrant, type SiwcLocalRequest, type SiwcResponseSink, type SiwcTransport } from "./siwc-inference-broker.js";
import type { PersonAgent } from "./agent-store.js";
import type { PersonAgentExecution } from "./person-agent-runtime.js";

const NOW = 1791115200000;
const TOKEN = "synthetic.siwc.access.token.never-logged";
const account = { accountBindingId: "account-one", clientId: "oaiapp_fixture", subject: "subscriber-one", verification: "host-validated-siwc-v1" as const, storage: "os-protected" as const };
const token: SiwcAccessToken = { ...account, audience: "https://api.openai.com/v1", scopes: ["resource.invoke", "chatgpt.tokens.use.direct"], expiresAt: NOW + 60_000, accessToken: TOKEN };
const grant = (changes: Partial<SiwcExecutionGrant> = {}): SiwcExecutionGrant => ({ agentId: "alice", executionId: "a".repeat(64),
  model: "gpt-6.1-sol", scopeDigest: "b".repeat(64), account: { ...account }, allowedFunctionNames: ["get_customer"],
  budget: { maxRequests: 8, maxConcurrent: 2, maxRequestBytes: 8192, maxResponseBytes: 16_384,
    maxTotalBytes: 64_000, maxEventBytes: 8192, requestTimeoutMs: 1000, expiresAt: NOW + 120_000 },
  getAccessToken: vi.fn(async () => ({ ...token, scopes: [...token.scopes] })), isCurrent: () => true, ...changes });
async function* chunks(value: string, cuts?: number[]): AsyncIterable<Uint8Array> {
  const bytes = Buffer.from(value); let at = 0;
  for (const cut of cuts ?? []) { yield bytes.subarray(at, cut); at = cut; }
  yield bytes.subarray(at);
}
const frame = (event: any): string => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`;
const completed = { type: "response.completed", response: { id: "resp_fixture", status: "completed", service_tier: "default", output: [] } };
const body = (changes: Record<string, any> = {}) => ({ model: "gpt-6.1-sol", input: [{ role: "user", content: "Get customer CUST-12345" }], store: false, stream: true, ...changes });
const request = (bearer: string, value = body(), changes: Partial<SiwcLocalRequest> = {}): SiwcLocalRequest => ({ method: "POST", path: "/v1/responses", host: "127.0.0.1:54321", remoteAddress: "127.0.0.1",
  authorization: `Bearer ${bearer}`, contentType: "application/json", body: chunks(JSON.stringify(value)), ...changes });
function sink(): SiwcResponseSink & { statuses: number[]; values: string[]; ended: boolean } {
  return { statuses: [], values: [], ended: false, start(status) { this.statuses.push(status); }, async write(chunk) { this.values.push(Buffer.from(chunk).toString("utf8")); }, end() { this.ended = true; } };
}
const transport = (): SiwcTransport => vi.fn(async () => ({ status: 200, contentType: "text/event-stream", body: chunks(frame(completed)) }));
function ready(g = grant(), t = transport()) {
  const broker = createSiwcExecutionBroker(g, t, () => NOW), selected = broker.selected("127.0.0.1", 54321);
  return { broker, selected, t, g };
}
// Public specification fixtures, not provider recordings or a real entitlement test:
// https://developers.openai.com/api/docs/guides/tools-tool-search#add-tools-at-a-specific-point-in-the-input
const customerTool = { type: "function", name: "get_customer", description: "Look up a customer by ID.", parameters: {
  type: "object", properties: { customer_id: { type: "string" } }, required: ["customer_id"], additionalProperties: false } };

describe("SIWC documented eager function subset", () => {
  it("accepts actual pinned Hermes/SDK root and function/result shapes without changing native call identity", () => {
    const capture = JSON.parse(readFileSync(new URL("./fixtures/hermes-siwc-shape.json", import.meta.url), "utf8"));
    expect(capture).toMatchObject({ hermesVersion: "0.21.5", sourceSha: "f97608f178d1ffeca59860195ab7da295f7c8e5f", openaiSdkVersion: "2.24.0", gatewayMaxTokensDefault: null });
    for (const name of ["normal", "function", "functionResult", "sdkTimeout"]) {
      const wire = capture.bodies[name], normalized = normalizeSiwcRequest(wire, wire.model, ["get_customer"]);
      expect(normalized).toMatchObject({ model: wire.model, instructions: wire.instructions, reasoning: wire.reasoning, include: wire.include, store: false, stream: true, service_tier: "default" });
      expect(normalized.max_output_tokens).toBeUndefined(); expect(normalized.prompt_cache_retention).toBeUndefined();
      if (wire.tools) expect(normalized.input[0]).toEqual({ type: "additional_tools", role: "developer", tools: wire.tools });
      expect(normalized.input.slice(wire.tools ? 1 : 0)).toEqual(wire.input);
    }
    const result = normalizeSiwcRequest(capture.bodies.functionResult, capture.bodies.functionResult.model, ["get_customer"]);
    expect(capture.normalizedCall).toMatchObject({ name: "get_customer", providerData: { call_id: "call_abc123", response_item_id: "fc_abc123" } });
    expect(result.input).toContainEqual({ type: "function_call", call_id: "call_abc123", name: "get_customer", arguments: '{"customer_id":"CUST-12345"}' });
    expect(result.input).toContainEqual({ type: "function_call_output", call_id: "call_abc123", output: '{"name":"Synthetic Customer"}' });
    expect(capture.sdkTimeoutOption).toBe(30); expect(capture.bodies.sdkTimeout.timeout).toBeUndefined();
    for (const name of ["configuredTokenLimit", "configuredCacheRetention"])
      expect(() => normalizeSiwcRequest(capture.bodies[name], capture.bodies[name].model, ["get_customer"])).toThrow("unsupported");
    expect(capture.bodies.configuredTokenLimit.max_output_tokens).toBe(2048);
    expect(capture.bodies.configuredCacheRetention.prompt_cache_retention).toBe("24h");
  });
  it("adds documented additional_tools while preserving exact names, schema, call ID and result history", () => {
    const input = [{ role: "user", content: "Get customer" }, { type: "function_call", name: "get_customer", call_id: "call_abc123", arguments: '{"customer_id":"CUST-12345"}' },
      { type: "function_call_output", call_id: "call_abc123", output: '{"name":"Customer"}' }];
    const original = body({ input, tools: [customerTool], tool_choice: "auto", service_tier: "normal" });
    const normalized = normalizeSiwcRequest(original, original.model, ["get_customer"]);
    expect(normalized.tools).toBeUndefined();
    expect(normalized.input).toEqual([{ type: "additional_tools", role: "developer", tools: [customerTool] }, ...input]);
    expect(normalized).toMatchObject({ store: false, stream: true, service_tier: "default" });
    expect(original.input).toEqual(input); expect(original.tools).toEqual([customerTool]);
  });
  it("rejects unsupported SIWC fields and billing overrides before handoff", () => {
    for (const key of ["max_output_tokens", "prompt_cache_retention", "previous_response_id", "background", "metadata", "multi_agent", "temperature", "model_provider", "base_url"])
      expect(() => normalizeSiwcRequest(body({ [key]: 1 }), "gpt-6.1-sol", [])).toThrow("unsupported");
    for (const tier of ["priority", "flex", "auto", null]) expect(() => normalizeSiwcRequest(body({ service_tier: tier }), "gpt-6.1-sol", [])).toThrow("unsupported");
    expect(() => normalizeSiwcRequest(body({ input: [{ role: "system", content: "hidden" }] }), "gpt-6.1-sol", [])).toThrow("unsupported");
  });
  it("does not allow client input items or schemas to widen immutable tool authority", () => {
    for (const tools of [[{ ...customerTool, name: "terminal" }], [customerTool, customerTool], [{ ...customerTool, defer_loading: true }], [{ type: "tool_search" }], [{ type: "computer" }], [{ type: "namespace", name: "crm", tools: [customerTool] }]])
      expect(() => normalizeSiwcRequest(body({ tools }), "gpt-6.1-sol", ["get_customer"])).toThrow("unsupported");
    expect(() => normalizeSiwcRequest(body({ input: [{ type: "additional_tools", role: "developer", tools: [customerTool] }] }), "gpt-6.1-sol", [])).toThrow("unsupported");
    expect(() => normalizeSiwcRequest(body({ input: [{ type: "function_call", name: "terminal", call_id: "call_x", arguments: "{}" }] }), "gpt-6.1-sol", [])).toThrow("unsupported");
  });
});

describe("host-only SIWC execution broker", () => {
  it("keeps onboarding unsupported, mints separate per-execution local bearer and never reports provider tokens", async () => {
    const a = ready(), b = ready(grant({ executionId: "c".repeat(64) }));
    expect(SIWC_ONBOARDING.status).toBe("unsupported"); expect(a.broker.status().onboarding).toBe("unsupported");
    expect(a.selected.bearer).toHaveLength(64); expect(a.selected.bearer).not.toBe(b.selected.bearer);
    expect(JSON.stringify(a.selected)).not.toContain(TOKEN); expect(JSON.stringify(a.broker.status())).not.toContain(a.selected.bearer);
    a.broker.close(); expect(() => a.broker.selected("127.0.0.1", 54321)).toThrow("binding");
  });
  it("pins official Responses and account/model/bearer binding; failed requests never call token or transport", async () => {
    const { broker, selected, g, t } = ready();
    const cases = [request("wrong"), request(selected.bearer, body({ model: "other" })), request(selected.bearer, body(), { path: "/backend-api/codex/responses" }),
      request(selected.bearer, body(), { host: "localhost:54321" }), request(selected.bearer, body(), { remoteAddress: "::1" }), request(selected.bearer, body(), { contentEncoding: "gzip" })];
    for (const req of cases) { const out = sink(); await broker.dispatch(req, out); expect(out.statuses[0]).not.toBe(200); expect(out.ended).toBe(true); }
    expect(g.getAccessToken).not.toHaveBeenCalled(); expect(t).not.toHaveBeenCalled();
  });
  it("uses only injected app-specific token with direct permission, valid expiry and exact account", async () => {
    for (const change of [{ accountBindingId: "other" }, { clientId: "oaiapp_other" }, { subject: "other" }, { storage: "plaintext" }, { scopes: ["openid"] }, { expiresAt: NOW }, { audience: "https://chatgpt.com" }]) {
      const t = transport(), { broker, selected } = ready(grant({ getAccessToken: async () => ({ ...token, ...change } as SiwcAccessToken) }), t), out = sink();
      await broker.dispatch(request(selected.bearer), out); expect(out.statuses).toEqual([401]); expect(t).not.toHaveBeenCalled();
      expect(out.values.join("")).not.toContain(TOKEN);
    }
  });
  it("forwards one HTTP/SSE request and leaves tool result execution and call identity in Hermes", async () => {
    const call = { type: "function_call", id: "fc_abc123", name: "get_customer", namespace: "get_customer", call_id: "call_abc123", arguments: '{"customer_id":"CUST-12345"}' };
    const events = frame({ type: "response.output_item.done", output_index: 0, item: call }) + frame({ ...completed, response: { ...completed.response, output: [call] } });
    const t = vi.fn<SiwcTransport>(async () => ({ status: 200, contentType: "text/event-stream; charset=utf-8", body: chunks(events, [3, 13, 37]) })), { broker, selected } = ready(grant(), t), out = sink();
    await broker.dispatch(request(selected.bearer, body({ tools: [customerTool] })), out);
    expect(t).toHaveBeenCalledOnce(); const sent = t.mock.calls[0][0]!;
    expect(sent.url).toBe(SIWC_RESPONSES_URL); expect(sent.headers.authorization).toBe(`Bearer ${TOKEN}`);
    expect(JSON.parse(sent.body).input[0]).toEqual({ type: "additional_tools", role: "developer", tools: [customerTool] });
    expect(out.statuses).toEqual([200]); expect(out.values.join("")).toContain('"call_id":"call_abc123"'); expect(out.values.join("")).toContain('"name":"get_customer"');
    expect(out.values.join("")).not.toContain(TOKEN); expect(broker.status()).toMatchObject({ requests: 1, active: 0 });
  });
  it("does not trust a native provider nonstandard tier, unauthorized tool call or secret echo", async () => {
    for (const event of [{ ...completed, response: { ...completed.response, service_tier: "priority" } },
      { type: "response.output_item.done", item: { type: "function_call", name: "terminal", call_id: "call_x", arguments: "{}" } },
      { type: "response.output_text.delta", delta: TOKEN }, { type: "response.failed", response: { error: { message: TOKEN } } }]) {
      const { broker, selected } = ready(grant(), async () => ({ status: 200, contentType: "text/event-stream", body: chunks(frame(event)) })), out = sink();
      await broker.dispatch(request(selected.bearer), out);
      expect(out.values.join("")).toContain('"code":"unknown"'); expect(out.values.join("")).not.toContain(TOKEN);
      expect(out.values.join("")).not.toContain('"type":"response.completed"');
    }
  });
  it("keeps denied/admission errors generic and does not retry or switch billing/provider", async () => {
    for (const status of [401, 403, 429, 503]) {
      const t = vi.fn(async () => ({ status, contentType: "application/json", body: chunks(`{"error":"${TOKEN}"}`) })), { broker, selected } = ready(grant(), t), out = sink();
      await broker.dispatch(request(selected.bearer), out); expect(t).toHaveBeenCalledOnce(); expect(out.statuses[0]).not.toBe(200); expect(out.values.join("")).not.toContain(TOKEN);
    }
  });
  it("enforces request/concurrency/byte budgets including slow body readers", async () => {
    const g = grant(); g.budget.maxRequests = 1; g.budget.maxConcurrent = 1; const { broker, selected, t } = ready(g);
    const out = sink(); await broker.dispatch(request(selected.bearer), out); const rejected = sink(); await broker.dispatch(request(selected.bearer), rejected);
    expect(rejected.statuses).toEqual([429]); expect(t).toHaveBeenCalledOnce();
    const huge = ready(), rejectedBody = sink(); await huge.broker.dispatch(request(huge.selected.bearer, body({ input: [{ role: "user", content: "x".repeat(9000) }] })), rejectedBody);
    expect(rejectedBody.statuses).toEqual([413]); expect(huge.t).not.toHaveBeenCalled();
  });
  it("reserves concurrency before reading a body and releases it on cancellation", async () => {
    const g = grant(); g.budget.maxConcurrent = 1;
    const a = ready(g), cancel = new AbortController(); let reading!: () => void;
    const entered = new Promise<void>(resolve => { reading = resolve; });
    const blockedBody = { [Symbol.asyncIterator]: () => ({ next: () => { reading(); return new Promise<IteratorResult<Uint8Array>>(() => {}); }, return: async () => ({ done: true as const, value: undefined }) }) };
    const first = sink(), live = a.broker.dispatch(request(a.selected.bearer, body(), { body: blockedBody, signal: cancel.signal }), first);
    await entered; const second = sink(); await a.broker.dispatch(request(a.selected.bearer), second);
    expect(second.statuses).toEqual([429]); expect(a.t).not.toHaveBeenCalled(); expect(a.broker.status().active).toBe(1);
    cancel.abort(); await live; expect(first.ended).toBe(true); expect(a.broker.status().active).toBe(0);
  });
  it("copies grants and cannot adopt a caller's changed account, tools or budget", async () => {
    const g = grant(), a = ready(g);
    g.account.accountBindingId = "other"; g.allowedFunctionNames = ["terminal"]; g.budget.maxRequests = 1000;
    const out = sink(); await a.broker.dispatch(request(a.selected.bearer, body({ tools: [{ ...customerTool, name: "terminal" }] })), out);
    expect(out.statuses).toEqual([400]); expect(a.t).not.toHaveBeenCalled();
    const good = sink(); await a.broker.dispatch(request(a.selected.bearer), good); expect(good.statuses).toEqual([200]);
    const invalid = sink(); await a.broker.dispatch(request("界".repeat(64)), invalid); expect(invalid.statuses).toEqual([401]);
  });
  it("bounds SSE frames, preserves fragmented CRLF and treats nonterminal EOF as unknown", async () => {
    const text = frame({ type: "response.output_text.delta", delta: "こんにちは" }) + frame(completed), crlf = text.replace(/\n/g, "\r\n");
    const { broker, selected } = ready(grant(), async () => ({ status: 200, contentType: "text/event-stream", body: chunks(crlf, [...Buffer.from(crlf).keys()].map(n => n + 1)) })), out = sink();
    await broker.dispatch(request(selected.bearer), out); expect(out.values.join("")).toContain("こんにちは"); expect(out.values.join("")).toContain("response.completed");
    for (const stream of [frame({ type: "response.output_text.delta", delta: "partial" }), "data: " + "x".repeat(9000)]) {
      const x = ready(grant(), async () => ({ status: 200, contentType: "text/event-stream", body: chunks(stream) })), r = sink();
      await x.broker.dispatch(request(x.selected.bearer), r); expect(r.values.join("")).toMatch(/unknown|budget/); expect(r.values.join("")).not.toContain("response.completed");
    }
  });
  it("awaits sink backpressure and cancels stuck transport/writer without synthetic completion", async () => {
    const g = grant(); g.budget.requestTimeoutMs = 30;
    let observedSignal: AbortSignal | undefined;
    const t: SiwcTransport = async sent => { observedSignal = sent.signal; return new Promise(() => {}); };
    const a = ready(g, t), out = sink(); await a.broker.dispatch(request(a.selected.bearer), out);
    expect(observedSignal?.aborted).toBe(true); expect(out.ended).toBe(true); expect(out.values.join("")).not.toContain("response.completed");
    let reads = 0; async function* upstream() { reads++; yield Buffer.from(frame({ type: "response.output_text.delta", delta: "first" })); reads++; yield Buffer.from(frame(completed)); }
    const b = ready(g, async () => ({ status: 200, contentType: "text/event-stream", body: upstream() }));
    const blocked = sink(); blocked.write = () => new Promise(() => {}); await b.broker.dispatch(request(b.selected.bearer), blocked);
    expect(reads).toBe(1); expect(blocked.ended).toBe(true); expect(b.broker.status().active).toBe(0);
  });
  it("ends a stalled provider at the execution expiry even when its request deadline is later", async () => {
    const at = Date.now(), g = grant(); g.budget.expiresAt = at + 30;
    g.getAccessToken = async () => ({ ...token, expiresAt: at + 60_000 });
    let providerSignal!: AbortSignal;
    const broker = createSiwcExecutionBroker(g, async sent => { providerSignal = sent.signal; return new Promise(() => {}); });
    const selected = broker.selected("127.0.0.1", 54321), out = sink();
    await broker.dispatch(request(selected.bearer), out);
    expect(providerSignal.aborted).toBe(true); expect(out.ended).toBe(true); expect(broker.status().active).toBe(0);
    expect(out.values.join("")).not.toContain("response.completed");
  });
  it("fences provider admission and response emission when host currency or execution is no longer current", async () => {
    let current = true; const g = grant({ isCurrent: () => current });
    g.getAccessToken = async () => { current = false; return token; };
    const a = ready(g), out = sink(); await a.broker.dispatch(request(a.selected.bearer), out); expect(a.t).not.toHaveBeenCalled(); expect(out.statuses).toEqual([401]);
    const b = ready(), next = sink(); b.broker.close(); await b.broker.dispatch(request(b.selected.bearer), next); expect(next.statuses).toEqual([403]); expect(b.t).not.toHaveBeenCalled();
  });
});

describe("curated factory broker selection", () => {
  const person = { id: "alice", accountBindingId: "account-one", model: "gpt-6.1-sol" } as PersonAgent;
  const execution = { kind: "ordinary", id: "a".repeat(64), scratchRoot: "/unused", workspace: "/unused", memoryDir: "/unused" } as PersonAgentExecution;
  it("returns no auth broker before verified onboarding and opens no endpoint", async () => {
    const openEndpoint = vi.fn(), selector = createSiwcBrokerSelector({ selectGrant: async () => undefined, transport: transport(), openEndpoint });
    expect(await selector.selectBroker(person, execution)).toBeUndefined(); expect(openEndpoint).not.toHaveBeenCalled();
  });
  it("memoizes exact execution startup, rejects mismatched account/model and closes only owned endpoints", async () => {
    const close = vi.fn(), openEndpoint = vi.fn(async () => ({ host: "127.0.0.1" as const, port: 54321, close }));
    const live = grant(); live.budget.expiresAt = Date.now() + 60_000;
    const selector = createSiwcBrokerSelector({ selectGrant: async () => live, transport: transport(), openEndpoint });
    const [a, b] = await Promise.all([selector.selectBroker(person, execution), selector.selectBroker(person, execution)]);
    expect(a).toBe(b); expect(openEndpoint).toHaveBeenCalledOnce(); expect(a).toMatchObject({ agentId: "alice", executionId: execution.id, accountBindingId: "account-one" });
    await expect(selector.selectBroker({ ...person, accountBindingId: "other" }, execution)).rejects.toThrow("binding");
    await expect(selector.selectBroker({ ...person, model: "other" }, execution)).rejects.toThrow("binding");
    expect(openEndpoint).toHaveBeenCalledOnce(); await selector.close(); expect(close).toHaveBeenCalledOnce();
    await expect(selector.selectBroker(person, execution)).rejects.toThrow("binding");
  });
  it("refuses nonnumeric or widened host endpoints and invalid/ambient credential attestations", async () => {
    for (const g of [grant({ account: { ...account, clientId: "app_EMoamEEZ73f0CkXaXp7hrann" } }), grant({ account: { ...account, storage: "plaintext" } as any })])
      expect(() => createSiwcExecutionBroker(g, transport(), () => NOW)).toThrow("binding");
    const g = grant(); g.budget.expiresAt = Date.now() + 60_000; const close = vi.fn();
    const selector = createSiwcBrokerSelector({ selectGrant: async () => g, transport: transport(), openEndpoint: async () => ({ host: "0.0.0.0", port: 54321, close } as any) });
    await expect(selector.selectBroker(person, execution)).rejects.toThrow("unsupported"); expect(close).toHaveBeenCalledOnce();
  });
  it("retirement revokes the exact execution and never reuses its consumed bearer", async () => {
    const close = vi.fn(), openEndpoint = vi.fn(async () => ({ host: "127.0.0.1" as const, port: 54321, close }));
    const live = grant(); live.budget.expiresAt = Date.now() + 60_000;
    const selector = createSiwcBrokerSelector({ selectGrant: async (_a, e) => ({ ...live, executionId: e.id }), transport: transport(), openEndpoint });
    const a = await selector.selectBroker(person, execution); await selector.release(person.id, execution.id);
    await expect(selector.selectBroker(person, execution)).rejects.toThrow("binding"); expect(close).toHaveBeenCalledOnce();
    const b = await selector.selectBroker(person, { ...execution, id: "c".repeat(64) }); expect(b?.bearer).not.toBe(a?.bearer);
    await selector.close(); expect(close).toHaveBeenCalledTimes(2);
  });
  it("aborts pending host acquisition and closes a late endpoint instead of adopting it", async () => {
    const close = vi.fn(); let opened!: () => void, finish!: (value: any) => void;
    const entering = new Promise<void>(resolve => { opened = resolve; });
    const live = grant(); live.budget.expiresAt = Date.now() + 60_000;
    let signal!: AbortSignal;
    const selector = createSiwcBrokerSelector({ selectGrant: async () => live, transport: transport(), openEndpoint: async (_h, _i, s) => { signal = s; opened(); return new Promise(resolve => { finish = resolve; }); } });
    const selecting = selector.selectBroker(person, execution); const rejected = expect(selecting).rejects.toThrow("unsupported");
    await entering; await selector.release(person.id, execution.id); expect(signal.aborted).toBe(true); await rejected;
    finish({ host: "127.0.0.1", port: 54321, close }); await new Promise(resolve => setImmediate(resolve));
    expect(close).toHaveBeenCalledOnce(); await selector.close(); expect(close).toHaveBeenCalledOnce();
  });
  it("does not turn a cancelled registration prerequisite into a socket or a retried lookup", async () => {
    let entered!: () => void; const starting = new Promise<void>(resolve => { entered = resolve; }); let signal!: AbortSignal;
    const selectGrant = vi.fn(async (_a, _e, s: AbortSignal) => { signal = s; entered(); return new Promise<SiwcExecutionGrant>(() => {}); }), openEndpoint = vi.fn();
    const selector = createSiwcBrokerSelector({ selectGrant, transport: transport(), openEndpoint });
    const pending = selector.selectBroker(person, execution), refusal = expect(pending).rejects.toThrow("unauthorized");
    await starting; await selector.close(); await refusal; expect(signal.aborted).toBe(true);
    expect(selectGrant).toHaveBeenCalledOnce(); expect(openEndpoint).not.toHaveBeenCalled();
  });
});

describe("quiescent host grant lifecycle", () => {
  it("reprepares an expired grant on the same endpoint/bearer without resubmitting prior requests", async () => {
    let now = NOW; const t = transport(), changed = vi.fn();
    const initial = grant(), prepare = vi.fn(async () => grant({ budget: { ...initial.budget, expiresAt: now + 120_000 },
      getAccessToken: async () => ({ ...token, expiresAt: now + 60_000 }) }));
    const broker = createSiwcExecutionBroker(initial, t, () => now, { prepare, changed });
    const selected = broker.selected("127.0.0.1", 54321);
    await broker.dispatch(request(selected.bearer), sink());
    now += 130_000;
    const out = sink(); await broker.dispatch(request(selected.bearer), out);
    expect(out.statuses).toEqual([200]); expect(t).toHaveBeenCalledTimes(2); expect(prepare).toHaveBeenCalledOnce();
    expect(broker.selected("127.0.0.1", 54321)).toEqual(selected); expect(changed).toHaveBeenCalledWith("renewed");
  });
  it("renews exhausted finite request budgets, but refuses changed authority and never repeats a handoff", async () => {
    const initial = grant(); initial.budget.maxRequests = 1; initial.budget.maxConcurrent = 1;
    const t = transport(), changed = vi.fn(), prepare = vi.fn(async () => grant({ budget: { ...initial.budget } }));
    const broker = createSiwcExecutionBroker(initial, t, () => NOW, { prepare, changed }), selected = broker.selected("127.0.0.1", 54321);
    await broker.dispatch(request(selected.bearer), sink()); await broker.dispatch(request(selected.bearer), sink());
    expect(t).toHaveBeenCalledTimes(2); expect(prepare).toHaveBeenCalledOnce();
    prepare.mockResolvedValueOnce(grant({ model: "different-authority", budget: { ...initial.budget } }));
    const rejected = sink(); await broker.dispatch(request(selected.bearer), rejected);
    expect(rejected.statuses).toEqual([403]); expect(t).toHaveBeenCalledTimes(2); expect(changed).toHaveBeenCalledWith("unavailable");
  });
  it("does not rotate under an admitted stream or renew a held execution", async () => {
    let release!: () => void;
    const t = vi.fn(async () => ({ status: 200, contentType: "text/event-stream", body: (async function* () {
      await new Promise<void>(resolve => { release = resolve; }); yield Buffer.from(frame(completed));
    })() }));
    let current = true; const initial = grant({ isCurrent: () => current }); initial.budget.maxRequests = 1; initial.budget.maxConcurrent = 1;
    const prepare = vi.fn(async () => initial), changed = vi.fn(), broker = createSiwcExecutionBroker(initial, t, () => NOW, { prepare, changed });
    const selected = broker.selected("127.0.0.1", 54321), running = broker.dispatch(request(selected.bearer), sink());
    await vi.waitFor(() => expect(release).toBeTypeOf("function"));
    const busy = sink(); await broker.dispatch(request(selected.bearer), busy); expect(busy.statuses).toEqual([429]); expect(prepare).not.toHaveBeenCalled();
    release(); await running; current = false;
    const held = sink(); await broker.dispatch(request(selected.bearer), held); expect(held.statuses).toEqual([403]); expect(prepare).not.toHaveBeenCalled();
    expect(t).toHaveBeenCalledOnce();
  });
});


it("bounds callers waiting for a coalesced grant preparation before reading their bodies", async () => {
  const initial = grant(); initial.budget.maxRequests = 1; initial.budget.maxConcurrent = 1;
  let finish!: (value: SiwcExecutionGrant) => void;
  const prepare = vi.fn(() => new Promise<SiwcExecutionGrant>(resolve => { finish = resolve; })), t = transport();
  const broker = createSiwcExecutionBroker(initial, t, () => NOW, { prepare, changed() {} }), selected = broker.selected("127.0.0.1", 54321);
  await broker.dispatch(request(selected.bearer), sink());
  const pendingOut = sink(), pending = broker.dispatch(request(selected.bearer), pendingOut);
  await vi.waitFor(() => expect(prepare).toHaveBeenCalledOnce());
  let read = false;
  const refused = sink(); await broker.dispatch(request(selected.bearer, body(), { body: (async function* () { read = true; yield Buffer.from("{}"); })() }), refused);
  expect(refused.statuses).toEqual([429]); expect(read).toBe(false);
  finish(grant({ budget: { ...initial.budget } })); await pending;
  expect(pendingOut.statuses).toEqual([200]); expect(t).toHaveBeenCalledTimes(2);
});
