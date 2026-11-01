import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { EventEmitter } from "node:events";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { test } from "node:test";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  },
});
const { bindAddresses, directAddress, MAX_FRAME_BYTES, MAX_PENDING, probeAnswer, serveDirect, validNonce, verifyProbe } = await import(
  "../src/direct.ts"
);
const { CLOSE } = await import("../src/hub.ts");
const { b64u, ed25519Keypair, roomId } = await import("../src/wire.ts");

test("binds only loopback, RFC 1918, ULA and 100.64.0.0/10", () => {
  const allowed = [
    "127.0.0.1", "127.255.0.9", "10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.254", "192.168.1.20",
    "100.64.0.1", "100.127.255.254", "::1", "0:0:0:0:0:0:0:1", "fc00::1", "fd7a:115c:a1e0::53", "FD12:3456::1",
  ];
  const refused = [
    "0.0.0.0", "::", "0:0:0:0:0:0:0:0", "8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "192.169.0.1", "11.0.0.1",
    "100.63.255.255", "100.128.0.1", "169.254.1.1", "255.255.255.255", "fe80::1", "fe80::1%en0", "febf::1", "fe00::1",
    "2001:4860:4860::8888", "2606:4700::1111", "::2", "::ffff:10.0.0.1", "::ffff:a00:1", "64:ff9b::a00:1",
    "fd00::1%utun3", "localhost", "", "10.0.0", "not an address",
  ];
  for (const address of allowed) assert.equal(directAddress(address), true, address);
  for (const address of refused) assert.equal(directAddress(address), false, address);
});

test("bind addresses come from the interfaces, each once", () => {
  const info = (address: string, family: "IPv4" | "IPv6") => ({ address, family, netmask: "", mac: "", internal: false, cidr: null });
  const interfaces = {
    lo0: [info("127.0.0.1", "IPv4"), info("::1", "IPv6"), info("fe80::1", "IPv6")],
    en0: [info("192.168.1.20", "IPv4"), info("2001:db8::5", "IPv6"), info("fd00::5", "IPv6")],
    utun3: [info("100.101.102.103", "IPv4"), info("127.0.0.1", "IPv4")],
    en1: [info("203.0.113.9", "IPv4"), info("169.254.3.3", "IPv4")],
    gone: undefined,
  };
  assert.deepEqual(bindAddresses(interfaces), ["127.0.0.1", "::1", "192.168.1.20", "fd00::5", "100.101.102.103"]);
});

test("the probe proves the room's key over the nonce", () => {
  const signing = ed25519Keypair();
  const room = roomId(signing.publicKey);
  const nonce = b64u(randomBytes(32));
  const answer = probeAnswer(signing, room, nonce);
  assert.equal(verifyProbe(room, nonce, answer), true);
  assert.equal(verifyProbe(room, b64u(randomBytes(32)), answer), false, "another nonce");
  assert.equal(verifyProbe(roomId(ed25519Keypair().publicKey), nonce, answer), false, "another room");
  const stranger = ed25519Keypair();
  assert.equal(verifyProbe(room, nonce, probeAnswer(stranger, room, nonce)), false, "a key that is not the room's");
  assert.equal(verifyProbe(room, nonce, { ...answer, sig: probeAnswer(stranger, room, nonce).sig }), false, "a forged signature");
  assert.equal(verifyProbe(room, nonce, { type: "probe" }), false);
  assert.equal(validNonce(nonce), true);
  for (const bad of [b64u(randomBytes(31)), b64u(randomBytes(33)), "", "!".repeat(43), 7]) assert.equal(validNonce(bad), false);
});

class FakeSocket extends EventEmitter {
  readyState = 1;
  sent: string[] = [];
  closed?: number;
  send(data: string) {
    this.sent.push(data);
  }
  close(code?: number) {
    if (this.readyState !== 1) return;
    this.readyState = 3;
    this.closed = code;
    queueMicrotask(() => this.emit("close", code));
  }
  terminate() {
    this.close(1006);
  }
}

class FakeServer extends EventEmitter {
  closed = false;
  readonly options: { host: string; port: number; maxPayload: number };
  constructor(options: { host: string; port: number; maxPayload: number }) {
    super();
    this.options = options;
    queueMicrotask(() => (options.host === "10.9.9.9" ? this.emit("error", new Error("EADDRNOTAVAIL")) : this.emit("listening")));
  }
  close(callback?: () => void) {
    this.closed = true;
    callback?.();
  }
}

async function listener(addresses = ["127.0.0.1"], pendingMs?: number) {
  const signing = ed25519Keypair();
  const room = roomId(signing.publicKey);
  const servers: FakeServer[] = [];
  const hub = { handshake: async () => null, open: () => null, handle: async () => {}, detach: () => {} };
  const direct = await serveDirect({
    addresses,
    port: 8738,
    keys: { signing, room },
    hub,
    ...(pendingMs !== undefined && { pendingMs }),
    server: (options) => {
      const server = new FakeServer(options);
      servers.push(server);
      return server;
    },
  });
  const connect = (headers: Record<string, string> = {}) => {
    const ws = new FakeSocket();
    servers[0]!.emit("connection", ws, { headers });
    return ws;
  };
  return { direct, servers, connect, room };
}

const settle = () => new Promise((resolve) => setImmediate(resolve));

test("listens on each address that binds and reports whether any did", async () => {
  const { direct, servers } = await listener(["127.0.0.1", "10.9.9.9", "::1"]);
  assert.equal(direct.listening, true);
  assert.deepEqual(direct.bound, ["127.0.0.1", "::1"]);
  assert.deepEqual(servers.map((s) => s.options.port), [8738, 8738, 8738]);
  assert.ok(servers.every((s) => s.options.maxPayload > MAX_FRAME_BYTES));
  await direct.close();
  assert.equal(direct.listening, false);
  assert.equal((await listener(["10.9.9.9"])).direct.listening, false);
});

test("never binds a wildcard or public address, whatever the caller passes", async () => {
  const { direct, servers } = await listener(["0.0.0.0", "::", "8.8.8.8", "127.0.0.1"]);
  assert.deepEqual(servers.map((s) => s.options.host), ["127.0.0.1"]);
  assert.deepEqual(direct.bound, ["127.0.0.1"]);
  await direct.close();
});

test("anything but a probe first closes 4101; a probe is answered", async () => {
  const { connect, room } = await listener();
  const early = connect();
  early.emit("message", Buffer.from(JSON.stringify({ type: "frame", payload: "x", sig: "y" })), false);
  await settle();
  assert.equal(early.closed, CLOSE.unauthorized);

  const ws = connect();
  const nonce = b64u(randomBytes(32));
  ws.emit("message", Buffer.from(JSON.stringify({ type: "probe", nonce })), false);
  await settle();
  const answer = JSON.parse(ws.sent[0]!);
  assert.equal(verifyProbe(room, nonce, answer), true);
  ws.emit("message", Buffer.from(JSON.stringify({ type: "probe", nonce })), false);
  await settle();
  assert.equal(ws.closed, CLOSE.unauthorized, "a second probe instead of the init");
});

test("a connection without a handshake closes 4101 when its time is up", async () => {
  const { connect } = await listener(["127.0.0.1"], 20);
  const ws = connect();
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.equal(ws.closed, CLOSE.unauthorized);
});

test("an oversized message closes 4103", async () => {
  const { connect } = await listener();
  const ws = connect();
  ws.emit("message", Buffer.alloc(MAX_FRAME_BYTES + 1, 0x20), false);
  await settle();
  assert.equal(ws.closed, CLOSE.tooLarge);
});

test("a browser origin is refused", async () => {
  const { connect } = await listener();
  const ws = connect({ origin: "https://example.com" });
  await settle();
  assert.equal(ws.closed, CLOSE.unauthorized);
});

test(`at most ${MAX_PENDING} connections wait for their handshake`, async () => {
  const { connect } = await listener();
  const waiting = Array.from({ length: MAX_PENDING }, () => connect());
  const extra = connect();
  await settle();
  assert.equal(extra.closed, CLOSE.unauthorized);
  assert.ok(waiting.every((ws) => ws.closed === undefined));
  waiting[0]!.close(1000);
  await settle();
  const next = connect();
  await settle();
  assert.equal(next.closed, undefined, "a slot frees when a waiting socket closes");
});

test("update rebinds only changed addresses, preserves surviving connections and follows listening state", async () => {
  const { direct, servers, connect } = await listener();
  const survivor = connect();
  await direct.update(["127.0.0.1", "192.168.1.5", "0.0.0.0", "::", "8.8.8.8"]);
  assert.deepEqual(direct.bound, ["127.0.0.1", "192.168.1.5"]);
  assert.equal(servers.length, 2);
  assert.equal(survivor.closed, undefined);
  await direct.update(["127.0.0.1"]);
  assert.equal(servers[1]!.closed, true);
  assert.equal(servers[0]!.closed, false);
  assert.equal(survivor.closed, undefined);
  await direct.update([]);
  assert.equal(survivor.closed, 1001);
  assert.equal(direct.listening, false);
  await direct.update(["::1"]);
  assert.equal(direct.listening, true);
  await direct.close();
  await direct.update(["127.0.0.1"]);
  assert.equal(direct.listening, false);
});
