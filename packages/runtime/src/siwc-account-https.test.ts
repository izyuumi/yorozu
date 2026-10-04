import { EventEmitter } from "node:events";
import { checkServerIdentity, rootCertificates } from "node:tls";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createSiwcAccountHttps } from "./siwc-account-https.js";
import { SIWC_DISCOVERY_URL, SIWC_ISSUER, SIWC_JWKS_URL, SIWC_RESOURCE, SIWC_TOKEN_URL } from "./siwc-account-lifecycle.js";

const network = vi.hoisted(() => ({ agents: [] as any[], calls: [] as any[] }));
vi.mock("node:https", async () => {
  const { EventEmitter } = await import("node:events");
  return { Agent: class { destroy = vi.fn(); constructor(readonly options: unknown) { network.agents.push(this); } },
    request: vi.fn((options, reply) => {
      const request = new EventEmitter() as any; request.destroy = vi.fn(); request.end = vi.fn();
      network.calls.push({ options, reply, request }); return request;
    }) };
});
const SECRET = "synthetic.oauth.token.never-logged";
const revoke = `${SIWC_ISSUER}/api/accounts/oauth/revoke`;
const form = () => ({ grant_type: "authorization_code", client_id: "oaiapp_fixture", code: "synthetic-code",
  code_verifier: "v".repeat(64), redirect_uri: "http://127.0.0.1:54000/auth/callback", resource: SIWC_RESOURCE });
const request = (changes: Record<string, unknown> = {}) => ({ url: SIWC_TOKEN_URL, method: "POST" as const,
  form: form(), signal: new AbortController().signal, ...changes }) as any;
function response(value: unknown, options: { status?: number; headers?: Record<string, unknown>; bytes?: Uint8Array; complete?: boolean } = {}) {
  const incoming = new EventEmitter() as any;
  incoming.statusCode = options.status ?? 200; incoming.complete = false; incoming.destroy = vi.fn();
  incoming.headers = { "content-type": "application/json", ...options.headers };
  incoming[Symbol.asyncIterator] = vi.fn(async function* () {
    yield options.bytes ?? Buffer.from(JSON.stringify(value)); incoming.complete = options.complete ?? true;
  });
  return incoming;
}
async function reply(client = createSiwcAccountHttps(), supplied = request(), incoming = response({ access_token: SECRET })) {
  const pending = client.request(supplied); network.calls.at(-1).reply(incoming);
  return { client, result: await pending, incoming };
}
beforeEach(() => { network.calls.length = 0; network.agents.length = 0; });
afterEach(() => vi.useRealTimers());

describe("fixed OAuth/discovery/JWKS HTTPS with inert network", () => {
  it("performs no construction I/O and exchanges only exact encoded public-client fields over pinned TLS", async () => {
    const client = createSiwcAccountHttps(); expect(network.calls).toHaveLength(0);
    const { result } = await reply(client);
    expect(result).toEqual({ status: 200, body: { access_token: SECRET } });
    const call = network.calls[0];
    expect(call.options).toEqual({ protocol: "https:", hostname: "auth.openai.com", port: 443, path: "/api/accounts/oauth/token",
      method: "POST", agent: network.agents[0], rejectUnauthorized: true, servername: "auth.openai.com", checkServerIdentity,
      ca: [...rootCertificates], maxHeaderSize: 16384, headers: { accept: "application/json", "accept-encoding": "identity",
        "content-type": "application/x-www-form-urlencoded", "content-length": String(Buffer.byteLength(new URLSearchParams(form()).toString())) } });
    expect(call.request.end).toHaveBeenCalledExactlyOnceWith(new URLSearchParams(form()).toString());
    expect(network.agents[0].options).toMatchObject({ proxyEnv: {}, keepAlive: false, maxCachedSessions: 0,
      ca: [...rootCertificates], rejectUnauthorized: true, checkServerIdentity });
    expect(network.agents[0].destroy).toHaveBeenCalledOnce();
  });

  it("refuses arbitrary routes, private clients, altered callback/resource and refresh scope overrides before I/O", async () => {
    const client = createSiwcAccountHttps();
    const variants = [request({ url: "https://evil.example/token" }), request({ url: `${SIWC_TOKEN_URL}?extra=1` }),
      request({ form: { ...form(), client_id: "dynamic_agent_client" } }), request({ form: { ...form(), client_secret: SECRET } }),
      request({ form: { ...form(), redirect_uri: "http://localhost:54000/auth/callback" } }),
      request({ form: { ...form(), redirect_uri: "http://127.0.0.1:54000/auth/callback#fragment" } }),
      request({ form: { ...form(), resource: "https://evil.example" } }), request({ form: { ...form(), code_verifier: "short" } }),
      request({ form: { grant_type: "refresh_token", client_id: "oaiapp_fixture", refresh_token: SECRET, resource: SIWC_RESOURCE, scope: "openid" } }),
      request({ url: SIWC_DISCOVERY_URL, method: "GET", form: {} }), request({ url: SIWC_JWKS_URL, method: "GET", form: undefined })];
    for (const value of variants) await expect(client.request(value)).rejects.toThrow("SIWC account unsupported");
    expect(network.calls).toHaveLength(0);
    const refreshed = await reply(client, request({ form: { grant_type: "refresh_token", client_id: "oaiapp_fixture", refresh_token: SECRET, resource: SIWC_RESOURCE } }));
    expect(refreshed.result.status).toBe(200); expect(network.calls).toHaveLength(1);
  });

  it("requires validated same-client discovery before sending a revocation token", async () => {
    const client = createSiwcAccountHttps(), revokeRequest = request({ url: revoke, form: {
      client_id: "oaiapp_fixture", token: SECRET, token_type_hint: "refresh_token" } });
    await expect(client.request(revokeRequest)).rejects.toThrow("unsupported");
    const discovery = request({ url: SIWC_DISCOVERY_URL, method: "GET", form: undefined });
    for (const value of [{ issuer: "https://evil.example", jwks_uri: SIWC_JWKS_URL, revocation_endpoint: revoke },
      { issuer: SIWC_ISSUER, jwks_uri: SIWC_JWKS_URL, revocation_endpoint: "https://evil.example/revoke" },
      { issuer: SIWC_ISSUER, jwks_uri: SIWC_JWKS_URL, revocation_endpoint: SIWC_TOKEN_URL }]) {
      await reply(client, discovery, response(value)); await expect(client.request(revokeRequest)).rejects.toThrow("unsupported");
    }
    await reply(client, discovery, response({ issuer: SIWC_ISSUER, jwks_uri: SIWC_JWKS_URL, revocation_endpoint: revoke, unrelated: SECRET }));
    const empty = response(null, { bytes: Buffer.alloc(0), headers: { "content-type": undefined } });
    expect((await reply(client, revokeRequest, empty)).result).toEqual({ status: 200, body: "" });
    expect(network.calls.at(-1).options.path).toBe("/api/accounts/oauth/revoke");
  });

  it("fetches JWKS only through the dedicated no-credential fixed GET", async () => {
    const client = createSiwcAccountHttps(), incoming = response({ keys: [] });
    const pending = client.fetchJwks(new AbortController().signal); network.calls.at(-1).reply(incoming);
    expect(await pending).toEqual({ status: 200, body: { keys: [] } });
    expect(network.calls[0].options).toMatchObject({ hostname: "auth.openai.com", method: "GET", path: "/.well-known/jwks.json",
      headers: { accept: "application/json", "accept-encoding": "identity" } });
    expect(Object.keys(network.calls[0].options.headers)).toEqual(["accept", "accept-encoding"]);
  });

  it("retains only OAuth error codes, discards redirects unread and does not replay", async () => {
    const client = createSiwcAccountHttps();
    expect((await reply(client, request(), response({ error: "invalid_grant", error_description: SECRET, arbitrary: SECRET }, { status: 400 }))).result)
      .toEqual({ status: 400, body: { error: "invalid_grant" } });
    const incoming = response({ error: SECRET }, { status: 302, headers: { location: "https://evil.example" } });
    expect((await reply(client, request(), incoming)).result).toEqual({ status: 302, body: undefined });
    expect(incoming[Symbol.asyncIterator]).not.toHaveBeenCalled(); expect(network.calls).toHaveLength(2);
  });

  it("refuses compressed, oversized, malformed and truncated bodies without raw errors", async () => {
    const client = createSiwcAccountHttps();
    for (const incoming of [response({}, { headers: { "content-encoding": "gzip" } }),
      response({}, { headers: { "content-length": "1048577" } }), response({}, { bytes: new Uint8Array(1048577) }),
      response({}, { bytes: Buffer.from(SECRET) }), response({}, { bytes: Buffer.from([255]) }), response({}, { complete: false })]) {
      const pending = client.request(request()), rejected = expect(pending).rejects.toThrow("SIWC account unknown");
      network.calls.at(-1).reply(incoming); await rejected; expect(incoming.destroy).toHaveBeenCalledOnce();
    }
    const pending = client.request(request()), rejected = expect(pending).rejects.toThrow("SIWC account unknown");
    network.calls.at(-1).request.emit("error", new Error(SECRET)); await rejected;
    expect(network.agents.every(agent => agent.destroy.mock.calls.length === 1)).toBe(true);
  });

  it("bounds pending concurrency, cancellation and absolute deadlines", async () => {
    vi.useFakeTimers(); const client = createSiwcAccountHttps(), controllers: AbortController[] = [], pending: Promise<unknown>[] = [];
    for (let i = 0; i < 8; i++) {
      const controller = new AbortController(); controllers.push(controller);
      pending.push(client.request(request({ signal: controller.signal })).catch(error => error));
    }
    await expect(client.request(request())).rejects.toThrow("unknown"); expect(network.calls).toHaveLength(8);
    controllers[0].abort(); await reply(client);
    await vi.advanceTimersByTimeAsync(30_000); await Promise.all(pending);
    expect(network.calls).toHaveLength(9); expect(network.agents.every(agent => agent.destroy.mock.calls.length === 1)).toBe(true);
    const aborted = new AbortController(); aborted.abort();
    await expect(client.request(request({ signal: aborted.signal }))).rejects.toThrow("unknown"); expect(network.calls).toHaveLength(9);
  });
});
