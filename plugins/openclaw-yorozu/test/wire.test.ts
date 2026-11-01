import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { test } from "node:test";
import type { Frame } from "../src/wire.ts";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  },
});
const { PEER_INFO, UNVERSIONED_WIRE, parseEvent } = await import("../src/envelope.ts");
const { Hub } = await import("../src/hub.ts");
const {
  acceptHandshake, b64u, decodeFrame, ed25519Keypair, encodeFrame, NoiseIK, prologue, signFrame, x25519Keypair,
} = await import("../src/wire.ts");

for (const legacy of [false, true]) {
  const format = legacy ? "legacy" : "unversioned";
  const frames: Frame[] = [
    { type: "init", deviceSigningKey: Buffer.alloc(32, 1), message: Buffer.alloc(96, 2) },
    { type: "response", sid: Buffer.alloc(8, 3), message: Buffer.alloc(48, 4) },
    { type: "box", sid: Buffer.alloc(8, 5), counter: 42, ciphertext: Buffer.alloc(16, 6) },
  ];
  for (const [index, frame] of frames.entries()) {
    test(`${format} ${frame.type} round-trips with its wire head and legacy flag`, () => {
      const payload = encodeFrame({ ...frame, legacy });
      const bytes = Buffer.from(payload, "base64url");
      assert.equal(bytes[0], legacy ? 3 : 0x11 + index);
      if (legacy) assert.equal(bytes[1], index + 1);
      assert.deepEqual(decodeFrame(payload), { ...frame, legacy });
      for (let length = 0; length < bytes.length; length++) {
        assert.equal(decodeFrame(b64u(bytes.subarray(0, length))), null, `truncated at ${length}`);
      }
    });
  }

  test(`${format} prologue uses the matching domain`, () => {
    assert.equal(prologue("room", Buffer.from([0xff]), legacy).toString(), `${legacy ? "yorozu-v3" : "yorozu"}|room|_w`);
  });
}

test("unknown frame heads and legacy types are rejected", () => {
  for (let first = 0; first <= 255; first++) {
    if ([3, 0x11, 0x12, 0x13].includes(first)) continue;
    assert.equal(decodeFrame(b64u(Buffer.concat([Buffer.from([first]), Buffer.alloc(160)]))), null);
  }
  for (const type of [0, 4, 0x11, 0x12, 0x13, 255]) {
    assert.equal(decodeFrame(b64u(Buffer.concat([Buffer.from([3, type]), Buffer.alloc(160)]))), null);
  }
});

function initiate(legacy: boolean, legacyPrologue = legacy) {
  const host = x25519Keypair();
  const device = x25519Keypair();
  const signing = ed25519Keypair();
  const room = "wire-test-room";
  const noise = new NoiseIK("initiator", device, host.publicKey, prologue(room, signing.publicKey, legacyPrologue));
  const payload = encodeFrame({
    legacy, type: "init", deviceSigningKey: signing.publicKey,
    message: noise.writeMessage(Buffer.from(JSON.stringify({ ts: Date.now() }))),
  });
  return { host, device, signing, room, noise, payload, sig: signFrame(signing.privateKey, payload) };
}

for (const legacy of [false, true]) {
  const format = legacy ? "legacy" : "unversioned";
  test(`${format} device handshake binds response and boxes to init and advertises unversioned-wire`, async () => {
    const init = initiate(legacy);
    const sent: string[] = [];
    const link = { path: "relay" as const, send: (payloads: string[]) => { sent.push(...payloads); } };
    const deviceKey = b64u(init.signing.publicKey);
    const hub = new Hub({
      keys: { static: init.host, room: init.room },
      peerInfo: () => PEER_INFO,
      staticKeyOf: async (key) => key === deviceKey ? b64u(init.device.publicKey) : undefined,
      onMessage: () => {},
      dispatch: async () => false,
    });
    assert.equal(await hub.handshake(init.payload, init.sig, link), deviceKey);
    assert.equal(sent.length, 2);
    const response = decodeFrame(sent[0]!);
    assert.ok(response?.type === "response");
    assert.equal(response.legacy, legacy);
    assert.equal(init.noise.readMessage(response.message).length, 0);
    const client = init.noise.split(response.sid);
    client.legacy = legacy;
    const entry = hub.served.get(deviceKey);
    assert.ok(entry);
    assert.equal(entry.session.legacy, legacy);
    assert.deepEqual(entry.session.handshakeHash, client.handshakeHash);

    const peerBox = decodeFrame(sent[1]!);
    assert.ok(peerBox?.type === "box");
    assert.equal(peerBox.legacy, legacy);
    const plain = client.open(peerBox);
    assert.ok(plain);
    const peer = parseEvent(plain);
    assert.ok(peer?.kind === "peer_info");
    assert.equal(UNVERSIONED_WIRE, "unversioned-wire");
    assert.ok(peer.data.capabilities.includes("unversioned-wire"));

    const box = decodeFrame(client.seal(Buffer.from("device box")));
    assert.ok(box?.type === "box");
    // Change only the format; a valid SID, counter and tag must not bypass the session binding.
    const otherFormat = decodeFrame(encodeFrame({ ...box, legacy: !legacy }));
    assert.ok(otherFormat);
    assert.equal(hub.open(otherFormat, link), null);
    const opened = hub.open(box, link);
    assert.ok(opened);
    assert.equal(opened.plain.toString(), "device box");
    assert.equal(hub.open(box, link), null, "accepted counter cannot be replayed");
  });

  test(`${format} init with the other prologue fails the handshake`, () => {
    const init = initiate(legacy, !legacy);
    assert.equal(acceptHandshake(init), null);
  });
}
