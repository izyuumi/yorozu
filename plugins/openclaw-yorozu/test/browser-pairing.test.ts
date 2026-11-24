import assert from "node:assert/strict";
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

const { Hub } = await import("../src/hub.ts");
const { PendingPairings } = await import("../src/pairing.ts");
const {
  b64u, decodeFrame, ed25519Keypair, encodeFrame, helloProof,
  NoiseIK, prologue, signFrame, x25519Keypair,
} = await import("../src/wire.ts");

test("browser credentials commit only after confirmation, survive rotation/restart, and can be revoked", async () => {
  let now = 2_000_000;
  const original = Date.now;
  Date.now = () => now;
  try {
    const staticHost = x25519Keypair(Buffer.alloc(32, 10));
    const room = "synthetic-browser-test";
    const pending = new PendingPairings();
    const persisted = new Map<string, { browser: true } | { staticPub: string }>();
    const sent: string[] = [];
    const received: string[] = [];
    const link = { path: "relay" as const, send: (payloads: string[]) => sent.push(...payloads) };
    const peer = { protocolMin: 3, protocolMax: 3, app: "test", capabilities: ["browser-ephemeral-v1"] };
    const createHub = () => new Hub({
      keys: { static:staticHost, room },
      peerInfo: () => ({...peer,capabilities:[...peer.capabilities,"direct"]}),
      directHints: () => ({port: 8738, lan:[{address:"192.0.2.2",prefix:24}], tailscale:[]}),
      staticKeyOf: async (key) => persisted.get(key),
      browser: {
        canPair: (accepted, at) => pending.acceptsBrowser(accepted.payload.proof, b64u(accepted.deviceStatic), b64u(accepted.deviceSigningKey), at),
        authorize: async (accepted, known, stillPending) => {
          const id = b64u(accepted.deviceSigningKey);
          if (!stillPending()) return false;
          if (known) return persisted.get(id)?.browser === true;
          if (persisted.has(id) || !pending.spend(accepted.payload.proof, b64u(accepted.deviceStatic), id, now, true)) return false;
          persisted.set(id, { browser: true });
          return true;
        },
      },
      onMessage: (message) => received.push(message.text),
      dispatch: async () => false,
    });
    let hub = createHub();
    function initiator(seed: number, signingSeed: number, secret?: string, browser = true, correctHost = true) {
      const ephemeral = Buffer.alloc(32, seed);
      const noiseKey = x25519Keypair(Buffer.alloc(32, seed + 1));
      const signing = ed25519Keypair(Buffer.alloc(32, signingSeed));
      const id = b64u(signing.publicKey);
      const noise = new NoiseIK("initiator", noiseKey, correctHost ? staticHost.publicKey : x25519Keypair(Buffer.alloc(32, 77)).publicKey, prologue(room, signing.publicKey, !browser, browser), ephemeral);
      const proof = secret ? helloProof(secret, b64u(noiseKey.publicKey), id) : undefined;
      const payload = encodeFrame({ type:"init", legacy:!browser, ...(browser && { browser:true }), deviceSigningKey:signing.publicKey, message:noise.writeMessage(Buffer.from(JSON.stringify({ts:now, proof}))) });
      const sig = signFrame(signing.privateKey, payload);
      const begin = async () => hub.handshake(payload, sig, link);
      function finish() {
        const frame = decodeFrame(sent.at(-1)!);
        assert.equal(frame?.type,"response");
        if (frame?.type !== "response") throw Error("not a response");
        noise.readMessage(frame.message);
        const session = noise.split(frame.sid);
        session.legacy = !browser;
        return async (event: unknown) => {
          const wire = decodeFrame(session.seal(Buffer.from(JSON.stringify(event))))!;
          const opened = hub.open(wire, link);
          if (opened) await hub.handle(opened);
          return !!opened;
        };
      }
      return { id, begin, finish, payload, sig, staticPub:b64u(noiseKey.publicKey) };
    }

    const secret = pending.add(now + 10_000, now, true);
    const legitimate = initiator(20, 40, secret);
    const concurrent = initiator(21, 41, secret);
    assert.equal(await hub.handshake(legitimate.payload, concurrent.sig, link), null);
    assert.equal(await initiator(30, 43, secret, true, false).begin(), null);
    assert.equal(await legitimate.begin(), legitimate.id);
    assert.equal(persisted.size, 0);
    assert.equal(sent.length, 1);
    assert.equal(await legitimate.begin(), null);
    const first = legitimate.finish();
    assert.equal(await concurrent.begin(), concurrent.id);
    const second = concurrent.finish();
    await Promise.all([first({kind:"peer_info",data:{...peer,capabilities:[...peer.capabilities,"direct"]}}), second({kind:"peer_info",data:peer})]);
    assert.deepEqual([...persisted.entries()], [[legitimate.id,{browser:true}]]);
    assert.equal(hub.served.get(legitimate.id)?.phase,"live");
    assert.equal(hub.served.has(concurrent.id),false);
    const beforeHints = sent.length;
    hub.broadcast([{kind:"direct_hints",data:{port:8738,lan:[{address:"192.0.2.2",prefix:24}],tailscale:[]}}]);
    assert.equal(sent.length,beforeHints);
    assert.equal(await first({kind:"message",data:{convId:"055890de-de0f-48be-88f3-5e009fd04491",messageId:"055890de-de0f-48be-88f3-5e009fd04492",text:"active"}}), true);
    assert.deepEqual(received, ["active"]);

    const replayAfterRestart = createHub();
    assert.equal(await replayAfterRestart.handshake(legitimate.payload, legitimate.sig, link), legitimate.id);
    assert.equal(replayAfterRestart.served.size,0);
    hub = replayAfterRestart;
    assert.equal(await first({kind:"message",data:{convId:"main",messageId:"replay",text:"old"}}), false);
    const rotated = initiator(22, 40);
    assert.notEqual(rotated.staticPub,legitimate.staticPub);
    assert.equal(await rotated.begin(), legitimate.id);
    const afterRestart = rotated.finish();
    assert.equal(await afterRestart({kind:"peer_info",data:peer}),true);
    assert.equal(hub.served.get(legitimate.id)?.phase,"live");
    const newer = initiator(23, 40);
    assert.equal(await newer.begin(), legitimate.id);
    const latePeer = newer.finish();
    hub.revoke(legitimate.id);
    persisted.delete(legitimate.id);
    assert.equal(await latePeer({kind:"peer_info",data:peer}),false);
    assert.equal(await afterRestart({kind:"message",data:{convId:"main",messageId:"blocked",text:"revoked"}}),false);
    assert.deepEqual(received,["active"]);

    const expires = pending.add(now + 100, now, true);
    const expired = initiator(24,42,expires);
    assert.equal(await expired.begin(),expired.id);
    const expiredPeer = expired.finish();
    now += 101;
    await expiredPeer({kind:"peer_info",data:peer});
    assert.equal(hub.served.has(expired.id),false);
    const nativeSecret = pending.add(now+1000,now);
    assert.equal(await initiator(25,44,nativeSecret).begin(),null);
    const legacy = initiator(28,46,undefined,false);
    persisted.set(legacy.id,{staticPub:legacy.staticPub});
    assert.equal(await legacy.begin(),legacy.id);
    assert.equal(hub.served.get(legacy.id)?.phase,"awaitingPeer");
    assert.equal(await initiator(29,46,secret).begin(),null);
  } finally { Date.now = original; }
});
