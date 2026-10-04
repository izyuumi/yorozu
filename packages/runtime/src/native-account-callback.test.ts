import { beforeEach, describe, expect, it, vi } from "vitest";
const fake = vi.hoisted(() => ({ requests: [] as any[], options: [] as any[], listenOptions: [] as any[], closes: 0,
  address: { address: "127.0.0.1", port: 54321 }, handler: undefined as any }));
vi.mock("node:http", () => ({ createServer: vi.fn((options, handler) => {
  fake.options.push(options); fake.handler = handler;
  const server = { maxConnections: 0, on: vi.fn(() => server), once: vi.fn(() => server), removeListener: vi.fn(() => server),
    listen: vi.fn((options, ready) => { fake.listenOptions.push(options); ready(); }), address: () => fake.address,
    close: vi.fn((done) => { fake.closes++; done(); }), closeAllConnections: vi.fn() };
  return server;
}) }));
import { createServer } from "node:http";
import { createNumericSiwcCallbackEndpointFactory } from "./native-account-callback.js";

beforeEach(() => { vi.clearAllMocks(); fake.requests = []; fake.options = []; fake.listenOptions = []; fake.closes = 0; fake.address = { address: "127.0.0.1", port: 54321 }; });
describe("numeric callback endpoint using a mocked HTTP server; no sockets", () => {
  it("constructs inertly and binds only explicitly acquired numeric ephemeral loopback", async () => {
    const factory = createNumericSiwcCallbackEndpointFactory(); expect(createServer).not.toHaveBeenCalled();
    const controller = new AbortController(), endpoint = await factory.acquire(async () => ({ status: 200, text: "Return to Yorozu." }), controller.signal);
    expect(fake.listenOptions).toEqual([{ host: "127.0.0.1", port: 0, exclusive: true, signal: controller.signal }]);
    expect(fake.options[0]).toMatchObject({ maxHeaderSize: 24576, headersTimeout: 5000, requestTimeout: 5000 });
    expect(endpoint).toMatchObject({ host: "127.0.0.1", port: 54321 }); await endpoint.close(); await endpoint.close(); expect(fake.closes).toBe(1);
  });
  it("refuses already-aborted acquisition before server creation and rejects a widened reported bind", async () => {
    const factory = createNumericSiwcCallbackEndpointFactory(), controller = new AbortController(); controller.abort();
    await expect(factory.acquire(async () => ({ status: 200, text: "Return" }), controller.signal)).rejects.toThrow("unavailable"); expect(createServer).not.toHaveBeenCalled();
    fake.address = { address: "0.0.0.0", port: 54321 };
    await expect(factory.acquire(async () => ({ status: 200, text: "Return" }), new AbortController().signal)).rejects.toThrow("unavailable"); expect(fake.closes).toBe(1);
  });
  it("never consumes request bodies and returns no callback URL or raw failure text", async () => {
    const handler = vi.fn(async () => { throw new Error("synthetic-secret-query-token"); });
    const endpoint = await createNumericSiwcCallbackEndpointFactory().acquire(handler, new AbortController().signal);
    const response = { destroyed: false, writeHead: vi.fn(), end: vi.fn() }, request = { method: "GET", url: "/auth/callback?code=synthetic-secret-query-token",
      headers: { host: "127.0.0.1:54321", "content-length": "1" }, socket: { remoteAddress: "127.0.0.1" }, rawHeaders: ["Host", "127.0.0.1:54321"], on: vi.fn() };
    fake.handler(request, response); await new Promise(resolve => setImmediate(resolve));
    expect(handler).toHaveBeenCalledWith(expect.objectContaining({ hasBody: true, remoteAddress: "127.0.0.1" })); expect(request.on).not.toHaveBeenCalled();
    expect(response.writeHead).toHaveBeenCalledWith(400, expect.objectContaining({ "cache-control": "no-store", "referrer-policy": "no-referrer", connection: "close" }));
    expect(JSON.stringify(response.end.mock.calls)).not.toContain("synthetic-secret-query-token"); await endpoint.close();
  });
});
