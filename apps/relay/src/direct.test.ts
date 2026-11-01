// End to end over the direct path (#532 step 3): the plugin's session core (`hub.ts`) and direct listener (`direct.ts`)
// on a real `ws` server, a device built on the plugin's own Noise code, and the Node relay as the fallback path. What
// OpenClaw adds around them (device storage, agent turns, the relay redial loop in `relay.ts`) is replaced by the
// in-memory allowlist and the small relay host link below.
import { randomBytes, randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";
import { afterEach, beforeAll, afterAll, expect, test } from "vitest";
import { WebSocketServer } from "ws";
import { serveDirect, verifyProbe, MAX_FRAME_BYTES, MAX_PENDING, type DirectListener } from "../../../plugins/openclaw-yorozu/src/direct.ts";
import { encodeEvent, parseEvent, type Event, type Message, type PeerInfo } from "../../../plugins/openclaw-yorozu/src/envelope.ts";
import { CLOSE, Hub, type Link } from "../../../plugins/openclaw-yorozu/src/hub.ts";
import {
  b64u,
  decodeFrame,
  ed25519Keypair,
  encodeFrame,
  NoiseIK,
  prologue,
  roomId,
  signFrame,
  verifyFrame,
  x25519Keypair,
  type Session,
} from "../../../plugins/openclaw-yorozu/src/wire.ts";
import { startRelay, type Relay } from "./index.js";
import { client, type Client } from "./testing.js";

let relay: Relay;
beforeAll(async () => {
  relay = await startRelay(0);
});
afterAll(() => relay.close());

const cleanup: (() => unknown)[] = [];
afterEach(async () => {
  for (const step of cleanup.splice(0).reverse()) await step();
});

const CONV = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b";
const local: PeerInfo = { protocolMin: 3, protocolMax: 3, app: "test", capabilities: [] };

type Device = ReturnType<typeof newDevice>;
function newDevice() {
  return { signing: ed25519Keypair(), static: x25519Keypair() };
}

async function host(opts: { direct?: boolean; pendingMs?: number } = {}) {
  const signing = ed25519Keypair();
  const keys = { static: x25519Keypair(), signing, room: roomId(signing.publicKey) };
  const allowlist = new Map<string, string>();
  const messages: Message[] = [];
  let direct: DirectListener | null = null;
  const servers: WebSocketServer[] = [];
  let relayFrames: ((payloads: string[]) => void) | null = null;
  const relayLink: Link = { path: "relay", send: (payloads) => relayFrames?.(payloads) };
  const hub = new Hub({
    keys,
    peerInfo: () => ({ ...local, capabilities: direct?.listening ? ["direct"] : [] }),
    staticKeyOf: async (key) => allowlist.get(key),
    onMessage: (message) => messages.push(message),
    dispatch: async () => false,
  });
  if (opts.direct !== false) {
    direct = await serveDirect({
      addresses: ["127.0.0.1"],
      port: 0,
      keys,
      hub,
      ...(opts.pendingMs !== undefined && { pendingMs: opts.pendingMs }),
      server: (options) => {
        const server = new WebSocketServer(options);
        servers.push(server);
        return server;
      },
    });
    cleanup.push(() => direct?.close());
  }
  const port = servers[0] ? (servers[0].address() as AddressInfo).port : 0;

  // The relay half of `relay.ts`: register, then hand every device frame to the hub.
  const link = client(relay.port, keys.room);
  cleanup.push(() => link.ws.terminate());
  await link.open;
  const { nonce } = await link.next();
  link.send({ type: "register", pubkey: b64u(signing.publicKey), nonceSig: signFrame(signing.privateKey, nonce) });
  expect(await link.next()).toMatchObject({ type: "registered", pushProxy: true });
  relayFrames = (payloads) => {
    for (const payload of payloads) link.send({ type: "frame", payload, sig: signFrame(signing.privateKey, payload) });
  };
  const tokens: ((token: string) => void)[] = [];
  const receive = async (msg: Record<string, any>): Promise<void> => {
    if (msg.type === "token") return tokens.shift()?.(msg.token);
    if (msg.type === "phones" && msg.count === 0) return hub.relayGone();
    if (msg.type !== "frame") return;
    const frame = decodeFrame(msg.payload);
    if (frame?.type === "init") await hub.handshake(msg.payload, msg.sig, relayLink);
    else if (frame?.type === "box") {
      const opened = hub.open(frame, relayLink);
      if (opened) await hub.handle(opened);
    }
  };
  let queue = Promise.resolve();
  link.ws.on("message", (data) => {
    queue = queue.then(() => receive(JSON.parse(String(data))));
  });
  const mint = () =>
    new Promise<string>((resolve) => {
      tokens.push(resolve);
      link.send({ type: "mint" });
    });
  const allow = (device: Device) => allowlist.set(b64u(device.signing.publicKey), b64u(device.static.publicKey));
  return { keys, hub, messages, port, direct, mint, allow };
}
type Host = Awaited<ReturnType<typeof host>>;

/** A device's session over one socket: the relay's after `joined`, or the listener's after the probe. */
function noise(device: Device, h: Host) {
  const ik = new NoiseIK("initiator", device.static, h.keys.static.publicKey, prologue(h.keys.room, device.signing.publicKey));
  const message = ik.writeMessage(Buffer.from(JSON.stringify({ ts: Date.now() })));
  const init = encodeFrame({ type: "init", deviceSigningKey: device.signing.publicKey, message });
  return {
    init,
    finish: (payload: string): Session => {
      const frame = decodeFrame(payload);
      if (frame?.type !== "response") throw new Error("not a response");
      ik.readMessage(frame.message);
      return ik.split(message.subarray(0, 8));
    },
  };
}

const framed = (device: Device, payload: string) => ({ type: "frame", payload, sig: signFrame(device.signing.privateKey, payload) });
const open = (session: Session, payload: string): Event | undefined => {
  const frame = decodeFrame(payload);
  const plain = frame ? session.open(frame) : null;
  const event = plain ? parseEvent(plain) : null;
  return event && event.kind !== "invalid" && event.kind !== "unknown" ? event : undefined;
};

/** Waits for the next host frame on `socket`, checking the host's signature. */
async function nextFrame(socket: Client, h: Host): Promise<string> {
  for (;;) {
    const msg = await socket.next();
    if (msg.type !== "frame") continue;
    expect(verifyFrame(h.keys.signing.publicKey, msg.payload, msg.sig)).toBe(true);
    return msg.payload;
  }
}

/** Probes, checks the answer, sends the init and opens the session; null when the listener is not there. */
async function dialDirect(device: Device, h: Host): Promise<{ socket: Client; session: Session; peer: PeerInfo } | null> {
  if (!h.port) return null;
  const socket = client(`ws://127.0.0.1:${h.port}`);
  cleanup.push(() => socket.ws.terminate());
  const reached = await Promise.race([socket.open.then(() => true), new Promise<boolean>((r) => socket.ws.once("error", () => r(false)))]);
  if (!reached) return null;
  const nonce = b64u(randomBytes(32));
  socket.send({ type: "probe", nonce });
  const answer = await socket.next();
  if (!verifyProbe(h.keys.room, nonce, answer)) return null;
  const hs = noise(device, h);
  socket.send(framed(device, hs.init));
  const session = hs.finish(await nextFrame(socket, h));
  const hello = open(session, await nextFrame(socket, h));
  if (hello?.kind !== "peer_info") throw new Error("expected the host's peer_info");
  socket.send(framed(device, session.seal(encodeEvent({ kind: "peer_info", data: local }))));
  expect(await socket.next()).toMatchObject({ type: "accepted" });
  return { socket, session, peer: hello.data };
}

async function dialRelay(device: Device, h: Host): Promise<{ socket: Client; session: Session; peer: PeerInfo }> {
  const token = await h.mint();
  const socket = client(relay.port, h.keys.room);
  cleanup.push(() => socket.ws.terminate());
  await socket.open;
  await socket.next();
  socket.send({ type: "join", roomId: h.keys.room, phonePubkey: b64u(device.signing.publicKey), token, sig: signFrame(device.signing.privateKey, token) });
  expect(await socket.next()).toMatchObject({ type: "joined", ownerOnline: true });
  const hs = noise(device, h);
  socket.send(framed(device, hs.init));
  expect(await socket.next()).toMatchObject({ type: "accepted" });
  const session = hs.finish(await nextFrame(socket, h));
  const hello = open(session, await nextFrame(socket, h));
  if (hello?.kind !== "peer_info") throw new Error("expected the host's peer_info");
  socket.send(framed(device, session.seal(encodeEvent({ kind: "peer_info", data: local }))));
  expect(await socket.next()).toMatchObject({ type: "accepted" });
  return { socket, session, peer: hello.data };
}

/** Direct first, the relay when the listener is off or unreachable: the client's race, reduced to its fallback. */
const connect = async (device: Device, h: Host) => (await dialDirect(device, h)) ?? (await dialRelay(device, h));

const message = (text: string): Message => ({ convId: CONV, messageId: randomUUID(), text });
const until = async (check: () => boolean) => {
  for (let i = 0; i < 200 && !check(); i++) await new Promise((r) => setTimeout(r, 10));
  expect(check()).toBe(true);
};

test("a paired device probes, opens a session directly, sends a message and gets accepted and delivered", async () => {
  const h = await host();
  const device = newDevice();
  h.allow(device);
  const link = await dialDirect(device, h);
  expect(link).not.toBeNull();
  const { socket, session, peer } = link!;
  expect(peer.capabilities).toContain("direct");
  const sent = message("hello");
  const frame = framed(device, session.seal(encodeEvent({ kind: "message", data: sent })));
  socket.send(frame);
  expect(await socket.next()).toEqual({ type: "accepted", sig: frame.sig });
  expect(open(session, await nextFrame(socket, h))).toEqual({ kind: "delivered", data: { convId: CONV, messageId: sent.messageId } });
  expect(h.messages).toEqual([sent]);
  expect([...h.hub.direct()]).toEqual([b64u(device.signing.publicKey)]);
  socket.send({ type: "ping" });
  expect(await socket.next()).toEqual({ type: "pong" });
});

test("without the listener the device falls back to the relay and completes its session there", async () => {
  const h = await host({ direct: false });
  const device = newDevice();
  h.allow(device);
  const { socket, session, peer } = await connect(device, h);
  expect(peer.capabilities).not.toContain("direct");
  const sent = message("over the relay");
  socket.send(framed(device, session.seal(encodeEvent({ kind: "message", data: sent }))));
  expect(await socket.next()).toMatchObject({ type: "accepted", buffered: false });
  expect(open(session, await nextFrame(socket, h))).toMatchObject({ kind: "delivered" });
  expect(h.messages).toEqual([sent]);
  expect(h.hub.direct().size).toBe(0);
});

test("an unreachable listener also falls back to the relay", async () => {
  const h = await host();
  await h.direct!.close();
  const device = newDevice();
  h.allow(device);
  const { session } = await connect(device, h);
  expect(session).toBeDefined();
  expect(h.hub.direct().size).toBe(0);
});

test("each device gets frames over its own path; relay presence resets leave direct devices alone", async () => {
  const h = await host();
  const near = newDevice();
  const far = newDevice();
  h.allow(near);
  h.allow(far);
  const direct = (await dialDirect(near, h))!;
  const relayed = await dialRelay(far, h);
  const front = encodeEvent({ kind: "foreground", data: { convId: CONV, active: true } });
  direct.socket.send(framed(near, direct.session.seal(front)));
  relayed.socket.send(framed(far, relayed.session.seal(front)));
  await direct.socket.next();
  await relayed.socket.next();
  await until(() => h.hub.watching(CONV).size === 2);
  const reply: Event = { kind: "typing", data: { convId: CONV, active: true } };
  expect(h.hub.broadcast([reply])).toBe(2);
  expect(open(direct.session, await nextFrame(direct.socket, h))).toEqual(reply);
  expect(open(relayed.session, await nextFrame(relayed.socket, h))).toEqual(reply);
  // The relay sends every host frame to every device socket: a second frame here would be the direct device's.
  h.hub.broadcast([{ kind: "typing", data: { convId: CONV, active: false } }]);
  expect(open(relayed.session, await nextFrame(relayed.socket, h))).toMatchObject({ data: { active: false } });
  expect(open(direct.session, await nextFrame(direct.socket, h))).toMatchObject({ data: { active: false } });
  relayed.socket.ws.close();
  await relayed.socket.closed;
  await until(() => h.hub.watching(CONV).size === 1);
  expect([...h.hub.watching(CONV)]).toEqual([b64u(near.signing.publicKey)]);
});

test("a message resent on the other path after a re-race runs once", async () => {
  const h = await host();
  const device = newDevice();
  h.allow(device);
  const sent = message("twice");
  const relayed = await dialRelay(device, h);
  relayed.socket.send(framed(device, relayed.session.seal(encodeEvent({ kind: "message", data: sent }))));
  await until(() => h.messages.length === 1);
  relayed.socket.ws.close();
  const direct = (await dialDirect(device, h))!;
  direct.socket.send(framed(device, direct.session.seal(encodeEvent({ kind: "message", data: sent }))));
  await direct.socket.next();
  expect(open(direct.session, await nextFrame(direct.socket, h))).toMatchObject({ kind: "delivered", data: { messageId: sent.messageId } });
  expect(h.messages).toEqual([sent]);
});

test("a device that is not allowlisted is closed 4101 after its init", async () => {
  const h = await host();
  const stranger = newDevice();
  const socket = client(`ws://127.0.0.1:${h.port}`);
  cleanup.push(() => socket.ws.terminate());
  await socket.open;
  const nonce = b64u(randomBytes(32));
  socket.send({ type: "probe", nonce });
  expect(verifyProbe(h.keys.room, nonce, await socket.next())).toBe(true);
  socket.send(framed(stranger, noise(stranger, h).init));
  expect(await socket.closed).toBe(CLOSE.unauthorized);
});

test("a malformed probe, or an init before the probe, closes 4101", async () => {
  const h = await host();
  const device = newDevice();
  h.allow(device);
  const bad = client(`ws://127.0.0.1:${h.port}`);
  const early = client(`ws://127.0.0.1:${h.port}`);
  cleanup.push(() => bad.ws.terminate(), () => early.ws.terminate());
  await Promise.all([bad.open, early.open]);
  bad.send({ type: "probe", nonce: "short" });
  early.send(framed(device, noise(device, h).init));
  expect(await bad.closed).toBe(CLOSE.unauthorized);
  expect(await early.closed).toBe(CLOSE.unauthorized);
});

test("a client refuses a probe answer that is not from its room's host", async () => {
  const h = await host();
  const other = await host();
  const socket = client(`ws://127.0.0.1:${other.port}`);
  cleanup.push(() => socket.ws.terminate());
  await socket.open;
  const nonce = b64u(randomBytes(32));
  socket.send({ type: "probe", nonce });
  const answer = await socket.next();
  expect(verifyProbe(other.keys.room, nonce, answer)).toBe(true);
  expect(verifyProbe(h.keys.room, nonce, answer)).toBe(false);
  expect(verifyProbe(other.keys.room, nonce, { ...answer, sig: b64u(randomBytes(64)) })).toBe(false);
});

test("a frame with a bad signature after the handshake closes 4101", async () => {
  const h = await host();
  const device = newDevice();
  h.allow(device);
  const { socket, session } = (await dialDirect(device, h))!;
  const payload = session.seal(encodeEvent({ kind: "message", data: message("forged") }));
  socket.send({ type: "frame", payload, sig: signFrame(ed25519Keypair().privateKey, payload) });
  expect(await socket.closed).toBe(CLOSE.unauthorized);
  expect(h.messages).toEqual([]);
});

test("the same device connecting again closes its old socket 4102", async () => {
  const h = await host();
  const device = newDevice();
  h.allow(device);
  const first = (await dialDirect(device, h))!;
  const second = (await dialDirect(device, h))!;
  expect(await first.socket.closed).toBe(CLOSE.replaced);
  const sent = message("on the new one");
  second.socket.send(framed(device, second.session.seal(encodeEvent({ kind: "message", data: sent }))));
  expect(await second.socket.next()).toMatchObject({ type: "accepted" });
  expect(h.messages).toEqual([sent]);
});

test("a direct session that loses to a relay session is closed 4102", async () => {
  const h = await host();
  const device = newDevice();
  h.allow(device);
  const direct = (await dialDirect(device, h))!;
  await dialRelay(device, h);
  expect(await direct.socket.closed).toBe(CLOSE.replaced);
  expect(h.hub.direct().size).toBe(0);
});

test("a message over 1 MiB closes 4103", async () => {
  const h = await host();
  const device = newDevice();
  h.allow(device);
  const { socket } = (await dialDirect(device, h))!;
  socket.ws.send("x".repeat(MAX_FRAME_BYTES + 1));
  expect(await socket.closed).toBe(CLOSE.tooLarge);
});

test(`a ${MAX_PENDING + 1}th connection waiting for its handshake is refused, and a waiting one times out`, async () => {
  const h = await host({ pendingMs: 300 });
  const waiting = Array.from({ length: MAX_PENDING }, () => client(`ws://127.0.0.1:${h.port}`));
  cleanup.push(() => waiting.forEach((socket) => socket.ws.terminate()));
  await Promise.all(waiting.map((socket) => socket.open));
  const extra = client(`ws://127.0.0.1:${h.port}`);
  cleanup.push(() => extra.ws.terminate());
  expect(await extra.closed).toBe(CLOSE.unauthorized);
  expect(await waiting[0]!.closed).toBe(CLOSE.unauthorized);
});
