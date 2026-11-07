import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { test } from "node:test";
import type { Event, Message, PeerInfo } from "../src/envelope.ts";
import type { HubOptions, Link } from "../src/hub.ts";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  },
});
const { Hub, CLOSE } = await import("../src/hub.ts");
const { encodeEvent, parseEvent } = await import("../src/envelope.ts");
const { b64u, decodeFrame, ed25519Keypair, encodeFrame, NoiseIK, prologue, roomId, signFrame, x25519Keypair } =
  await import("../src/wire.ts");

const peer: PeerInfo = { app: "test", protocolMin: 3, protocolMax: 3, capabilities: [] };
const hello: Event = { kind: "peer_info", data: peer };
const convId = "11111111-1111-4111-8111-111111111111";
const messageId = "22222222-2222-4222-8222-222222222222";
const foreground: Event = { kind: "foreground", data: { convId, active: true } };
const answer: Event = { kind: "conv_list", data: { conversations: [] } };

// Same fake Link and Noise IK setup as pairing.test.ts and apps/relay/src/direct.test.ts.
function host(options: Partial<Pick<HubOptions, "onPeer" | "dispatch">> = {}) {
  const keys = { static: x25519Keypair(), room: roomId(ed25519Keypair().publicKey) };
  const device = { signing: ed25519Keypair(), static: x25519Keypair() };
  const deviceKey = b64u(device.signing.publicKey);
  const messages: Message[] = [];
  const hub = new Hub({
    keys, peerInfo: () => peer,
    staticKeyOf: async (key) => key === deviceKey ? b64u(device.static.publicKey) : undefined,
    onMessage: (message) => { messages.push(message); },
    dispatch: async () => false,
    ...options,
  });

  async function connect() {
    const sent: string[] = [];
    const closed: { code: number; reason: string }[] = [];
    const link: Link = {
      path: "direct", send: (payloads) => { sent.push(...payloads); },
      close: (code, reason) => { closed.push({ code, reason }); },
    };
    const ik = new NoiseIK("initiator", device.static, keys.static.publicKey, prologue(keys.room, device.signing.publicKey));
    const message = ik.writeMessage(Buffer.from(JSON.stringify({ ts: Date.now() })));
    const payload = encodeFrame({ type: "init", deviceSigningKey: device.signing.publicKey, message });
    assert.equal(await hub.handshake(payload, signFrame(device.signing.privateKey, payload), link), deviceKey);
    const response = decodeFrame(sent.shift()!);
    assert.ok(response?.type === "response");
    ik.readMessage(response.message);
    const session = ik.split(message.subarray(0, 8));

    function drain() {
      return sent.splice(0).map((payload) => {
        const frame = decodeFrame(payload);
        assert.ok(frame?.type === "box");
        const plain = session.open(frame);
        assert.ok(plain, "the intended session can decrypt its reply");
        const event = parseEvent(plain);
        assert.ok(event && event.kind !== "invalid" && event.kind !== "unknown");
        return event;
      });
    }
    assert.deepEqual(drain(), [hello]);
    function open(event: Event) {
      const frame = decodeFrame(session.seal(encodeEvent(event)));
      assert.ok(frame?.type === "box");
      const opened = hub.open(frame, link);
      assert.ok(opened, "the original link opens its session's frame before replacement/end");
      return opened;
    }
    return { link, sent, closed, drain, open, send: (event: Event) => hub.handle(open(event)) };
  }
  return { hub, deviceKey, messages, connect };
}

function pendingState(h: ReturnType<typeof host>) {
  const entry = h.hub.served.get(h.deviceKey);
  assert.ok(entry, "the replacement session still exists");
  assert.deepEqual(
    { peer: entry.peer, foreground: entry.foreground, active: entry.active },
    { peer: undefined, foreground: undefined, active: undefined },
    "only the replacement's own peer_info may make it live",
  );
  assert.deepEqual([...h.hub.watching(convId)], [], "a pending session is not watching");
  assert.equal(h.hub.broadcast([answer]), 0, "a pending session receives no broadcast");
}

test("a frame opened on a replaced session is not handled as the new session", async (t) => {
  const h = host();
  const a = await h.connect();
  await a.send(hello);
  const message: Event = { kind: "message", data: { convId, messageId, text: "stale session probe" } };
  const opened = [hello, foreground, message, message].map(a.open);
  const b = await h.connect();
  assert.deepEqual(a.closed, [{ code: CLOSE.replaced, reason: "replaced" }]);
  for (const frame of opened) {
    await h.hub.handle(frame);
    pendingState(h);
  }
  const replies = { A: a.drain(), B: b.drain() };
  t.diagnostic(`S1 message deliveries: ${h.messages.length}; replies: ${JSON.stringify(replies)}`);
  assert.ok(h.messages.length === 0 || h.messages.length === 1, "a stale message is refused or delivered exactly once");
  if (h.messages.length) assert.deepEqual(h.messages, [message.data]);
  assert.deepEqual(replies, { A: [], B: [] }, "a stale message cannot deliver receipts to an ended or pending session");
  await b.send(hello);
  assert.equal(h.hub.broadcast([answer]), 1, "S2 becomes live after its own peer_info");
  assert.deepEqual(b.drain(), [answer]);
});

test("an opened first peer_info from a replaced session cannot make its replacement live", async () => {
  const h = host();
  const a = await h.connect();
  const opened = a.open(hello);
  const b = await h.connect();
  await h.hub.handle(opened);
  pendingState(h);
  assert.deepEqual(b.drain(), []);
});

test("a foreground event from a replaced session does not change the new session's watching()", async () => {
  const h = host();
  const a = await h.connect();
  await a.send(hello);
  const stale = a.open(foreground);
  const staleClear = a.open({ kind: "foreground", data: { active: false } });
  const b = await h.connect();
  await b.send(hello);
  await h.hub.handle(stale);
  assert.deepEqual([...h.hub.watching(convId)], [], "stale presence cannot activate the replacement");
  await b.send(foreground);
  await h.hub.handle(staleClear);
  assert.deepEqual([...h.hub.watching(convId)], [h.deviceKey], "stale presence cannot clear the replacement");
});

test("onPeer replies for a replaced session do not reach the new session before its own peer_info", async (t) => {
  const entered = Promise.withResolvers<void>();
  const resume = Promise.withResolvers<void>();
  const h = host({ onPeer: async ({ reply }) => {
    entered.resolve();
    await resume.promise;
    reply([answer]);
  } });
  const a = await h.connect();
  const handling = a.send(hello);
  await entered.promise;
  const b = await h.connect();
  assert.deepEqual(a.closed, [{ code: CLOSE.replaced, reason: "replaced" }]);
  resume.resolve();
  await handling;
  const replies = { A: a.drain(), B: b.drain() };
  t.diagnostic(`late onPeer reply: ${JSON.stringify(replies)}`);
  assert.deepEqual(replies, { A: [], B: [] }, "onPeer must not reply to a replaced link or a pending replacement");
  pendingState(h);
});

for (const replacement of ["none", "pending", "live"] as const) {
  test(`a request answered after its session ended: replacement ${replacement}`, async (t) => {
    const entered = Promise.withResolvers<void>();
    const resume = Promise.withResolvers<void>();
    const h = host({ dispatch: async ({ reply }) => {
      entered.resolve();
      await resume.promise;
      reply([answer]);
      return true;
    } });
    const a = await h.connect();
    await a.send(hello);
    const handling = a.send({ kind: "conv_list", data: {} });
    await entered.promise;
    h.hub.end(h.deviceKey);
    const b = replacement === "none" ? undefined : await h.connect();
    if (replacement === "live") await b!.send(hello);
    resume.resolve();
    await handling;
    const replies = { A: a.drain(), B: b?.drain() ?? [] };
    t.diagnostic(`late dispatch reply: ${JSON.stringify(replies)}`);
    assert.deepEqual(replies.A, [], "an ended session receives no late answer");
    assert.deepEqual(replies.B, replacement === "live" ? [answer] : [], "only a current live session receives a late answer");
    if (replacement === "pending") pendingState(h);
    if (replacement === "none") assert.equal(h.hub.served.has(h.deviceKey), false);
  });
}

test("a box before peer_info is refused and does not end the session", async () => {
  const h = host();
  const a = await h.connect();
  await a.send(foreground);
  assert.deepEqual(a.drain(), [{ kind: "error", data: { code: "bad_request", message: "the session must start with peer_info" } }]);
  pendingState(h);
  assert.deepEqual(a.closed, []);
  await a.send(hello);
  await a.send(foreground);
  assert.deepEqual([...h.hub.watching(convId)], [h.deviceKey]);
  assert.equal(h.hub.broadcast([answer]), 1);
  assert.deepEqual(a.drain(), [answer]);
});

test("a second peer_info does not reset the phase", async () => {
  let peers = 0;
  const h = host({ onPeer: async () => { peers++; } });
  const a = await h.connect();
  await a.send(hello);
  await a.send(foreground);
  await a.send({ kind: "peer_info", data: { ...peer, app: "second", protocolMin: 99, protocolMax: 99 } });
  assert.equal(peers, 1, "a second peer_info must not repeat onPeer");
  const entry = h.hub.served.get(h.deviceKey);
  assert.deepEqual(entry?.peer, peer, "the first peer_info stands, even if the second is incompatible");
  assert.equal(entry?.foreground, convId);
  assert.equal(entry?.active, true);
  assert.deepEqual([...h.hub.watching(convId)], [h.deviceKey]);
  assert.equal(h.hub.broadcast([answer]), 1);
  assert.deepEqual(a.drain(), [answer]);
  assert.deepEqual(a.closed, []);
});

test("end() during an in-flight handle leaves no live entry", async (t) => {
  const entered = Promise.withResolvers<void>();
  const resume = Promise.withResolvers<void>();
  const h = host({ onPeer: async ({ reply }) => {
    entered.resolve();
    await resume.promise;
    reply([answer]);
  } });
  const a = await h.connect();
  const handling = a.send(hello);
  await entered.promise;
  const queued = a.open(foreground);
  h.hub.end(h.deviceKey);
  resume.resolve();
  await handling;
  // A receive queue can still hold an already-opened frame after the await resumes.
  await h.hub.handle(queued);
  t.diagnostic(`captured entry after end: foreground=${queued.entry.foreground}, active=${queued.entry.active}`);
  assert.equal(h.hub.served.has(h.deviceKey), false, "resuming a handle must not resurrect an ended session");
  assert.deepEqual([...h.hub.watching(convId)], []);
  assert.equal(h.hub.broadcast([answer]), 0);
  assert.deepEqual(a.drain(), [], "an ended session receives neither late replies nor broadcasts");
});
