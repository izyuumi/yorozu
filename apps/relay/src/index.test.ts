import { afterAll, afterEach, beforeAll, expect, test, vi } from "vitest";
import WebSocket from "ws";
import { roomId, signChallenge, startRelay, type Relay } from "./index.js";
import { client, connectMac, connectPhone, keypair, mintToken, type Client } from "./testing.js";
import { conformance, type Adapter } from "./conformance.test.js";

/**
 * The Node relay against the shared conformance suite. Everything on the wire is covered
 * there; only what is Node's alone lives here.
 */

let relay: Relay;
const peers: Client[] = [];
const servers: Relay[] = [];
beforeAll(async () => {
  relay = await startRelay(0);
});
afterAll(async () => {
  vi.useRealTimers();
  await relay.close();
});
afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => server.close()));
  await Promise.all(peers.splice(0).map(async (peer) => {
    peer.ws.terminate();
    await peer.closed;
  }));
  vi.useRealTimers();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

const adapter: Adapter = {
  keypair: async () => {
    const keys = keypair();
    return { pub: keys.pub, sign: async (data) => signChallenge(data, keys.priv) };
  },
  roomId: async (pub) => roomId(pub),
  connect: async (room) => {
    const peer = client(relay.port, room);
    peers.push(peer);
    await peer.open;
    return {
      send: peer.send,
      raw: (text) => peer.ws.send(text),
      close: (code, reason) => peer.ws.close(code, reason),
      next: peer.next,
      closed: () => peer.closed,
    };
  },
  // The relay reads `Date.now()` in-process, so moving the clock is enough. Only `Date` is
  // faked: `ws` keeps its real timers.
  advance: async (_room, ms) => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(Date.now() + ms);
  },
};

conformance(adapter);

test("room id is base64url sha256 of the raw public key", () => {
  const { pub } = keypair();
  expect(roomId(pub)).toMatch(/^[\w-]{43}$/);
  expect(roomId(pub)).toBe(roomId(pub));
  expect(roomId(pub)).not.toBe(roomId(keypair().pub));
});

test("a key may only register in its own room", async () => {
  const keys = keypair();
  const squatter = client(relay.port, roomId(keypair().pub));
  peers.push(squatter);
  await squatter.open;
  const { nonce } = await squatter.next();
  squatter.send({ type: "register", pubkey: keys.pub, nonceSig: signChallenge(nonce, keys.priv) });
  // Derived from the key, so the `?room=` it dialed is ignored and it lands in its own room.
  expect(await squatter.next()).toMatchObject({ type: "registered", roomId: roomId(keys.pub) });
});

test("mint consumes the same per-socket bucket as registration", async () => {
  vi.useFakeTimers({ toFake: ["Date"] });
  const mac = await connectMac(relay.port, keypair());
  peers.push(mac);
  for (let i = 0; i < 60; i++) mac.send({ type: "mint" });
  for (let i = 0; i < 59; i++) expect(await mac.next()).toMatchObject({ type: "token" });
  expect(await Promise.race([mac.next(), mac.closed])).toBe(4029);
});

test("the payload cap accepts one MiB and rejects fragmented UTF-8 bytes above it", async () => {
  const peer = client(relay.port);
  peers.push(peer);
  await peer.open;
  await peer.next();
  peer.ws.send(JSON.stringify({ type: "ping" }).padEnd(1_048_576));
  expect(await peer.next()).toEqual({ type: "pong" });
  const oversized = JSON.stringify({ type: "ping", padding: "é".repeat(524_288) });
  peer.ws.send(oversized.slice(0, 300_000), { fin: false });
  peer.ws.send(oversized.slice(300_000), { fin: true });
  expect(await Promise.race([peer.next(), peer.closed])).toBe(1009);
});

async function limitedRelay(): Promise<Relay> {
  const server = await startRelay(0);
  servers.push(server);
  return server;
}

function dial(port: number, forwarded?: string) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`, {
    headers: forwarded === undefined ? {} : { "X-Forwarded-For": forwarded },
  });
  const closed = new Promise<number>((resolve) => ws.once("close", resolve));
  const first = Promise.race([
    closed,
    new Promise<unknown>((resolve) => ws.once("message", (data) => resolve(JSON.parse(data.toString())))),
  ]);
  return { ws, closed, first };
}

test("the default per-IP cap rejects socket 33 and releases a disconnected slot", async () => {
  vi.stubEnv("RELAY_MAX_CONNS_PER_IP", "");
  vi.stubEnv("RELAY_TRUST_PROXY", "");
  const server = await limitedRelay();
  const allowed = [];
  for (let i = 0; i < 32; i++) {
    const peer = dial(server.port);
    expect(await peer.first).toMatchObject({ type: "nonce" });
    allowed.push(peer);
  }
  expect(await dial(server.port).first).toBe(1008);
  allowed[0]!.ws.close();
  await allowed[0]!.closed;
  expect(await dial(server.port).first).toMatchObject({ type: "nonce" });
});

test.each([false, true])("forwarded IPs are trusted only with RELAY_TRUST_PROXY (trusted: %s)", async (trusted) => {
  vi.stubEnv("RELAY_MAX_CONNS_PER_IP", "1");
  vi.stubEnv("RELAY_TRUST_PROXY", trusted ? "1" : "");
  const server = await limitedRelay();
  expect(await dial(server.port, "192.0.2.1, 192.0.2.10").first).toMatchObject({ type: "nonce" });
  const other = await dial(server.port, "192.0.2.2, 192.0.2.10").first;
  if (trusted) expect(other).toMatchObject({ type: "nonce" });
  else expect(other).toBe(1008);
  // The proxy chain after the first address cannot buy another slot.
  expect(await dial(server.port, "192.0.2.1, 192.0.2.99").first).toBe(1008);
});

test.each([undefined, "2"])("token cap evicts the oldest mint, including tied timestamps (cap: %s)", async (configured) => {
  vi.stubEnv("RELAY_MAX_TOKENS_PER_ROOM", configured);
  vi.useFakeTimers({ toFake: ["Date"] });
  const server = await limitedRelay();
  const keys = keypair();
  const mac = await connectMac(server.port, keys);
  const tokens = [];
  const cap = configured === undefined ? 8 : 2;
  for (let i = 0; i <= cap; i++) tokens.push(await mintToken(mac));
  const oldest = await connectPhone(server.port, roomId(keys.pub), tokens[0]!);
  expect(await Promise.race([oldest.phone.next(), oldest.phone.closed])).toBe(4001);
  for (const token of tokens.slice(1)) {
    const { phone } = await connectPhone(server.port, roomId(keys.pub), token);
    expect(await phone.next()).toMatchObject({ type: "joined" });
  }
});

test("a periodic sweep releases an idle room after its last token expires", async () => {
  vi.useFakeTimers({ toFake: ["Date", "setInterval", "clearInterval"] });
  const logs = vi.spyOn(console, "log");
  const server = await limitedRelay();
  const mac = await connectMac(server.port, keypair());
  await mintToken(mac);
  mac.ws.close();
  await mac.closed;
  await vi.waitFor(() => expect(logs.mock.calls.some(([line]) => JSON.parse(line).ev === "close")).toBe(true));
  await vi.advanceTimersByTimeAsync(10 * 60_000);
  expect(logs.mock.calls.some(([line]) => JSON.parse(line).ev === "room-drop")).toBe(false);
  await vi.advanceTimersByTimeAsync(60_000);
  expect(logs.mock.calls.filter(([line]) => JSON.parse(line).ev === "room-drop")).toHaveLength(1);
});

test("switching rooms on one socket cannot leave an unreachable room behind", async () => {
  const peer = client(relay.port);
  peers.push(peer);
  await peer.open;
  const { nonce } = await peer.next();
  const first = keypair();
  peer.send({ type: "register", pubkey: first.pub, nonceSig: signChallenge(nonce, first.priv) });
  expect(await peer.next()).toMatchObject({ type: "registered" });
  const second = keypair();
  peer.send({ type: "register", pubkey: second.pub, nonceSig: signChallenge(nonce, second.priv) });
  expect(await Promise.race([peer.next(), peer.closed])).toBe(4001);
});

test("notify throttling is per room, survives reconnect, and resets after a minute", async () => {
  vi.stubEnv("RELAY_NOTIFY_PER_MINUTE", "2");
  vi.useFakeTimers({ toFake: ["Date"] });
  const server = await limitedRelay();
  const keys = keypair();
  const mac = await connectMac(server.port, keys);
  const { phone } = await connectPhone(server.port, roomId(keys.pub), await mintToken(mac));
  await phone.next();
  const notify = { type: "notify", class: "reply", threadRef: "opaque" };
  mac.send(notify);
  mac.send(notify);
  mac.send({ type: "ping" });
  expect(await mac.next()).toEqual({ type: "pong" });
  const replacement = await connectMac(server.port, keys);
  replacement.send(notify);
  replacement.send({ type: "ping" });
  expect(await replacement.next()).toEqual({ type: "state", state: "notify rate limit" });
  expect(await replacement.next()).toEqual({ type: "pong" });
  const otherRoom = await connectMac(server.port, keypair());
  otherRoom.send(notify);
  otherRoom.send({ type: "ping" });
  expect(await otherRoom.next()).toEqual({ type: "pong" });
  vi.setSystemTime(Date.now() + 60_000);
  replacement.send(notify);
  replacement.send({ type: "ping" });
  expect(await replacement.next()).toEqual({ type: "pong" });
});
