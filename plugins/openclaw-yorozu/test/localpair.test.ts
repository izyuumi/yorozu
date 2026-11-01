import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { EventEmitter, once } from "node:events";
import { existsSync } from "node:fs";
import fs from "node:fs/promises";
import { registerHooks } from "node:module";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import type { Link } from "../src/hub.ts";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  },
});
const { loopbackAddress, serveDirect } = await import("../src/direct.ts");
const { CLOSE, Hub } = await import("../src/hub.ts");
const { LOCAL_PAIR, LocalPairingFile, localPairingPath, MIN_LEFT_MS, reusable, writePrivateFile } = await import("../src/localpair.ts");
const { mintCode, OFFLINE_MS, pairer, pairingQuery, PendingPairings } = await import("../src/pairing.ts");
const { b64u, ed25519Keypair, encodeFrame, helloProof, NoiseIK, prologue, roomId, signFrame, x25519Keypair } = await import(
  "../src/wire.ts"
);

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
  readonly options: { host: string; port: number; maxPayload: number };
  constructor(options: { host: string; port: number; maxPayload: number }) {
    super();
    this.options = options;
    queueMicrotask(() => this.emit("listening"));
  }
  close(callback?: () => void) {
    callback?.();
  }
}

const settle = () => new Promise((resolve) => setImmediate(resolve));
/** Whether `file` is gone within a second (the deletion runs on the file's queue). */
async function gone(file: string): Promise<boolean> {
  for (let i = 0; i < 100 && existsSync(file); i++) await new Promise((resolve) => setTimeout(resolve, 10));
  return !existsSync(file);
}
const mode = async (p: string) => (await fs.stat(p)).mode & 0o777;

/** A host with a direct listener on `addresses`, its pairing secrets and the local pairing file under a temp state dir. */
async function host(addresses = ["127.0.0.1", "192.168.1.5"]) {
  const stateDir = await fs.mkdtemp(path.join(os.tmpdir(), "yorozu-localpair-"));
  const signing = ed25519Keypair();
  const keys = { static: x25519Keypair(), room: roomId(signing.publicKey) };
  const pending = new PendingPairings();
  const allowlist = new Map<string, string>();
  const relay: string[] = [];
  const codes: Awaited<ReturnType<typeof mintCode>>[] = [];
  let mints = 0;
  const local = new LocalPairingFile({
    file: localPairingPath(stateDir),
    mint: async () => {
      mints++;
      const code = await mintCode(null, { port: 8738, lan: [], tailscale: [] });
      codes.push(code);
      const { token, expiresAt } = code;
      const secret = pending.add(expiresAt);
      const query = pairingQuery({ relayUrl: "wss://relay.example/ws", hostStatic: keys.static.publicKey, token, room: keys.room, secret });
      return { link: `yorozu://pair?${query}`, secret, expiresAt };
    },
    pending: (secret) => pending.has(secret),
  });
  pending.onSpend = (secret) => local.spent(secret);
  const hub = new Hub({
    keys,
    peerInfo: () => ({ app: "test", protocolMin: 3, protocolMax: 3, capabilities: [] }),
    onMessage: () => {},
    dispatch: async () => false,
    staticKeyOf: async (key) => allowlist.get(key),
    pair: pairer({
      pending,
      put: async (device) => {
        allowlist.set(device.signingPub, device.staticPub);
        return [];
      },
      forget: () => {},
      allowlist: async () => [...allowlist.keys()],
      relaySend: () => (raw) => { relay.push(raw); },
    }),
  });
  const servers = new Map<string, FakeServer>();
  const direct = await serveDirect({
    addresses,
    port: 8738,
    keys: { signing, room: keys.room },
    hub,
    localPair: () => local.ensure(),
    server: (options) => {
      const server = new FakeServer(options);
      servers.set(options.host, server);
      return server;
    },
  });
  const connect = (address = "127.0.0.1") => {
    const ws = new FakeSocket();
    servers.get(address)!.emit("connection", ws, { headers: {} });
    return ws;
  };
  const message = (ws: FakeSocket, value: unknown) => ws.emit("message", Buffer.from(JSON.stringify(value)), false);
  /** Probe, then `local_pair`; the replies after the probe answer. */
  const ask = async (address = "127.0.0.1") => {
    const ws = connect(address);
    message(ws, { type: "probe", nonce: b64u(randomBytes(32)) });
    await settle();
    const closed = once(ws, "close", { signal: AbortSignal.timeout(5_000) });
    message(ws, { type: "local_pair" });
    await closed;
    return { ws, replies: ws.sent.slice(1).map((raw) => JSON.parse(raw) as Record<string, unknown>) };
  };
  return { stateDir, keys, pending, allowlist, relay, codes, local, hub, direct, connect, message, ask, mints: () => mints };
}

const secretOf = async (file: string) => new URLSearchParams((await fs.readFile(file, "utf8")).trim().split("?")[1]).get("secret")!;

test("the feature flag is named, and only 127/8 and ::1 count as loopback", () => {
  assert.equal(LOCAL_PAIR, "local-pair");
  for (const address of ["127.0.0.1", "127.9.9.9", "::1", "0:0:0:0:0:0:0:1"]) assert.equal(loopbackAddress(address), true, address);
  for (const address of ["192.168.1.5", "10.0.0.1", "fd00::1", "::", "::2", "::ffff:127.0.0.1", "localhost", ""]) {
    assert.equal(loopbackAddress(address), false, address);
  }
});

test("local_pair on loopback writes a 0600 file in a 0700 dir and answers its path only", async () => {
  const h = await host();
  const before = Date.now();
  const { ws, replies } = await h.ask();
  const file = localPairingPath(h.stateDir);
  assert.deepEqual(replies, [{ type: "local_pair", path: file }]);
  assert.equal(ws.closed, 1000);
  assert.equal(path.isAbsolute(file), true);
  assert.equal(await mode(file), 0o600);
  assert.equal(await mode(path.dirname(file)), 0o700);
  const link = (await fs.readFile(file, "utf8")).trim();
  const code = h.codes[0]!;
  assert.equal(code.directOnly, true);
  assert.equal(Buffer.from(code.token, "base64url").length, 32);
  assert.ok(code.expiresAt >= before + OFFLINE_MS && code.expiresAt <= Date.now() + OFFLINE_MS);
  assert.equal(new URLSearchParams(link.split("?")[1]).get("token"), code.token);
  assert.match(link, /^yorozu:\/\/pair\?v=3&/);
  const secret = await secretOf(file);
  assert.equal(new URLSearchParams(link.split("?")[1]).get("room"), h.keys.room);
  const wire = ws.sent.join("\n");
  assert.ok(!wire.includes(secret) && !wire.includes("yorozu://"), "neither the secret nor the link goes over the socket");
  assert.deepEqual((await fs.readdir(path.dirname(file))).filter((name) => name !== "local-pairing"), [], "no temp file left");
  await h.direct.close();
  await h.local.close();
});

test("a second request while the code is valid reuses it; a nearly expired or spent one is replaced", async () => {
  const h = await host();
  const file = localPairingPath(h.stateDir);
  await h.ask();
  const first = await secretOf(file);
  await h.ask();
  assert.equal(await secretOf(file), first);
  assert.equal(h.mints(), 1);
  await h.local.ensure(Date.now() + OFFLINE_MS - MIN_LEFT_MS + 1_000);
  const second = await secretOf(file);
  assert.notEqual(second, first, "under a minute left: a new code");
  assert.equal(h.mints(), 2);
  assert.notEqual(h.codes[0]!.token, h.codes[1]!.token, "new random offline token");
  const code = { link: "", secret: second, expiresAt: Date.now() + OFFLINE_MS };
  assert.equal(reusable(code, (s) => h.pending.has(s)), true);
  assert.equal(reusable(code, () => false), false, "spent");
  assert.equal(reusable({ ...code, expiresAt: Date.now() - 1 }, () => true), false, "expired");
  assert.equal(reusable(null, () => true), false);
  await h.direct.close();
  await h.local.close();
  assert.equal(existsSync(file), false, "gone on close");
});

test("the file's secret pairs one device, and the file is gone after", async () => {
  const h = await host();
  await h.ask();
  const file = localPairingPath(h.stateDir);
  const secret = await secretOf(file);
  const handshake = async () => {
    const device = { signing: ed25519Keypair(), static: x25519Keypair() };
    const proof = helloProof(secret, b64u(device.static.publicKey), b64u(device.signing.publicKey));
    const ik = new NoiseIK("initiator", device.static, h.keys.static.publicKey, prologue(h.keys.room, device.signing.publicKey));
    const payload = encodeFrame({ type: "init", deviceSigningKey: device.signing.publicKey, message: ik.writeMessage(Buffer.from(JSON.stringify({ ts: Date.now(), proof }))) });
    const link: Link = { path: "direct", send: () => {} };
    return h.hub.handshake(payload, signFrame(device.signing.privateKey, payload), link);
  };
  assert.ok(await handshake());
  assert.equal(await gone(file), true);
  assert.equal(await handshake(), null, "spent");
  assert.equal(h.allowlist.size, 1);
  assert.deepEqual(h.relay.map((raw) => JSON.parse(raw)), [{ type: "devices", devices: [...h.allowlist.keys()] }]);
  await h.ask();
  assert.notEqual(await secretOf(file), secret, "the next request mints anew");
  await h.direct.close();
  await h.local.close();
});

test("local_pair answers an error and closes when the pairing file cannot be written", async () => {
  const h = await host();
  await fs.writeFile(path.join(h.stateDir, "yorozu"), "not a directory");
  const { ws, replies } = await h.ask();
  assert.deepEqual(replies, [{ type: "local_pair", error: "the host could not make a pairing code" }]);
  assert.equal(ws.closed, 1000);
  assert.equal(existsSync(localPairingPath(h.stateDir)), false);
  await h.direct.close();
  await h.local.close();
});

test("the file goes when its code expires", async () => {
  const stateDir = await fs.mkdtemp(path.join(os.tmpdir(), "yorozu-localpair-"));
  const local = new LocalPairingFile({
    file: localPairingPath(stateDir),
    mint: async () => ({ link: "yorozu://pair?x", secret: "s", expiresAt: Date.now() + 30 }),
    pending: () => true,
  });
  const file = await local.ensure();
  assert.equal(existsSync(file), true);
  assert.equal(await gone(file), true, "deleted at expiry, without close");
});

test("local_pair on a non-loopback listener, or before a probe, is refused like any unexpected message", async () => {
  const h = await host();
  const { ws, replies } = await h.ask("192.168.1.5");
  assert.equal(ws.closed, CLOSE.unauthorized);
  assert.deepEqual(replies, []);
  const early = h.connect();
  h.message(early, { type: "local_pair" });
  await settle();
  assert.equal(early.closed, CLOSE.unauthorized);
  assert.equal(early.sent.length, 0);
  assert.equal(existsSync(localPairingPath(h.stateDir)), false, "nothing written");
  await h.direct.close();
});

test("the write replaces a symlink instead of following it, and tightens an open directory", async () => {
  const stateDir = await fs.mkdtemp(path.join(os.tmpdir(), "yorozu-localpair-"));
  const file = localPairingPath(stateDir);
  await fs.mkdir(path.dirname(file), { mode: 0o755 });
  await fs.chmod(path.dirname(file), 0o755);
  const target = path.join(stateDir, "elsewhere");
  await fs.writeFile(target, "untouched");
  await fs.symlink(target, file);
  await writePrivateFile(file, "link\n");
  assert.equal(await fs.readFile(target, "utf8"), "untouched");
  assert.equal((await fs.lstat(file)).isFile(), true);
  assert.equal(await mode(file), 0o600);
  assert.equal(await mode(path.dirname(file)), 0o700);
});
