import assert from "node:assert/strict";
import { test } from "node:test";
import type { Event } from "../src/envelope.ts";
import { answer, convId, hello, host, messageId, newDevice, peer } from "./hub-host.ts";

const { CLOSE } = await import("../src/hub.ts");
const foreground: Event = { kind: "foreground", data: { convId, active: true } };

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

test("an incompatible first peer_info ends the session and allows a fresh handshake", async () => {
  let peers = 0;
  const h = host({ onPeer: async () => { peers++; } });
  const a = await h.connect();
  assert.equal(h.hub.served.get(h.deviceKey)?.phase, "awaitingPeer");
  await a.send({ kind: "peer_info", data: { ...peer, protocolMin: 99, protocolMax: 99 } });
  assert.deepEqual(a.drain(), [{ kind: "error", data: { code: "update_required", message: "no common protocol version" } }]);
  assert.equal(h.hub.served.has(h.deviceKey), false);
  const message: Event = { kind: "message", data: { convId, messageId, text: "ended session probe" } };
  for (const event of [hello, message]) {
    const opened = h.hub.open(a.seal(event), a.link);
    if (opened) await h.hub.handle(opened);
    assert.equal(opened, null, "the ended session cannot open another frame");
  }
  assert.equal(peers, 0);
  assert.deepEqual(h.messages, []);
  assert.deepEqual(a.drain(), []);
  const b = await h.connect();
  pendingState(h);
  assert.equal(h.hub.served.get(h.deviceKey)?.phase, "awaitingPeer");
  await b.send(hello);
  assert.equal(peers, 1);
  assert.equal(h.hub.served.get(h.deviceKey)?.phase, "live");
  assert.equal(h.hub.broadcast([answer]), 1);
  assert.deepEqual(b.drain(), [answer]);
  assert.deepEqual(a.drain(), []);
});

test("detach ends pending and live sessions only on its link without closing it", async () => {
  const h = host();
  const pending = await h.connect();
  pending.link.path = "relay";
  const live = await h.connect(newDevice(), pending);
  const other = await h.connect(newDevice());
  await live.send(hello);
  await live.send(foreground);
  await other.send(hello);
  await other.send(foreground);
  assert.equal(h.hub.served.get(pending.deviceKey)?.phase, "awaitingPeer");
  assert.equal(h.hub.served.get(live.deviceKey)?.phase, "live");
  assert.deepEqual([...h.hub.watching(convId)], [live.deviceKey, other.deviceKey]);
  assert.equal(h.hub.broadcast([answer]), 2);
  assert.deepEqual(live.drain(), [answer]);
  assert.deepEqual(other.drain(), [answer]);
  const otherEntry = h.hub.served.get(other.deviceKey);
  h.hub.detach(pending.link);
  assert.equal(h.hub.served.has(pending.deviceKey), false);
  assert.equal(h.hub.served.has(live.deviceKey), false);
  assert.equal(h.hub.served.get(other.deviceKey), otherEntry);
  assert.deepEqual([...h.hub.watching(convId)], [other.deviceKey]);
  assert.equal(h.hub.broadcast([answer]), 1);
  assert.deepEqual(pending.drain(), [], "neither detached session receives a broadcast");
  assert.deepEqual(other.drain(), [answer]);
  assert.deepEqual(pending.closed, [], "detach does not close the shared link");
  assert.deepEqual(other.closed, []);
});

test("relayGone clears live relay presence and leaves direct and pending sessions alone", async () => {
  const h = host();
  const relay = await h.connect();
  relay.link.path = "relay";
  const direct = await h.connect(newDevice());
  const pending = await h.connect(newDevice(), relay);
  await relay.send(hello);
  await relay.send(foreground);
  await direct.send(hello);
  await direct.send(foreground);
  assert.deepEqual([...h.hub.watching(convId)], [relay.deviceKey, direct.deviceKey]);
  const pendingEntry = h.hub.served.get(pending.deviceKey);
  assert.equal(pendingEntry?.phase, "awaitingPeer");
  h.hub.relayGone();
  const relayEntry = h.hub.served.get(relay.deviceKey);
  assert.ok(relayEntry?.phase === "live");
  assert.equal(relayEntry.foreground, undefined);
  assert.equal(relayEntry.active, undefined);
  const directEntry = h.hub.served.get(direct.deviceKey);
  assert.ok(directEntry?.phase === "live");
  assert.equal(directEntry.foreground, convId);
  assert.equal(directEntry.active, true);
  assert.deepEqual([...h.hub.watching(convId)], [direct.deviceKey]);
  assert.equal(h.hub.served.get(pending.deviceKey), pendingEntry);
  assert.equal(h.hub.served.get(pending.deviceKey)?.phase, "awaitingPeer");
  await pending.send(hello);
  assert.equal(h.hub.served.get(pending.deviceKey)?.phase, "live");
  await pending.send(foreground);
  assert.deepEqual([...h.hub.watching(convId)], [direct.deviceKey, pending.deviceKey]);
  assert.deepEqual(relay.drain(), []);
  assert.deepEqual(direct.drain(), []);
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
