import { env, runInDurableObject, SELF } from "cloudflare:test";
import { afterEach, expect, test, vi } from "vitest";
import { MAX_DEVICES, NOTIFY_BODY } from "./protocol.js";
import * as apns from "./apns.js";
import type { Env } from "./worker.js";

/**
 * The Durable Object relay, exercised the way a client does: one websocket per device
 * through the Worker's router. Mirrors `index.test.ts`, which covers the Node relay.
 */

const ED25519 = { name: "Ed25519" } as const;

function toBase64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

interface Keys {
  pub: string;
  priv: CryptoKey;
}

async function keypair(): Promise<Keys> {
  const pair = (await crypto.subtle.generateKey(ED25519, true, ["sign", "verify"])) as CryptoKeyPair;
  const raw = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  return { pub: toBase64Url(raw), priv: pair.privateKey };
}

async function sign(data: string, keys: Keys): Promise<string> {
  const sig = await crypto.subtle.sign(ED25519, keys.priv, new TextEncoder().encode(data));
  return toBase64Url(new Uint8Array(sig));
}

async function roomId(pubkey: string): Promise<string> {
  const bin = atob(pubkey.replace(/-/g, "+").replace(/_/g, "/"));
  const digest = await crypto.subtle.digest(
    "SHA-256",
    Uint8Array.from(bin, (c) => c.charCodeAt(0)),
  );
  return toBase64Url(new Uint8Array(digest));
}

type Client = Awaited<ReturnType<typeof connect>>;

/** Minimal client: queue inbound JSON so callers can await messages in order. */
async function connect(room: string) {
  const response = await SELF.fetch(`https://relay.test/?room=${encodeURIComponent(room)}`, {
    headers: { Upgrade: "websocket" },
  });
  expect(response.status).toBe(101);
  const ws = response.webSocket!;
  const queue: any[] = [];
  const waiters: ((v: any) => void)[] = [];
  let closeCode: number | null = null;
  const closers: ((v: number) => void)[] = [];
  ws.addEventListener("message", (event: MessageEvent) => {
    const msg = JSON.parse(String(event.data));
    const waiter = waiters.shift();
    if (waiter) waiter(msg);
    else queue.push(msg);
  });
  ws.addEventListener("close", (event: CloseEvent) => {
    closeCode = event.code;
    for (const done of closers.splice(0)) done(event.code);
  });
  ws.accept();
  return {
    ws,
    send: (msg: unknown) => ws.send(JSON.stringify(msg)),
    next: (): Promise<any> =>
      queue.length > 0 ? Promise.resolve(queue.shift()!) : new Promise((r) => waiters.push(r)),
    closed: (): Promise<number> =>
      closeCode !== null ? Promise.resolve(closeCode) : new Promise((r) => closers.push(r)),
  };
}

async function connectMac(keys: Keys): Promise<Client> {
  const room = await roomId(keys.pub);
  const mac = await connect(room);
  const { nonce } = await mac.next();
  mac.send({ type: "register", pubkey: keys.pub, nonceSig: await sign(nonce, keys) });
  expect(await mac.next()).toMatchObject({ type: "registered", roomId: room });
  return mac;
}

async function mintToken(mac: Client): Promise<string> {
  mac.send({ type: "mint" });
  const { token } = await mac.next();
  return token as string;
}

async function connectPhone(room: string, token: string) {
  const keys = await keypair();
  const phone = await connect(room);
  await phone.next(); // nonce
  phone.send({
    type: "join",
    roomId: room,
    token,
    phonePubkey: keys.pub,
    sig: await sign(token, keys),
  });
  return { phone, keys };
}

/** Rejoins as a device the room already knows: no token, signature over the connect nonce. */
async function rejoinPhone(room: string, keys: Keys): Promise<Client> {
  const phone = await connect(room);
  const { nonce } = await phone.next();
  phone.send({ type: "join", roomId: room, phonePubkey: keys.pub, sig: await sign(nonce, keys) });
  return phone;
}

async function frame(client: Client, payload: string, keys: Keys): Promise<void> {
  client.send({ type: "frame", payload, sig: await sign(payload, keys) });
}

test("a plain GET answers without upgrading, and an upgrade needs a room", async () => {
  expect(await (await SELF.fetch("https://relay.test/")).text()).toBe("yorozu relay\n");
  const missing = await SELF.fetch("https://relay.test/", { headers: { Upgrade: "websocket" } });
  expect(missing.status).toBe(400);
});

test("forwards opaque frames in both directions", async () => {
  const macKeys = await keypair();
  const mac = await connectMac(macKeys);
  const token = await mintToken(mac);
  const { phone, keys: phoneKeys } = await connectPhone(await roomId(macKeys.pub), token);
  expect(await phone.next()).toMatchObject({ type: "joined", ownerOnline: true });

  await frame(phone, "Y2lwaGVydGV4dC1mcm9tLXBob25l", phoneKeys);
  expect(await mac.next()).toMatchObject({ type: "frame", payload: "Y2lwaGVydGV4dC1mcm9tLXBob25l" });

  await frame(mac, "Y2lwaGVydGV4dC1mcm9tLW1hYw", macKeys);
  expect(await phone.next()).toMatchObject({ type: "frame", payload: "Y2lwaGVydGV4dC1mcm9tLW1hYw" });
});

test("buffers frames while the mac is offline and drains them in order", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const token = await mintToken(mac);
  const { phone, keys: phoneKeys } = await connectPhone(room, token);
  await phone.next(); // joined

  mac.ws.close();
  expect(await phone.next()).toMatchObject({ type: "owner", online: false });

  const payloads = ["b25l", "dHdv", "dGhyZWU"];
  for (const payload of payloads) await frame(phone, payload, phoneKeys);

  const reconnected = await connectMac(macKeys);
  let last = -1;
  for (const payload of payloads) {
    const replayed = await reconnected.next();
    expect(replayed).toMatchObject({ type: "frame", payload });
    // Each replayed frame names its place in the buffer, which is what the ack refers to.
    expect(replayed.seq).toBe(last + 1);
    last = replayed.seq;
  }

  // Sent, not delivered: a Mac that goes away without acking sees the frames again, because
  // a send onto a socket that was about to die must not count.
  reconnected.ws.close();
  const again = await connectMac(macKeys);
  for (const payload of payloads) {
    expect(await again.next()).toMatchObject({ type: "frame", payload });
  }

  // Acked, and only then let go: the next registration replays nothing ahead of a live frame.
  again.send({ type: "ack", seq: last });
  again.ws.close();
  const third = await connectMac(macKeys);
  await frame(third, "bGF0ZXI", macKeys);
  // The phone also hears the owner go and come back around each Mac socket.
  let msg = await phone.next();
  while (msg.type === "owner") msg = await phone.next();
  expect(msg).toMatchObject({ type: "frame", payload: "bGF0ZXI" });
});

test("only the room's mac may ack, and a malformed ack closes the socket", async () => {
  const macKeys = await keypair();
  const mac = await connectMac(macKeys);
  const { phone } = await connectPhone(await roomId(macKeys.pub), await mintToken(mac));
  await phone.next(); // joined

  phone.send({ type: "ack", seq: 0 });
  expect(await phone.closed()).toBe(4001);
  mac.send({ type: "ack", seq: "zero" });
  expect(await mac.closed()).toBe(4001);
});

test("join tokens are one-time", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const token = await mintToken(mac);

  const { phone } = await connectPhone(room, token);
  expect(await phone.next()).toMatchObject({ type: "joined" });

  const replay = await connectPhone(room, token);
  expect(await replay.phone.closed()).toBe(4001);
});

test("a known device rejoins against the nonce, with no second token", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const { phone, keys } = await connectPhone(room, await mintToken(mac));
  expect(await phone.next()).toMatchObject({ type: "joined" });

  // The room remembers the device in storage, so the rejoin does not wait on the old socket.
  phone.ws.close();

  const again = await rejoinPhone(room, keys);
  expect(await again.next()).toMatchObject({ type: "joined", ownerOnline: true });

  // And it is a real join: frames flow without pairing again.
  await frame(again, "YWZ0ZXItcmVqb2lu", keys);
  expect(await mac.next()).toMatchObject({ type: "frame", payload: "YWZ0ZXItcmVqb2lu" });
});

test("a revoked device is dropped and cannot rejoin", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const { phone, keys } = await connectPhone(room, await mintToken(mac));
  expect(await phone.next()).toMatchObject({ type: "joined" });

  // The Mac unpairs it: the live socket goes, and the nonce rejoin it used to be allowed
  // to make is refused.
  mac.send({ type: "revoke", pubkey: keys.pub });
  expect(await phone.closed()).toBe(4001);

  const again = await rejoinPhone(room, keys);
  expect(await again.closed()).toBe(4001);
});

test("only the room's mac may revoke, and a malformed revoke closes the socket", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);

  const stranger = await connect(room);
  await stranger.next(); // nonce
  stranger.send({ type: "revoke", pubkey: (await keypair()).pub });
  expect(await stranger.closed()).toBe(4001);

  mac.send({ type: "revoke" });
  expect(await mac.closed()).toBe(4001);
});

test("rejects a nonce join from a pubkey the room does not know", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  await connectMac(macKeys);

  const stranger = await rejoinPhone(room, await keypair());
  expect(await stranger.closed()).toBe(4001);
});

test("a nonce join must be signed by the device it names", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const { phone, keys } = await connectPhone(room, await mintToken(mac));
  await phone.next(); // joined

  const impostor = await connect(room);
  await impostor.next(); // nonce
  // The known pubkey, but signed with somebody else's key over somebody else's nonce.
  impostor.send({
    type: "join",
    roomId: room,
    phonePubkey: keys.pub,
    sig: await sign("not the nonce", await keypair()),
  });
  expect(await impostor.closed()).toBe(4003);
});

test("rejects a registration with a bad challenge signature", async () => {
  const keys = await keypair();
  const mac = await connect(await roomId(keys.pub));
  await mac.next(); // nonce
  mac.send({ type: "register", pubkey: keys.pub, nonceSig: await sign("wrong", keys) });
  expect(await mac.closed()).toBe(4003);
});

test("a key may only register in its own room", async () => {
  const keys = await keypair();
  const squatter = await connect(await roomId((await keypair()).pub));
  const { nonce } = await squatter.next();
  squatter.send({ type: "register", pubkey: keys.pub, nonceSig: await sign(nonce, keys) });
  expect(await squatter.closed()).toBe(4001);
});

test("rejects a join signed by the wrong key", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const token = await mintToken(mac);

  const phone = await connect(room);
  await phone.next(); // nonce
  const wrong = await keypair();
  phone.send({
    type: "join",
    roomId: room,
    token,
    phonePubkey: (await keypair()).pub,
    sig: await sign(token, wrong),
  });
  expect(await phone.closed()).toBe(4003);

  // The failed join must not have burned the token.
  const retry = await connectPhone(room, token);
  expect(await retry.phone.next()).toMatchObject({ type: "joined" });
});

test("drops unsigned and mis-signed frames with a close code", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const { phone, keys: phoneKeys } = await connectPhone(room, await mintToken(mac));
  await phone.next(); // joined

  phone.send({ type: "frame", payload: "dW5zaWduZWQ=" });
  expect(await phone.closed()).toBe(4003);

  const second = await connectPhone(room, await mintToken(mac));
  await second.phone.next(); // joined
  second.phone.send({ type: "frame", payload: "dGFtcGVyZWQ", sig: await sign("else", phoneKeys) });
  expect(await second.phone.closed()).toBe(4003);
});

test("rate limits frames per room", async () => {
  const macKeys = await keypair();
  const mac = await connectMac(macKeys);
  const { phone, keys: phoneKeys } = await connectPhone(
    await roomId(macKeys.pub),
    await mintToken(mac),
  );
  await phone.next(); // joined

  const payload = "Zmxvb2Q";
  const sig = await sign(payload, phoneKeys);
  for (let i = 0; i < 80; i++) phone.send({ type: "frame", payload, sig });
  expect(await phone.closed()).toBe(4029);
});

test("tells phones whether the room's mac is online", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const { phone } = await connectPhone(room, await mintToken(mac));
  expect(await phone.next()).toMatchObject({ type: "joined", ownerOnline: true });

  mac.ws.close();
  expect(await phone.next()).toMatchObject({ type: "owner", online: false });

  await connectMac(macKeys);
  expect(await phone.next()).toMatchObject({ type: "owner", online: true });
});

test("a mis-typed message closes the socket", async () => {
  const client = await connect("anything");
  await client.next(); // nonce
  client.send({ type: "nope" });
  expect(await client.closed()).toBe(4001);
});

test("answers the heartbeat without a close, so an idle socket can stay open", async () => {
  const macKeys = await keypair();
  const mac = await connectMac(macKeys);

  // `setWebSocketAutoResponse` answers this at the edge so the room is never woken. The test
  // pool runs the object in-process, where the handler answers it instead; either way the
  // client sees a pong, and — the point of the test — the socket is not closed for an
  // "unknown type".
  mac.send({ type: "ping" });
  expect(await mac.next()).toMatchObject({ type: "pong" });

  // Still a working, registered socket afterwards.
  mac.send({ type: "mint" });
  expect(await mac.next()).toMatchObject({ type: "token" });
});

test("the auto-response pair is what answers a ping, and leaves presence alone", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const { phone } = await connectPhone(room, await mintToken(mac));
  expect(await phone.next()).toMatchObject({ type: "joined", ownerOnline: true });

  // A heartbeat from either end is not traffic the other end should ever see.
  mac.send({ type: "ping" });
  expect(await mac.next()).toMatchObject({ type: "pong" });
  phone.send({ type: "ping" });
  expect(await phone.next()).toMatchObject({ type: "pong" });

  // And the Mac is still the room's owner as far as a new phone is concerned.
  const second = await connectPhone(room, await mintToken(mac));
  expect(await second.phone.next()).toMatchObject({ type: "joined", ownerOnline: true });
});

test("presence survives hibernation: it is read off the live sockets, not remembered", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const token = await mintToken(mac);

  // What hibernation takes away is the instance: its fields, its closures, everything but the
  // sockets and their attachments. So the check that the answer survives it is that the answer
  // is computed from those — reach into the object and read the only state presence can come
  // from. A `role: "mac"` in a surviving attachment is the whole of "the Mac is online".
  // `cloudflare:test` types `env` from a declaration the test suite would otherwise have to
  // carry a whole file for; the bindings are the Worker's own, so say so here instead.
  const rooms = (env as unknown as Env).ROOM;
  const id = rooms.idFromName(room);
  await runInDurableObject(rooms.get(id), async (_room, state) => {
    const roles = state.getWebSockets().map((ws) => (ws.deserializeAttachment() as any)?.role);
    expect(roles).toContain("mac");
  });

  const { phone } = await connectPhone(room, token);
  expect(await phone.next()).toMatchObject({ type: "joined", ownerOnline: true });

  // The explicit query answers from that same live set, so a phone that has been asleep and
  // cannot trust what it last heard has a way to ask rather than guess.
  phone.send({ type: "owner" });
  expect(await phone.next()).toMatchObject({ type: "owner", online: true });

  // And it tracks the truth rather than a cached flag: with the Mac's socket gone, so is the
  // attachment it was read from, and the same question answers false.
  mac.ws.close();
  expect(await phone.next()).toMatchObject({ type: "owner", online: false });
  phone.send({ type: "owner" });
  expect(await phone.next()).toMatchObject({ type: "owner", online: false });

  await runInDurableObject(rooms.get(id), async (_room, state) => {
    const roles = state.getWebSockets().map((ws) => (ws.deserializeAttachment() as any)?.role);
    expect(roles).not.toContain("mac");
  });
});

test("only a joined phone may ask about presence", async () => {
  const stranger = await connect("some-room");
  await stranger.next(); // nonce
  stranger.send({ type: "owner" });
  expect(await stranger.closed()).toBe(4001);
});

test("an announced device may rejoin, so storage this room lost comes back", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const phoneKeys = await keypair();

  // Nothing has ever paired here: the rejoin is refused until the Mac says otherwise.
  expect(await (await rejoinPhone(room, phoneKeys)).closed()).toBe(4001);

  mac.send({ type: "devices", devices: [phoneKeys.pub] });
  const phone = await rejoinPhone(room, phoneKeys);
  expect(await phone.next()).toMatchObject({ type: "joined", roomId: room });
});

test("a shorter announced list drops the devices missing from it", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const [gone, kept] = [await keypair(), await keypair()];
  mac.send({ type: "devices", devices: [gone.pub, kept.pub] });

  // The Mac's list is the source of truth, so a key absent from the next one is unpaired.
  mac.send({ type: "devices", devices: [kept.pub] });
  expect(await (await rejoinPhone(room, gone)).closed()).toBe(4001);
  expect(await (await rejoinPhone(room, kept)).next()).toMatchObject({ type: "joined" });
});

test("an announce that has not caught up yet leaves a connected device alone", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const { phone, keys } = await connectPhone(room, await mintToken(mac));
  expect(await phone.next()).toMatchObject({ type: "joined" });

  // The phone has just spent its token and the Mac is still being told about it, so an
  // announce that predates the news must not unpair it. `revoke` is what does that.
  mac.send({ type: "devices", devices: [] });
  mac.send({ type: "mint" });
  await mac.next(); // the token, which the room only answers once the announce is done with

  expect(await (await rejoinPhone(room, keys)).next()).toMatchObject({ type: "joined" });
});

test("an announced list past the cap keeps the last MAX_DEVICES of it", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const announced = await Promise.all(Array.from({ length: MAX_DEVICES + 1 }, () => keypair()));
  mac.send({ type: "devices", devices: announced.map(({ pub }) => pub) });

  // The first one announced is the one over the cap; the last is inside it.
  expect(await (await rejoinPhone(room, announced[0]!)).closed()).toBe(4001);
  expect(await (await rejoinPhone(room, announced.at(-1)!)).next()).toMatchObject({
    type: "joined",
  });
});

test("only the room's mac may announce devices, and a malformed list closes the socket", async () => {
  const macKeys = await keypair();
  const mac = await connectMac(macKeys);

  const stranger = await connect(await roomId(macKeys.pub));
  await stranger.next(); // nonce
  stranger.send({ type: "devices", devices: [] });
  expect(await stranger.closed()).toBe(4001);

  mac.send({ type: "devices", devices: [1] });
  expect(await mac.closed()).toBe(4001);
});

/**
 * The push side. Everything below stands a fake APNs in front of the room and reads what it was
 * sent — which is the only way to check the promise that matters: that a wake-up carries a class
 * and an opaque reference and nothing whatsoever from the conversation.
 */

type Call = { url: string; headers: Headers; body: any };

/**
 * Stands a fake APNs in front of the room and records every push it makes. The Apple key and
 * the host are real bindings — see vitest.config.ts — because a Durable Object is handed its
 * env by the runtime and never sees one a test assigned to.
 *
 * `status` is what Apple answers with, which is how the dead-token path is exercised.
 */
function fakeApns(status: () => number = () => 200): Call[] {
  // Another test's cached JWT would be signed by the same key, but the cache is per isolate
  // and a test that asserts on minting must start from nothing.
  apns.resetToken();
  const calls: Call[] = [];
  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({
      url: String(input),
      headers: new Headers(init?.headers),
      body: JSON.parse(String(init?.body)),
    });
    return new Response(null, { status: status() });
  });
  return calls;
}

afterEach(() => {
  vi.unstubAllGlobals();
  apns.resetToken();
});

/**
 * Waits for everything already sent to have been handled. Messages are handled in order on the
 * room, so an answer to a later question means the earlier ones are done with.
 *
 * Two of them, because the question has to be one the asker is allowed to ask: a phone asks
 * about presence, and a mac asks for a token.
 */
async function settled(phone: Client): Promise<void> {
  phone.send({ type: "owner" });
  await phone.next();
}

async function macSettled(mac: Client): Promise<void> {
  mac.send({ type: "mint" });
  await mac.next();
}

/** A mac, a phone that has registered for pushes, and the room they share. */
async function paired() {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const { phone, keys } = await connectPhone(room, await mintToken(mac));
  await phone.next(); // joined
  phone.send({ type: "push", deviceToken: "device-token" });
  await settled(phone);
  return { mac, macKeys, phone, keys, room };
}

const record = async (room: string, pubkey: string): Promise<any> => {
  const rooms = (env as unknown as Env).ROOM;
  return await runInDurableObject(rooms.get(rooms.idFromName(room)), async (_room, state) =>
    state.storage.get(`push:${pubkey}`),
  );
};

test("a phone registers where it can be woken, and revoking it takes the token with it", async () => {
  const { mac, phone, keys, room } = await paired();

  expect(await record(room, keys.pub)).toEqual({ deviceToken: "device-token" });

  // Re-registering is what a phone does on every launch, and the newest token wins.
  phone.send({ type: "push", deviceToken: "device-token-2" });
  await settled(phone);
  expect(await record(room, keys.pub)).toEqual({ deviceToken: "device-token-2" });

  // And the whole registration goes when the Mac unpairs the device: a revoked phone is not
  // woken again, which is the entire point of revoking it.
  mac.send({ type: "revoke", pubkey: keys.pub });
  expect(await phone.closed()).toBe(4001);
  expect(await record(room, keys.pub)).toBeUndefined();
});

test("only a joined phone may register, and only the mac may notify", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);

  const stranger = await connect(room);
  await stranger.next(); // nonce
  stranger.send({ type: "push", deviceToken: "d" });
  expect(await stranger.closed()).toBe(4001);

  const second = await connect(room);
  await second.next(); // nonce
  second.send({ type: "notify", class: "reply", threadRef: "r" });
  expect(await second.closed()).toBe(4001);

  // And a malformed one closes the socket rather than being quietly ignored.
  mac.send({ type: "notify", class: "gossip", threadRef: "r" });
  expect(await mac.closed()).toBe(4001);
});

test("a phone holding a live socket still gets an alert but no background wake", async () => {
  const calls = fakeApns();
  const { mac, phone } = await paired();

  // iOS may suspend without promptly closing this socket. Always send the alert; the app's
  // foreground delegate suppresses presentation when somebody is already watching.
  mac.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);
  expect(calls).toHaveLength(1);
  expect(calls[0]!.headers.get("apns-push-type")).toBe("alert");

  // With the socket gone there is nobody watching, so the same notify adds a silent catch-up
  // push behind the visible alert.
  phone.ws.close();
  mac.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);
  expect(calls).toHaveLength(3);
  expect(calls.slice(1).map((call) => call.headers.get("apns-push-type"))).toEqual(["alert", "background"]);
});

test("a wake-up carries a class and an opaque reference, and nothing of the conversation", async () => {
  const calls = fakeApns();
  const { mac, phone } = await paired();
  phone.ws.close();

  mac.send({ type: "notify", class: "approval", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);

  const call = calls[0]!;
  expect(call.url).toBe("https://apns.test/3/device/device-token");
  expect(call.headers.get("apns-topic")).toBe("to.yumi.yorozu.ios");
  expect(call.headers.get("apns-push-type")).toBe("alert");
  expect(call.body.aps.alert).toEqual({ title: "Yorozu", "loc-key": NOTIFY_BODY.approval });
  expect(call.body.ref).toBe("Ab3-_x9Z");

  // The payload's whole vocabulary, spelled out. Anything the runtime could have leaked would
  // have to appear here, and there is nowhere for it to appear.
  expect(Object.keys(call.body)).toEqual(["aps", "ref", "cls"]);
  expect(JSON.stringify(call.body)).toBe(
    JSON.stringify({
      aps: {
        alert: { title: "Yorozu", "loc-key": NOTIFY_BODY.approval },
        sound: "default",
        "thread-id": "Ab3-_x9Z",
      },
      ref: "Ab3-_x9Z",
      cls: "approval",
    }),
  );

  // The auth token is a signed ES256 JWT naming the key, and it is minted once and reused.
  const auth = call.headers.get("authorization")!;
  expect(auth.startsWith("bearer ")).toBe(true);
  const [head, body, sig] = auth.slice("bearer ".length).split(".");
  expect(JSON.parse(atob(head!))).toEqual({ alg: "ES256", kid: "KEY123456" });
  expect(JSON.parse(atob(body!)).iss).toBe("TEAM12345");
  expect(sig).toBeTruthy();
  // Never the key itself, anywhere.
  expect(auth).not.toContain("PRIVATE KEY");

  mac.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);
  expect(calls[1]!.headers.get("authorization")).toBe(auth);
});

test("a wake-up selects only its device's encrypted preview", async () => {
  const calls = fakeApns();
  const { mac, phone, keys } = await paired();
  phone.ws.close();
  const own = { n: "B".repeat(16), c: "C".repeat(22) };
  mac.send({
    type: "notify",
    class: "reply",
    threadRef: "Ab3-_x9Z",
    previews: { [keys.pub]: own, ["D".repeat(43)]: { n: "E".repeat(16), c: "F".repeat(22) } },
  });
  await macSettled(mac);

  expect(calls[0]!.body.preview).toEqual(own);
  expect(calls[0]!.body.aps["mutable-content"]).toBe(1);
  expect(JSON.stringify(calls[0]!.body)).not.toContain("secret reply");
});

test("a device token Apple no longer knows is forgotten rather than retried", async () => {
  const calls = fakeApns(() => 410);
  const { mac, phone, keys, room } = await paired();
  phone.ws.close();

  mac.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);
  expect(calls).toHaveLength(1);
  expect(await record(room, keys.pub)).toBeUndefined();

  // Nothing left to push to, so the next turn does not try.
  mac.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);
  expect(calls).toHaveLength(1);
});

test("one APNs network failure does not block another phone", async () => {
  apns.resetToken();
  const calls: string[] = [];
  vi.stubGlobal("fetch", async (input: RequestInfo | URL) => {
    calls.push(String(input));
    if (calls.length === 1) throw new Error("network down for first phone");
    return new Response(null, { status: 200 });
  });
  const { mac, phone, room } = await paired();
  const second = await connectPhone(room, await mintToken(mac));
  await second.phone.next();
  second.phone.send({ type: "push", deviceToken: "device-token-2" });
  await settled(second.phone);
  phone.ws.close();
  second.phone.ws.close();

  mac.send({ type: "notify", class: "approval", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);

  expect(calls).toHaveLength(2);
  expect(new Set(calls.map((url) => url.split("/").at(-1)))).toEqual(
    new Set(["device-token", "device-token-2"]),
  );
});

test("a wake-up also nudges the app awake, at most once a minute", async () => {
  const calls = fakeApns();
  const { mac, phone, keys, room } = await paired();
  phone.ws.close();

  mac.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);

  expect(calls).toHaveLength(2);
  const silent = calls[1]!;
  expect(silent.url).toBe("https://apns.test/3/device/device-token");
  // The app's own topic, not the activity's, and explicitly not urgent — Apple rejects a
  // background push that claims to be.
  expect(silent.headers.get("apns-topic")).toBe("to.yumi.yorozu.ios");
  expect(silent.headers.get("apns-push-type")).toBe("background");
  expect(silent.headers.get("apns-priority")).toBe("5");
  // `content-available` and nothing else. There is no reference and no class in here: the app
  // is being sent to ask over its own socket, not being told what happened. Anything the
  // runtime could have leaked would have to appear here, and there is nowhere for it to.
  expect(silent.body).toEqual({ aps: { "content-available": 1 } });
  expect(JSON.stringify(silent.body)).toBe(JSON.stringify({ aps: { "content-available": 1 } }));

  // The budget is per phone per minute, so the next turn still buzzes and does not wake it.
  mac.send({ type: "notify", class: "done", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);
  expect(calls).toHaveLength(3);
  expect(calls[2]!.headers.get("apns-push-type")).toBe("alert");

  // A minute later it is allowed again. Rewinding the recorded timestamp is the same thing as
  // waiting out the minute, without asking the clock to move under a running Durable Object.
  const rooms = (env as unknown as Env).ROOM;
  await runInDurableObject(rooms.get(rooms.idFromName(room)), async (_room, state) => {
    const stored = (await state.storage.get(`push:${keys.pub}`)) as Record<string, unknown>;
    await state.storage.put(`push:${keys.pub}`, { ...stored, backgroundAt: Date.now() - 61_000 });
  });

  mac.send({ type: "notify", class: "failed", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);
  expect(calls).toHaveLength(5);
  expect(calls[4]!.headers.get("apns-push-type")).toBe("background");
});

test("an approval buzzes without waking the app: it is a question, not history", async () => {
  const calls = fakeApns();
  const { mac, phone } = await paired();
  phone.ws.close();

  // Nothing to catch up on — the answer is given in the app, by a person who has come to it.
  mac.send({ type: "notify", class: "approval", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);
  expect(calls).toHaveLength(1);
  expect(calls[0]!.headers.get("apns-push-type")).toBe("alert");
});
