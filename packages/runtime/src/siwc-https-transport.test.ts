import { EventEmitter } from "node:events";
import { checkServerIdentity, rootCertificates } from "node:tls";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createSiwcHttpsTransport } from "./siwc-https-transport.js";
import { createSiwcExecutionBroker, SIWC_RESPONSES_URL, type SiwcTransportRequest } from "./siwc-inference-broker.js";

const network = vi.hoisted(() => ({ agents: [] as any[], calls: [] as any[] }));
vi.mock("node:https", async () => {
  const { EventEmitter } = await import("node:events");
  return {
    Agent: class { destroy = vi.fn(); constructor(readonly options: unknown) { network.agents.push(this); } },
    request: vi.fn((options, reply) => {
      const request = new EventEmitter() as any;
      request.destroy = vi.fn(); request.end = vi.fn();
      network.calls.push({ options, reply, request }); return request;
    }),
  };
});
const TOKEN = "synthetic.transport.token.never-logged";
function input(changes: Partial<SiwcTransportRequest> = {}): SiwcTransportRequest {
  return { url: SIWC_RESPONSES_URL, method: "POST", headers: { authorization: `Bearer ${TOKEN}`,
    "content-type": "application/json", accept: "text/event-stream" },
    body: JSON.stringify({ model: "synthetic-model", store: false, stream: true, input: [] }),
    signal: new AbortController().signal, ...changes };
}
function response(chunks: Uint8Array[] = [Buffer.from("data: synthetic\n\n")], options: {
  status?: number; headers?: Record<string, unknown>; complete?: boolean; error?: Error;
} = {}) {
  const incoming = new EventEmitter() as any;
  incoming.statusCode = options.status ?? 200;
  incoming.headers = { "content-type": "text/event-stream", ...options.headers };
  incoming.complete = false; incoming.destroy = vi.fn();
  const next = vi.fn(async () => {
    if (options.error) throw options.error;
    const chunk = chunks.shift();
    if (chunk) return { done: false, value: chunk };
    incoming.complete = options.complete ?? true; return { done: true, value: undefined };
  });
  const iterator = { next, return: vi.fn(async () => ({ done: true, value: undefined })) };
  incoming[Symbol.asyncIterator] = vi.fn(() => iterator);
  return { incoming, next, iterator };
}
async function admit(transport = createSiwcHttpsTransport(), supplied = input(), fixture = response()) {
  const pending = transport(supplied);
  network.calls.at(-1).reply(fixture.incoming);
  return { transport, supplied, fixture, result: await pending };
}
beforeEach(() => { network.agents.length = 0; network.calls.length = 0; });
afterEach(() => { vi.useRealTimers(); });

describe("fixed SIWC HTTPS transport with inert network", () => {
  it("constructs without I/O and fixes endpoint, TLS trust, proxy and request headers", async () => {
    const transport = createSiwcHttpsTransport(); expect(network.calls).toHaveLength(0);
    const { result, supplied } = await admit(transport);
    expect(network.calls).toHaveLength(1);
    expect(network.calls[0].options).toEqual({ protocol: "https:", hostname: "api.openai.com", port: 443,
      path: "/v1/responses", method: "POST", agent: network.agents[0], rejectUnauthorized: true,
      servername: "api.openai.com", checkServerIdentity, ca: [...rootCertificates], maxHeaderSize: 16384,
      headers: { ...supplied.headers, "accept-encoding": "identity", "content-length": String(Buffer.byteLength(supplied.body)) } });
    expect(network.agents[0].options).toEqual({ keepAlive: false, maxSockets: 1, maxCachedSessions: 0,
      proxyEnv: {}, ca: [...rootCertificates], rejectUnauthorized: true, servername: "api.openai.com", checkServerIdentity });
    expect(network.calls[0].request.end).toHaveBeenCalledExactlyOnceWith(supplied.body);
    await result.body[Symbol.asyncIterator]().return!();
    expect(network.agents[0].destroy).toHaveBeenCalledOnce();
  });

  it("rejects route/header/body injection and pre-abort before creating an agent", async () => {
    const transport = createSiwcHttpsTransport();
    const aborted = new AbortController(); aborted.abort();
    const variants: any[] = [input({ url: "https://evil.example/v1/responses" as any }), input({ method: "GET" as any }),
      input({ headers: { ...input().headers, authorization: `Bearer ${TOKEN}\r\nCookie: secret` } }),
      input({ headers: { ...input().headers, cookie: "synthetic" } as any }), input({ body: "not json" }),
      input({ body: JSON.stringify({ store: true, stream: true }) }), input({ body: JSON.stringify({ store: false, stream: false }) }),
      input({ body: JSON.stringify({ store: false, stream: true, input: TOKEN }) }),
      input({ body: JSON.stringify({ store: false, stream: true, input: "x".repeat(4 * 1024 * 1024) }) }),
      input({ signal: aborted.signal })];
    for (const supplied of variants) await expect(transport(supplied)).rejects.toThrow(/^SIWC broker /);
    expect(network.calls).toHaveLength(0); expect(network.agents).toHaveLength(0);
  });

  it("reads only when pulled and releases sockets on normal HTTP completion", async () => {
    const { result, fixture } = await admit();
    expect(fixture.next).not.toHaveBeenCalled();
    const iterator = result.body[Symbol.asyncIterator]();
    expect(await iterator.next()).toEqual({ done: false, value: Buffer.from("data: synthetic\n\n") });
    expect(fixture.next).toHaveBeenCalledOnce(); expect(network.agents[0].destroy).not.toHaveBeenCalled();
    expect(await iterator.next()).toEqual({ done: true, value: undefined });
    expect(network.agents[0].destroy).toHaveBeenCalledOnce();
    expect(await iterator.next()).toEqual({ done: true, value: undefined });
  });

  it("cancels before the first pull, releases reservations, and does not consume unread bodies", async () => {
    const transport = createSiwcHttpsTransport();
    // More than the concurrency bound, each retired without ever starting its body iterator.
    for (let i = 0; i < 40; i++) {
      const { result, fixture } = await admit(transport);
      await result.body[Symbol.asyncIterator]().return!();
      expect(fixture.next).not.toHaveBeenCalled(); expect(fixture.incoming.destroy).toHaveBeenCalledOnce();
    }
    expect(network.agents.every(agent => agent.destroy.mock.calls.length === 1)).toBe(true);
  });

  it("discards errors and redirect bodies without retrying or following Location", async () => {
    const transport = createSiwcHttpsTransport();
    for (const status of [302, 401, 403, 429, 503]) {
      const fixture = response([Buffer.from(TOKEN)], { status, headers: { "content-type": "application/json", location: "https://evil.example" } });
      const { result } = await admit(transport, input(), fixture);
      expect(result.status).toBe(status); expect(await result.body[Symbol.asyncIterator]().next()).toEqual({ done: true, value: undefined });
      expect(fixture.next).not.toHaveBeenCalled(); expect(fixture.incoming.destroy).toHaveBeenCalledOnce();
    }
    expect(network.calls).toHaveLength(5);
  });

  it("bounds declared and streamed bytes, and refuses content compression", async () => {
    const transport = createSiwcHttpsTransport();
    for (const headers of [{ "content-encoding": "gzip" }, { "content-length": String(32 * 1024 * 1024 + 1) },
      { "content-length": "NaN" }, { "content-type": ["text/event-stream"] }]) {
      const fixture = response([], { headers }), pending = transport(input());
      const rejected = expect(pending).rejects.toThrow(/^SIWC broker /);
      network.calls.at(-1).reply(fixture.incoming); await rejected;
      expect(fixture.next).not.toHaveBeenCalled(); expect(fixture.incoming.destroy).toHaveBeenCalledOnce();
    }
    const { result } = await admit(transport, input(), response([new Uint8Array(32 * 1024 * 1024 + 1)]));
    await expect(result.body[Symbol.asyncIterator]().next()).rejects.toMatchObject({ code: "budget" });
    expect(network.agents.every(agent => agent.destroy.mock.calls.length === 1)).toBe(true);
  });

  it("does not mistake truncated HTTP or native errors for completion or expose error details", async () => {
    for (const fixture of [response([], { complete: false }), response([], { error: new Error(TOKEN) })]) {
      const { result } = await admit(createSiwcHttpsTransport(), input(), fixture);
      await expect(result.body[Symbol.asyncIterator]().next()).rejects.toThrow("SIWC broker unknown");
      expect(fixture.incoming.destroy).toHaveBeenCalledOnce();
    }
    const pending = createSiwcHttpsTransport()(input());
    const rejected = expect(pending).rejects.toThrow("SIWC broker unknown");
    network.calls.at(-1).request.emit("error", new Error(TOKEN)); await rejected;
    expect(network.agents.at(-1).destroy).toHaveBeenCalledOnce();
  });

  it("aborts both pre-header requests and unconsumed responses with an absolute deadline", async () => {
    vi.useFakeTimers();
    const controller = new AbortController(), transport = createSiwcHttpsTransport();
    const pending = transport(input({ signal: controller.signal }));
    const rejected = expect(pending).rejects.toThrow("SIWC broker unknown"); controller.abort(); await rejected;
    expect(network.calls.at(-1).request.destroy).toHaveBeenCalledOnce();
    const later = new AbortController(); const { result, fixture } = await admit(transport, input({ signal: later.signal }));
    later.abort(); await expect(result.body[Symbol.asyncIterator]().next()).rejects.toThrow("SIWC broker unknown");
    expect(fixture.next).not.toHaveBeenCalled();
    const timed = transport(input()), timedRejected = expect(timed).rejects.toThrow("SIWC broker unknown");
    await vi.advanceTimersByTimeAsync(120_000); await timedRejected;
    expect(network.agents.every(agent => agent.destroy.mock.calls.length === 1)).toBe(true);
  });

  it("caps concurrent requests and admits a new one only after cancellation", async () => {
    const transport = createSiwcHttpsTransport(), controllers: AbortController[] = [], pending: Promise<unknown>[] = [];
    for (let i = 0; i < 32; i++) {
      const controller = new AbortController(); controllers.push(controller);
      pending.push(transport(input({ signal: controller.signal })).catch(error => error));
    }
    await expect(transport(input())).rejects.toMatchObject({ code: "budget" });
    expect(network.calls).toHaveLength(32);
    controllers[0].abort();
    const { result } = await admit(transport); await result.body[Symbol.asyncIterator]().return!();
    controllers.forEach(controller => controller.abort()); await Promise.all(pending);
    expect(network.calls).toHaveLength(33);
    expect(network.agents.every(agent => agent.destroy.mock.calls.length === 1)).toBe(true);
  });

  it("composes with the execution broker without exposing either bearer or replaying the request", async () => {
    const identity = { accountBindingId: "synthetic-account", clientId: "oaiapp_fixture", subject: "synthetic-subject",
      verification: "host-validated-siwc-v1" as const, storage: "os-protected" as const };
    const broker = createSiwcExecutionBroker({ agentId: "alice", executionId: "a".repeat(64), scopeDigest: "b".repeat(64),
      account: identity, model: "synthetic-model", allowedFunctionNames: [], isCurrent: () => true,
      budget: { maxRequests: 1, maxConcurrent: 1, maxRequestBytes: 8192, maxResponseBytes: 16384,
        maxTotalBytes: 64000, maxEventBytes: 8192, requestTimeoutMs: 1000, expiresAt: Date.now() + 60000 },
      getAccessToken: async () => ({ ...identity, audience: "https://api.openai.com/v1", scopes: ["resource.invoke", "chatgpt.tokens.use.direct"],
        expiresAt: Date.now() + 60000, accessToken: TOKEN }) }, createSiwcHttpsTransport());
    const selected = broker.selected("127.0.0.1", 54321), output: string[] = [], statuses: number[] = [];
    const pending = broker.dispatch({ method: "POST", path: "/v1/responses", host: "127.0.0.1:54321", remoteAddress: "127.0.0.1",
      authorization: `Bearer ${selected.bearer}`, contentType: "application/json",
      body: { async *[Symbol.asyncIterator]() { yield Buffer.from(JSON.stringify({ model: "synthetic-model", store: false,
        stream: true, input: [{ role: "user", content: "Synthetic prompt" }] })); } } },
      { start: status => statuses.push(status), write: async value => { output.push(Buffer.from(value).toString()); }, end: () => {} });
    await vi.waitFor(() => expect(network.calls).toHaveLength(1));
    expect(network.calls[0].options.headers.authorization).toBe(`Bearer ${TOKEN}`);
    expect(JSON.parse(network.calls[0].request.end.mock.calls[0][0])).toMatchObject({ store: false, stream: true, service_tier: "default" });
    const completed = { type: "response.completed", response: { id: "resp_synthetic", status: "completed", service_tier: "default", output: [] } };
    network.calls[0].reply(response([Buffer.from(`event: response.completed\ndata: ${JSON.stringify(completed)}\n\n`)]).incoming);
    await pending;
    expect(statuses).toEqual([200]); expect(output.join("")).toContain("response.completed");
    expect(output.join("")).not.toContain(TOKEN); expect(output.join("")).not.toContain(selected.bearer);
    expect(network.calls).toHaveLength(1); expect(network.agents[0].destroy).toHaveBeenCalledOnce();
    expect(broker.status()).toMatchObject({ requests: 1, active: 0 }); broker.close();
  });
});
