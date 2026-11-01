import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { test } from "node:test";
import type { DirectHints } from "../src/envelope.ts";
import type { Link } from "../src/hub.ts";
registerHooks({ resolve(specifier, context, next) {
  if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
    const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
    if (existsSync(ts)) return next(ts.href, context);
  }
  return next(specifier, context);
} });
const { mintCode, OFFLINE_MS, pairer, pairingQuery, PendingPairings } = await import("../src/pairing.ts");
const { Hub } = await import("../src/hub.ts");
const { b64u, decodeFrame, ed25519Keypair, encodeFrame, fromB64u, helloProof, NoiseIK, prologue, roomId, signFrame, x25519Keypair } =
  await import("../src/wire.ts");

const hints: DirectHints = {
  port: 8738,
  lan: ["10.0.0.4", "172.16.0.9", "192.168.1.5", "192.168.2.5", "fd00::5"].map((address) => ({ address, prefix: 24 })),
  tailscale: [{ address: "100.100.1.2" }, { address: "fd7a:115c:a1e0::1" }, { address: "100.100.1.3" }],
  magicDNS: "host.tail.ts.net",
};

test("the pairing link carries the port, 4 LAN and 2 Tailscale addresses, no MagicDNS name", () => {
  const base = { relayUrl: "wss://relay.example/ws", hostStatic: Buffer.alloc(32, 7), token: "tok", room: "room", secret: "sec" };
  const query = pairingQuery({ ...base, hints });
  const params = new URLSearchParams(query);
  assert.equal(params.get("port"), "8738");
  assert.equal(params.get("lan"), "10.0.0.4/24,172.16.0.9/24,192.168.1.5/24,192.168.2.5/24");
  assert.equal(params.get("ts"), "100.100.1.2,fd7a:115c:a1e0::1");
  assert.ok(query.includes("ts=100.100.1.2,fd7a:115c:a1e0::1"), "colons stay readable");
  assert.ok(!query.includes("ts.net"));
  const ipv6 = new URLSearchParams(pairingQuery({ ...base, hints: { port: 9000, lan: [{ address: "fd00::5", prefix: 64 }], tailscale: [] } }));
  assert.equal(ipv6.get("lan"), "fd00::5/64");
  assert.equal(ipv6.get("ts"), null);
  const plain = pairingQuery(base);
  assert.equal(plain, "v=3&relay=wss://relay.example/ws&key=" + b64u(base.hostStatic) + "&token=tok&room=room&secret=sec");
});

test("a relay token while the relay mints; an offline code when it can't but direct listens; else an error", async () => {
  const relay = await mintCode(async () => ({ token: "relay-token", expiresAt: 5 }), hints);
  assert.deepEqual(relay, { token: "relay-token", expiresAt: 5, directOnly: false });
  const logs: string[] = [];
  const log = { info: (s: string) => logs.push(s), warn: assert.fail };
  for (const mint of [null, async () => { throw new Error("the relay did not answer the token request"); }]) {
    const offline = await mintCode(mint, hints, log, 1_000);
    assert.equal(offline.directOnly, true);
    assert.equal(offline.expiresAt, 1_000 + OFFLINE_MS);
    assert.equal(OFFLINE_MS, 10 * 60_000);
    assert.equal(fromB64u(offline.token)?.length, 32);
    assert.notEqual(offline.token, (await mintCode(mint, hints, log)).token, "random");
  }
  assert.ok(logs.includes("yorozu: relay unreachable; pairing code works over the direct path only"));
  await assert.rejects(mintCode(null, undefined), /neither its relay nor its direct listener/);
  await assert.rejects(mintCode(async () => { throw new Error("relay timeout"); }, undefined), /relay timeout/);
});

const peer = { app: "test", protocolMin: 3, protocolMax: 3, capabilities: [] as string[] };

function host(relayConnected: boolean) {
  const signing = ed25519Keypair();
  const keys = { static: x25519Keypair(), room: roomId(signing.publicKey) };
  const allowlist = new Map<string, string>();
  const pending = new PendingPairings();
  const relay: string[] = [];
  const refused: string[] = [];
  const logs: string[] = [];
  const log = { info: (s: string) => logs.push(s), warn: (s: string) => logs.push(s) };
  const hub = new Hub({
    keys, peerInfo: () => peer, onMessage: () => {}, dispatch: async () => false,
    staticKeyOf: async (key) => allowlist.get(key),
    refused: (key) => refused.push(key),
    log,
    pair: pairer({
      log,
      pending,
      put: async (device) => { allowlist.set(device.signingPub, device.staticPub); return []; },
      forget: () => {},
      allowlist: async () => [...allowlist.keys()],
      relaySend: () => relayConnected ? (raw) => relay.push(raw) : null,
    }),
  });
  return { keys, hub, allowlist, pending, relay, refused, logs };
}

/** A device's init frame, signed, with a hello proof over `secret` when given. */
function init(h: ReturnType<typeof host>, secret?: string, device = { signing: ed25519Keypair(), static: x25519Keypair() }) {
  const proof = secret && helloProof(secret, b64u(device.static.publicKey), b64u(device.signing.publicKey));
  const ik = new NoiseIK("initiator", device.static, h.keys.static.publicKey, prologue(h.keys.room, device.signing.publicKey));
  const message = ik.writeMessage(Buffer.from(JSON.stringify({ ts: Date.now(), ...(proof && { proof }) })));
  const payload = encodeFrame({ type: "init", deviceSigningKey: device.signing.publicKey, message });
  return { device, payload, sig: signFrame(device.signing.privateKey, payload) };
}

const link = (path: "relay" | "direct"): Link & { sent: string[][] } => {
  const sent: string[][] = [];
  return { path, sent, send: (payloads) => sent.push(payloads) };
};

test("over direct, a valid proof pairs the device once and the relay gets the allowlist at once", async () => {
  const h = host(true);
  const secret = h.pending.add(Date.now() + OFFLINE_MS);
  const first = init(h, secret);
  const direct = link("direct");
  const key = b64u(first.device.signing.publicKey);
  assert.equal(await h.hub.handshake(first.payload, first.sig, direct), key);
  assert.equal(decodeFrame(direct.sent[0]![0]!)?.type, "response");
  assert.equal(h.allowlist.get(key), b64u(first.device.static.publicKey));
  assert.deepEqual(h.relay.map((raw) => JSON.parse(raw)), [{ type: "devices", devices: [key] }]);
  assert.ok(h.logs.includes("yorozu: device paired over direct"));
  const second = init(h, secret);
  assert.equal(await h.hub.handshake(second.payload, second.sig, link("direct")), null, "the secret is spent");
  assert.equal(h.allowlist.size, 1);
  const again = init(h, undefined, first.device);
  assert.equal(await h.hub.handshake(again.payload, again.sig, link("relay")), key, "the paired device is known on the relay");
  assert.deepEqual(h.refused, [], "direct refusals don't tell the relay");
});

test("over direct, an expired secret or no proof is refused; the allowlist waits for the relay", async () => {
  const h = host(false);
  const expired = init(h, h.pending.add(Date.now() - 1));
  assert.equal(await h.hub.handshake(expired.payload, expired.sig, link("direct")), null);
  const bare = init(h);
  h.pending.add(Date.now() + OFFLINE_MS);
  assert.equal(await h.hub.handshake(bare.payload, bare.sig, link("direct")), null);
  assert.equal(h.allowlist.size, 0);
  assert.deepEqual(h.refused, []);
  const valid = init(h, h.pending.add(Date.now() + OFFLINE_MS));
  assert.ok(await h.hub.handshake(valid.payload, valid.sig, link("direct")));
  assert.deepEqual(h.relay, [], "no relay: the devices go out on the next registered");
});

test("over the relay, a pairing doesn't resend the allowlist and a refusal revokes", async () => {
  const h = host(true);
  const valid = init(h, h.pending.add(Date.now() + OFFLINE_MS));
  assert.ok(await h.hub.handshake(valid.payload, valid.sig, link("relay")));
  assert.deepEqual(h.relay, []);
  const stranger = init(h);
  assert.equal(await h.hub.handshake(stranger.payload, stranger.sig, link("relay")), null);
  assert.deepEqual(h.refused, [b64u(stranger.device.signing.publicKey)]);
});
