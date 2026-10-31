import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import type { AddressInfo } from "node:net";
import { after, before, describe, test } from "node:test";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { clientIp, createHttpServer, defaults, optionsFromEnv, rateLimiter, type HttpOptions } from "../src/http.ts";
import { callEveryTool, toolNames } from "./calls.ts";

const rpc = (id: number, method: string, params: object = {}) => JSON.stringify({ jsonrpc: "2.0", id, method, params });
const mcpHeaders = { "Content-Type": "application/json", Accept: "application/json, text/event-stream", "Mcp-Protocol-Version": "2025-06-18" };

async function listen(options: Partial<HttpOptions>) {
  const server = createHttpServer({ ...defaults, port: 0, ...options });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return { url, close: () => new Promise<void>((resolve) => server.close(() => resolve())) };
}

describe("http behind a proxy at /yorozu", () => {
  const limit = 20;
  let url: string;
  let close: () => Promise<void>;
  before(async () => ({ url, close } = await listen({ basePath: "/yorozu", trustProxy: 1, rateLimit: limit })));
  after(() => close());

  const post = (path: string, ip: string, body = rpc(1, "tools/list"), headers: Record<string, string> = {}) =>
    fetch(`${url}${path}`, { method: "POST", headers: { ...mcpHeaders, "X-Forwarded-For": ip, ...headers }, body });

  test("SDK client: every tool and a resource", async () => {
    const client = new Client({ name: "test", version: "0" });
    // Its own client IP, so these calls don't use up another test's rate-limit window.
    const transport = new StreamableHTTPClientTransport(new URL(`${url}/yorozu/mcp`), { requestInit: { headers: { "X-Forwarded-For": "192.0.2.10" } } });
    await client.connect(transport);
    assert.deepEqual((await client.listTools()).tools.map((t) => t.name).sort(), toolNames);
    await callEveryTool(client);
    const { contents } = await client.readResource({ uri: "yorozu://docs/readme" });
    assert.match((contents[0] as { text: string }).text, /Yorozu/);
    await client.close();
  });

  test("healthz under the base path", async () => {
    const res = await fetch(`${url}/yorozu/healthz`, { headers: { "X-Forwarded-For": "192.0.2.11" } });
    assert.equal(res.status, 200);
    assert.equal(((await res.json()) as { status: string }).status, "ok");
    assert.equal((await fetch(`${url}/healthz`)).status, 404);
    assert.equal((await fetch(`${url}/yorozu/healthz`, { method: "POST" })).status, 405);
  });

  test("MCP answers at the base path, base/ and base/mcp only", async () => {
    for (const path of ["/yorozu", "/yorozu/", "/yorozu/mcp"]) {
      const res = await post(path, "192.0.2.12");
      assert.equal(res.status, 200, path);
      assert.ok(((await res.json()) as { result: { tools: unknown[] } }).result.tools.length, path);
    }
    assert.equal((await post("/mcp", "192.0.2.12")).status, 404);
  });

  test("429 with Retry-After past the per-IP limit; other IPs unaffected", async () => {
    for (let i = 0; i < limit; i++) assert.equal((await post("/yorozu/mcp", "198.51.100.7")).status, 200);
    const limited = await post("/yorozu/mcp", "198.51.100.7");
    assert.equal(limited.status, 429);
    const wait = Number(limited.headers.get("retry-after"));
    assert.ok(wait >= 1 && wait <= 60, `Retry-After ${wait}`);
    assert.equal(((await limited.json()) as { error: { message: string } }).error.message, "Too many requests");
    // The proxy appends the real client last; a spoofed left-hand entry does not change the key.
    assert.equal((await post("/yorozu/mcp", "203.0.113.1, 198.51.100.7")).status, 429);
    assert.equal((await post("/yorozu/mcp", "198.51.100.8")).status, 200);
    assert.equal((await fetch(`${url}/yorozu/healthz`, { headers: { "X-Forwarded-For": "198.51.100.7" } })).status, 200);
  });

  test("CORS preflight and response headers", async () => {
    const pre = await fetch(`${url}/yorozu/mcp`, {
      method: "OPTIONS",
      headers: { Origin: "https://app.example", "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type, mcp-protocol-version" },
    });
    assert.equal(pre.status, 204);
    assert.equal(pre.headers.get("access-control-allow-origin"), "*");
    assert.match(pre.headers.get("access-control-allow-methods") ?? "", /POST/);
    assert.match(pre.headers.get("access-control-allow-headers") ?? "", /Mcp-Protocol-Version/);
    const res = await post("/yorozu/mcp", "192.0.2.13", rpc(1, "tools/list"), { Origin: "https://app.example" });
    assert.equal(res.headers.get("access-control-allow-origin"), "*");
    assert.match(res.headers.get("access-control-expose-headers") ?? "", /Mcp-Session-Id/);
  });

  test("rejects GET streams, oversized and malformed bodies", async () => {
    assert.equal((await fetch(`${url}/yorozu/mcp`, { headers: { "X-Forwarded-For": "192.0.2.14" } })).status, 405);
    assert.equal((await post("/yorozu/mcp", "192.0.2.14", "x".repeat(70 * 1024))).status, 413);
    assert.equal((await post("/yorozu/mcp", "192.0.2.14", "{not json")).status, 400);
  });
});

test("CORS with an origin allow-list", async () => {
  const { url, close } = await listen({ corsOrigins: ["https://ok.example"] });
  const ok = await fetch(`${url}/healthz`, { headers: { Origin: "https://ok.example" } });
  assert.equal(ok.headers.get("access-control-allow-origin"), "https://ok.example");
  assert.equal(ok.headers.get("vary"), "Origin");
  const other = await fetch(`${url}/healthz`, { headers: { Origin: "https://other.example" } });
  assert.equal(other.headers.get("access-control-allow-origin"), null);
  await close();
});

test("without TRUST_PROXY, X-Forwarded-For is ignored", () => {
  const req = { socket: { remoteAddress: "10.0.0.2" }, headers: { "x-forwarded-for": "203.0.113.5, 10.0.0.1" } } as never;
  assert.equal(clientIp(req, 0), "10.0.0.2");
  assert.equal(clientIp(req, 1), "10.0.0.1");
  assert.equal(clientIp(req, 2), "203.0.113.5");
  assert.equal(clientIp(req, 5), "203.0.113.5");
});

test("rate limiter window resets", () => {
  let now = 0;
  const limited = rateLimiter(2, 1000, () => now);
  assert.deepEqual([limited("a"), limited("a"), limited("a")], [0, 0, 1]);
  now = 1000;
  assert.equal(limited("a"), 0);
});

test("optionsFromEnv: defaults, overrides and bad values", () => {
  assert.deepEqual(optionsFromEnv({}), defaults);
  const o = optionsFromEnv({ PORT: "9000", HOST: "0.0.0.0", BASE_PATH: "/yorozu/", TRUST_PROXY: "1", RATE_LIMIT: "10", RATE_LIMIT_WINDOW_MS: "1000", CORS_ORIGINS: "https://a.example, https://b.example" });
  assert.deepEqual([o.port, o.host, o.basePath, o.trustProxy, o.rateLimit, o.rateWindowMs], [9000, "0.0.0.0", "/yorozu", 1, 10, 1000]);
  assert.deepEqual(o.corsOrigins, ["https://a.example", "https://b.example"]);
  assert.throws(() => optionsFromEnv({ PORT: "http" }), /PORT/);
  assert.throws(() => optionsFromEnv({ BASE_PATH: "yorozu" }), /BASE_PATH/);
  assert.throws(() => optionsFromEnv({ RATE_LIMIT: "0" }), /RATE_LIMIT/);
});

test("`node src/http.ts` starts from the environment", async () => {
  const child = spawn(process.execPath, ["src/http.ts"], {
    cwd: fileURLToPath(new URL("..", import.meta.url)),
    env: { ...process.env, PORT: "0", HOST: "127.0.0.1", BASE_PATH: "/yorozu" },
  });
  try {
    const line = await new Promise<string>((resolve, reject) => {
      let err = "";
      child.stderr.on("data", (d) => {
        err += d;
        if (err.includes("\n")) resolve(err);
      });
      child.on("exit", (code) => reject(new Error(`exited ${code}: ${err}`)));
    });
    const port = /127\.0\.0\.1:(\d+)\/yorozu\/mcp/.exec(line)?.[1];
    assert.ok(port, line);
    assert.equal((await fetch(`http://127.0.0.1:${port}/yorozu/healthz`)).status, 200);
  } finally {
    child.kill("SIGTERM");
  }
  const bad = spawn(process.execPath, ["src/http.ts"], { cwd: fileURLToPath(new URL("..", import.meta.url)), env: { ...process.env, PORT: "nope" } });
  assert.equal(await new Promise((resolve) => bad.on("exit", resolve)), 64);
});
