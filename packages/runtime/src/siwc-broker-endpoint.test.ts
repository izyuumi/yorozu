/** Complete node:http replacement. These tests never bind a port. */
import { EventEmitter } from "node:events";
import { beforeEach, expect, test, vi } from "vitest";
const fake = vi.hoisted(() => ({ create: vi.fn(), servers: [] as any[], address: { address: "127.0.0.1", port: 54321 } as any }));
vi.mock("node:http", () => ({ createServer: fake.create }));
import { createNumericSiwcBrokerEndpoint } from "./siwc-broker-endpoint.js";
beforeEach(() => {
  fake.servers = []; fake.address = { address: "127.0.0.1", port: 54321 }; fake.create.mockReset();
  fake.create.mockImplementation((options, handler) => {
    const server = Object.assign(new EventEmitter(), { options, handler, maxConnections: 0, maxHeadersCount: 0,
      address: () => fake.address, listen: vi.fn((_address, ready) => ready()), closeAllConnections: vi.fn(), close: vi.fn(done => done()) });
    fake.servers.push(server); return server;
  });
});
test("factory is inert and dispatch opens exactly numeric exclusive ephemeral loopback", async () => {
  const open = createNumericSiwcBrokerEndpoint(); expect(fake.create).not.toHaveBeenCalled();
  const endpoint = await open(vi.fn(), { agentId: "alice", executionId: "a".repeat(64) }, new AbortController().signal);
  expect(fake.servers[0].listen).toHaveBeenCalledWith({ host: "127.0.0.1", port: 0, exclusive: true, signal: expect.any(AbortSignal) }, expect.any(Function));
  expect(endpoint).toMatchObject({ host: "127.0.0.1", port: 54321 });
  await endpoint.close(); await endpoint.close(); expect(fake.servers[0].close).toHaveBeenCalledOnce();
});

test("a late mocked bind after cancellation is closed again and never becomes an endpoint", async () => {
  let ready!: () => void;
  fake.create.mockImplementation((_options, handler) => {
    const server = Object.assign(new EventEmitter(), { handler, address: () => fake.address,
      listen: vi.fn((_options, callback) => { ready = callback; }), closeAllConnections: vi.fn(), close: vi.fn(done => done()) });
    fake.servers.push(server); return server;
  });
  const cancel = new AbortController(), pending = createNumericSiwcBrokerEndpoint()(vi.fn(), { agentId: "alice", executionId: "a".repeat(64) }, cancel.signal);
  cancel.abort(); await expect(pending).rejects.toThrow(); ready();
  expect(fake.servers[0].close).toHaveBeenCalledTimes(2);
});
test("aborted admission opens nothing; later cancellation closes active endpoint", async () => {
  const c = new AbortController(); c.abort();
  await expect(createNumericSiwcBrokerEndpoint()(vi.fn(), { agentId: "alice", executionId: "a".repeat(64) }, c.signal)).rejects.toThrow();
  expect(fake.create).not.toHaveBeenCalled();
  const live = new AbortController(), endpoint = await createNumericSiwcBrokerEndpoint()(vi.fn(), { agentId: "alice", executionId: "a".repeat(64) }, live.signal);
  live.abort(); await endpoint.close(); expect(fake.servers[0].closeAllConnections).toHaveBeenCalledOnce();
});
test("unusable addresses and duplicate headers fail closed without dispatch", async () => {
  fake.address = { address: "::1", port: 54321 };
  await expect(createNumericSiwcBrokerEndpoint()(vi.fn(), { agentId: "alice", executionId: "a".repeat(64) }, new AbortController().signal)).rejects.toThrow();
  expect(fake.servers[0].close).toHaveBeenCalledOnce(); fake.address = { address: "127.0.0.1", port: 54321 };
  const handler = vi.fn(), endpoint = await createNumericSiwcBrokerEndpoint()(handler, { agentId: "alice", executionId: "a".repeat(64) }, new AbortController().signal);
  const reply = { writeHead: vi.fn(), end: vi.fn() };
  fake.servers[1].handler({ rawHeaders: ["Host", "127.0.0.1:54321", "host", "other"] }, reply);
  expect(handler).not.toHaveBeenCalled(); expect(reply.writeHead).toHaveBeenCalledWith(400, expect.any(Object)); await endpoint.close();
});
