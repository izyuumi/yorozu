import { afterAll, afterEach, beforeAll, expect, test, vi } from "vitest";
import WebSocket from "ws";
import { AUTH_TIMEOUT_MS, CLOSE_POLICY, ROOM_ID } from "./protocol.js";
import { clientIp, roomId, signChallenge, startRelay, trustedHops, type Relay } from "./index.js";
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
  expect(roomId(pub)).toMatch(ROOM_ID);
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

test("a stalled phone is disconnected without slowing another phone or the host", async () => {
  const logs = vi.spyOn(console, "log");
  const keys = keypair();
  const mac = await connectMac(relay.port, keys);
  peers.push(mac);
  const room = roomId(keys.pub);
  const slow = await connectPhone(relay.port, room, await mintToken(mac));
  peers.push(slow.phone);
  await slow.phone.next(); // joined
  const fast = await connectPhone(relay.port, room, await mintToken(mac));
  peers.push(fast.phone);
  await fast.phone.next(); // joined
  const socket = (slow.phone.ws as WebSocket & { _socket: { pause(): void; resume(): void } })._socket;
  socket.pause();
  try {
    const payload = "A".repeat(140_000);
    const frames = Array.from({ length: 6 }, () => ({ payload, sig: signChallenge(payload, keys.priv) }));
    for (let i = 0; i < 8; i++) {
      mac.send({ type: "frame", frames });
      for (let j = 0; j < frames.length; j++)
        expect(await fast.phone.next()).toMatchObject({ type: "frame", payload });
    }
    await vi.waitFor(() => expect(logs.mock.calls.some(([line]) => JSON.parse(line).ev === "slow-phone")).toBe(true));
  } finally {
    socket.resume();
  }
  expect(await slow.phone.closed).toBe(1013);
  mac.frame("bWFya2Vy", keys);
  expect(await fast.phone.next()).toMatchObject({ type: "frame", payload: "bWFya2Vy" });
});

async function limitedRelay(): Promise<Relay> {
  const server = await startRelay(0);
  servers.push(server);
  return server;
}

function dial(port: number, forwarded?: string, headers: Record<string, string> = {}) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`, {
    headers: forwarded === undefined ? headers : { ...headers, "X-Forwarded-For": forwarded },
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
  // One trusted hop: the last entry is what the proxy saw, the rest is the client's story.
  expect(await dial(server.port, "192.0.2.1, 192.0.2.10").first).toMatchObject({ type: "nonce" });
  const other = await dial(server.port, "192.0.2.2, 192.0.2.11").first;
  if (trusted) expect(other).toMatchObject({ type: "nonce" });
  else expect(other).toBe(CLOSE_POLICY);
  // A different first entry behind the same last hop is the same client, so no second slot.
  expect(await dial(server.port, "192.0.2.99, 192.0.2.10").first).toBe(CLOSE_POLICY);
});

test("a client cannot prepend to X-Forwarded-For to dodge the cap or fill a victim's", async () => {
  vi.stubEnv("RELAY_MAX_CONNS_PER_IP", "1");
  vi.stubEnv("RELAY_TRUST_PROXY", "1");
  const server = await limitedRelay();
  const victim = "203.0.113.7";
  const attacker = "198.51.100.9";
  // Whatever the attacker writes in front, the trusted hop appended its real address last.
  expect(await dial(server.port, `${victim}, ${attacker}`).first).toMatchObject({ type: "nonce" });
  expect(await dial(server.port, `10.0.0.1, ${victim}, ${attacker}`).first).toBe(CLOSE_POLICY);
  // The victim's own slot is untouched by any of that.
  expect(await dial(server.port, `${attacker}, ${victim}`).first).toMatchObject({ type: "nonce" });
});

test("RELAY_TRUST_PROXY=N reads the Nth entry from the end, and a short chain is not trusted", async () => {
  vi.stubEnv("RELAY_MAX_CONNS_PER_IP", "1");
  vi.stubEnv("RELAY_TRUST_PROXY", "2");
  const server = await limitedRelay();
  // Two trusted hops: the second-from-last entry is the client, the last is the inner proxy.
  expect(await dial(server.port, "192.0.2.1, 192.0.2.50, 192.0.2.60").first).toMatchObject({ type: "nonce" });
  expect(await dial(server.port, "192.0.2.2, 192.0.2.50, 192.0.2.60").first).toBe(CLOSE_POLICY);
  expect(await dial(server.port, "192.0.2.3, 192.0.2.51, 192.0.2.60").first).toMatchObject({ type: "nonce" });
  // Fewer entries than hops: something upstream is misconfigured, so the peer address counts.
  expect(await dial(server.port, "192.0.2.4").first).toMatchObject({ type: "nonce" });
  expect(await dial(server.port, "192.0.2.5").first).toBe(CLOSE_POLICY);
});

test("CF-Connecting-IP is honoured over X-Forwarded-For when a proxy is trusted", async () => {
  vi.stubEnv("RELAY_MAX_CONNS_PER_IP", "1");
  vi.stubEnv("RELAY_TRUST_PROXY", "1");
  const server = await limitedRelay();
  const cf = { "CF-Connecting-IP": "192.0.2.77" };
  expect(await dial(server.port, "192.0.2.1", cf).first).toMatchObject({ type: "nonce" });
  expect(await dial(server.port, "192.0.2.2", cf).first).toBe(CLOSE_POLICY);
  expect(await dial(server.port, undefined, { "CF-Connecting-IP": "192.0.2.78" }).first).toMatchObject({ type: "nonce" });
});

test("trusted hop parsing and client address selection", () => {
  expect(trustedHops(undefined)).toBe(0);
  expect(trustedHops("")).toBe(0);
  expect(trustedHops("1")).toBe(1);
  expect(trustedHops("3")).toBe(3);
  expect(trustedHops("true")).toBe(1);
  expect(trustedHops("0")).toBe(1);
  expect(trustedHops("-2")).toBe(1);
  const peer = "127.0.0.1";
  expect(clientIp({ "x-forwarded-for": "1.1.1.1, 2.2.2.2" }, peer, 0)).toBe(peer);
  expect(clientIp({ "x-forwarded-for": "1.1.1.1, 2.2.2.2" }, peer, 1)).toBe("2.2.2.2");
  expect(clientIp({ "x-forwarded-for": "1.1.1.1, 2.2.2.2" }, peer, 2)).toBe("1.1.1.1");
  expect(clientIp({ "x-forwarded-for": "1.1.1.1, 2.2.2.2" }, peer, 3)).toBe(peer);
  expect(clientIp({ "x-forwarded-for": "1.1.1.1, not-an-ip" }, peer, 1)).toBe(peer);
  expect(clientIp({ "x-forwarded-for": ["1.1.1.1", "2.2.2.2"] }, peer, 1)).toBe("2.2.2.2");
  expect(clientIp({ "cf-connecting-ip": "3.3.3.3", "x-forwarded-for": "1.1.1.1" }, peer, 1)).toBe("3.3.3.3");
  expect(clientIp({ "cf-connecting-ip": "3.3.3.3" }, peer, 0)).toBe(peer);
  expect(clientIp({}, undefined, 1)).toBe("unknown");
});

test("a socket that never registers or joins is closed at the auth deadline", async () => {
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  const server = await limitedRelay();
  const stranger = dial(server.port);
  expect(await stranger.first).toMatchObject({ type: "nonce" });
  const keys = keypair();
  const mac = await connectMac(server.port, keys);
  await vi.advanceTimersByTimeAsync(AUTH_TIMEOUT_MS);
  expect(await stranger.closed).toBe(CLOSE_POLICY);
  // The one that answered in time is still there.
  mac.send({ type: "ping" });
  expect(await mac.next()).toEqual({ type: "pong" });
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
