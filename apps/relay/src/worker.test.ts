/// <reference types="@cloudflare/vitest-pool-workers/types" />

import { env, runInDurableObject, SELF } from "cloudflare:test";
import { afterEach, expect, test, vi } from "vitest";
import { AUTH_TIMEOUT_MS, CLOSE_POLICY, MAX_DEVICES, NOTIFY_BODY, type Notify } from "./protocol.js";
import * as apns from "./apns.js";
import { Room, type Env } from "./worker.js";
import { conformance, fakeRoom } from "./conformance.test.js";

/**
 * The Durable Object relay, exercised the way a client does: one websocket per device
 * through the Worker's router. The wire protocol is covered by the shared conformance suite;
 * only what is the Durable Object's alone — alarms, hibernation, APNs — lives here.
 */

const ED25519 = { name: "Ed25519" } as const;
const DEVICE_TOKEN = "a".repeat(64);
const SECOND_DEVICE_TOKEN = "b".repeat(64);
const REPLACEMENT_TOKEN = "c".repeat(64);

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
    raw: (text: string) => ws.send(text),
    close: (code?: number, reason?: string) => ws.close(code, reason),
    next: (): Promise<any> =>
      queue.length > 0 ? Promise.resolve(queue.shift()!) : new Promise((r) => waiters.push(r)),
    closed: (): Promise<number> =>
      closeCode !== null ? Promise.resolve(closeCode) : new Promise((r) => closers.push(r)),
  };
}

const room = (name: string) => {
  const rooms = (env as unknown as Env).ROOM;
  return rooms.get(rooms.idFromName(name));
};

conformance({
  keypair: async () => {
    const keys = await keypair();
    return { pub: keys.pub, sign: (data) => sign(data, keys) };
  },
  roomId,
  connect,
  // The object reads `Date.now()` in workerd, out of reach of a fake clock: age every token
  // in storage by the same amount instead.
  advance: (name, ms) =>
    runInDurableObject(room(name), async (_room, state) => {
      const tokens = await state.storage.list<number>({ prefix: "t:" });
      for (const [key, expiresAt] of tokens) await state.storage.put(key, expiresAt - ms);
    }),
});

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

async function frame(client: Client, payload: string, keys: Keys): Promise<void> {
  client.send({ type: "frame", payload, sig: await sign(payload, keys) });
}

test("a plain GET answers without upgrading, and an upgrade needs a room", async () => {
  expect(await (await SELF.fetch("https://relay.test/")).text()).toBe("yorozu relay\n");
  const missing = await SELF.fetch("https://relay.test/", { headers: { Upgrade: "websocket" } });
  expect(missing.status).toBe(400);
});

test.each([
  "short",
  "A".repeat(42),
  "A".repeat(44),
  "A".repeat(42) + "=",
  "A".repeat(42) + "+",
  "A".repeat(42) + "/",
  "A".repeat(42) + " ",
])("a room that no key could hash to is refused before any object is touched (%s)", async (room) => {
  const rooms = (env as unknown as Env).ROOM;
  const named = vi.spyOn(rooms, "idFromName");
  try {
    const response = await SELF.fetch(`https://relay.test/?room=${encodeURIComponent(room)}`, {
      headers: { Upgrade: "websocket" },
    });
    expect(response.status).toBe(400);
    expect(await response.text()).toBe("bad ?room");
    expect(named).not.toHaveBeenCalled();
  } finally {
    named.mockRestore();
  }
});

test("a socket that never registers or joins is closed at the auth deadline", async () => {
  const name = fakeRoom("auth-timeout");
  const stranger = await connect(name);
  await stranger.next(); // nonce
  // Accepting the socket scheduled a sweep for its deadline, so hibernation cannot lose it.
  await runInDurableObject(room(name), async (instance, state) => {
    const alarm = await state.storage.getAlarm();
    expect(alarm).not.toBeNull();
    expect(alarm! - Date.now()).toBeLessThanOrEqual(AUTH_TIMEOUT_MS);
    // Before the deadline the sweep leaves it alone.
    await (instance as unknown as { alarm(): Promise<void> }).alarm();
    expect(state.getWebSockets()).toHaveLength(1);
    // The clock cannot be moved under workerd, so the socket's own record of when it arrived
    // is aged instead — the same thing the alarm would see ten seconds from now.
    const socket = state.getWebSockets()[0]!;
    const conn = socket.deserializeAttachment() as Record<string, unknown>;
    socket.serializeAttachment({ ...conn, since: Date.now() - AUTH_TIMEOUT_MS });
    await (instance as unknown as { alarm(): Promise<void> }).alarm();
  });
  expect(await stranger.closed()).toBe(CLOSE_POLICY);
});

test("a socket that registered in time survives the auth sweep", async () => {
  const keys = await keypair();
  const name = await roomId(keys.pub);
  const mac = await connectMac(keys);
  await runInDurableObject(room(name), async (instance, state) => {
    const socket = state.getWebSockets()[0]!;
    const conn = socket.deserializeAttachment() as Record<string, unknown>;
    socket.serializeAttachment({ ...conn, since: Date.now() - AUTH_TIMEOUT_MS });
    await (instance as unknown as { alarm(): Promise<void> }).alarm();
    expect(state.getWebSockets()).toHaveLength(1);
  });
  mac.send({ type: "ping" });
  expect(await mac.next()).toEqual({ type: "pong" });
});

test("a key may only register in its own room", async () => {
  const keys = await keypair();
  const squatter = await connect(await roomId((await keypair()).pub));
  const { nonce } = await squatter.next();
  squatter.send({ type: "register", pubkey: keys.pub, nonceSig: await sign(nonce, keys) });
  expect(await squatter.closed()).toBe(4001);
});

test("a used or expired join token is swept by the alarm, and a live one is kept", async () => {
  const macKeys = await keypair();
  const room = await roomId(macKeys.pub);
  const mac = await connectMac(macKeys);
  const stale = await mintToken(mac);
  const live = await mintToken(mac);

  const rooms = (env as unknown as Env).ROOM;
  const stub = rooms.get(rooms.idFromName(room));
  await runInDurableObject(stub, async (instance, state) => {
    // Minting scheduled the sweep for when the first token expires.
    expect(await state.storage.getAlarm()).not.toBeNull();
    await state.storage.put(`t:${stale}`, Date.now() - 1);
    await (instance as unknown as { alarm(): Promise<void> }).alarm();
    expect(await state.storage.get(`t:${stale}`)).toBeUndefined();
    expect(await state.storage.get(`t:${live}`)).toBeGreaterThan(Date.now());
    // The live token still has a sweep coming for it.
    expect(await state.storage.getAlarm()).not.toBeNull();
  });

  expect(await (await connectPhone(room, stale)).phone.closed()).toBe(4001);
  expect(await (await connectPhone(room, live)).phone.next()).toMatchObject({ type: "joined" });
});

test("heartbeats answer without changing presence", async () => {
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
 * `status` is what Apple answers with, by URL, which is how the dead-token and wrong-environment
 * paths are exercised: a 400 here is always Apple's `BadDeviceToken`.
 */
function fakeApns(status: (url: string) => number = () => 200): Call[] {
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
    const code = status(String(input));
    return new Response(code === 400 ? JSON.stringify({ reason: "BadDeviceToken" }) : null, {
      status: code,
    });
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
  phone.send({ type: "push", deviceToken: DEVICE_TOKEN });
  await settled(phone);
  return { mac, macKeys, phone, keys, room };
}

const record = async (room: string, pubkey: string): Promise<any> => {
  const rooms = (env as unknown as Env).ROOM;
  return await runInDurableObject(rooms.get(rooms.idFromName(room)), async (_room, state) =>
    state.storage.get(`push:${pubkey}`),
  );
};

// Keep the wake's completion observable while real socket messages change its registration.
const wake = (name: string) => runInDurableObject(room(name), (instance) =>
  (instance as unknown as { wake(notify: Notify, now: number): Promise<void> }).wake(
    { class: "reply", threadRef: "Ab3-_x9Z" }, Date.now(),
  ),
);

test("a phone registers where it can be woken, and revoking it takes the token with it", async () => {
  const { mac, phone, keys, room } = await paired();

  expect(await record(room, keys.pub)).toEqual({ deviceToken: DEVICE_TOKEN });

  // Re-registering is what a phone does on every launch, and the newest token wins.
  phone.send({ type: "push", deviceToken: SECOND_DEVICE_TOKEN });
  await settled(phone);
  expect(await record(room, keys.pub)).toEqual({ deviceToken: SECOND_DEVICE_TOKEN });

  // And the whole registration goes when the Mac unpairs the device: a revoked phone is not
  // woken again, which is the entire point of revoking it.
  mac.send({ type: "revoke", pubkey: keys.pub });
  expect(await phone.closed()).toBe(4001);
  expect(await record(room, keys.pub)).toBeUndefined();
});

test("evicting the oldest device removes its push registration and socket", async () => {
  const { mac, phone, keys, room: name } = await paired();
  await runInDurableObject(room(name), async (_instance, state) => {
    await state.storage.put(`p:${keys.pub}`, 0);
    for (let i = 1; i < MAX_DEVICES; i++) await state.storage.put(`p:known-${i}`, i);
  });

  const next = await connectPhone(name, await mintToken(mac));
  expect(await next.phone.next()).toMatchObject({ type: "joined" });
  expect(await record(name, keys.pub)).toBeUndefined();
  expect(await phone.closed()).toBe(4001);
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
  expect(call.url).toBe(`https://apns.test/3/device/${DEVICE_TOKEN}`);
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
        // Which buttons the phone draws: a fixed name, not a word about the action.
        category: "approval-review",
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
  second.phone.send({ type: "push", deviceToken: SECOND_DEVICE_TOKEN });
  await settled(second.phone);
  phone.ws.close();
  second.phone.ws.close();

  mac.send({ type: "notify", class: "approval", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);

  // The first phone's alert failed, which costs it its silent wake too; the second phone
  // gets both. Three calls, and both tokens were tried.
  expect(calls).toHaveLength(3);
  expect(new Set(calls.map((url) => url.split("/").at(-1)))).toEqual(
    new Set([DEVICE_TOKEN, SECOND_DEVICE_TOKEN]),
  );
});

test("an APNs request that never answers does not delay the next frame", async () => {
  apns.resetToken();
  const pending: string[] = [];
  vi.stubGlobal("fetch", (input: RequestInfo | URL) => {
    pending.push(String(input));
    return new Promise<Response>(() => {}); // Apple, hanging.
  });
  const { mac, macKeys, phone } = await paired();

  mac.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  await frame(mac, "cmlnaHQtYmVoaW5k", macKeys);
  // The frame lands while the push is still outstanding: the wake ran off the chain.
  expect(await phone.next()).toMatchObject({ type: "frame", payload: "cmlnaHQtYmVoaW5k" });
  expect(pending).toHaveLength(1);
});

test.each([200, 410])("an old APNs response (%i) cannot change a replacement token", async (status) => {
  const { mac, phone, keys, room: name } = await paired();
  let complete!: (response: Response) => void;
  vi.stubGlobal("fetch", async (input: RequestInfo | URL) => {
    if (String(input).startsWith("https://apns.test/")) {
      return new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 });
    }
    return new Promise<Response>((resolve) => { complete = resolve; });
  });
  const pending = wake(name);
  await vi.waitFor(() => expect(complete).toBeTypeOf("function"));
  phone.send({ type: "push", deviceToken: REPLACEMENT_TOKEN });
  await settled(phone);
  // Workerd requires deferred I/O to complete in the Durable Object that owns it.
  await runInDurableObject(room(name), () => complete(new Response(null, { status })));
  await pending;

  expect(await record(name, keys.pub)).toEqual({ deviceToken: REPLACEMENT_TOKEN });
  await macSettled(mac);
});

test("a background response cannot restore a revoked registration", async () => {
  const { mac, phone, keys, room: name } = await paired();
  phone.close();
  await macSettled(mac);
  let complete!: (response: Response) => void;
  vi.stubGlobal("fetch", async (_input: RequestInfo | URL, init?: RequestInit) => {
    if (new Headers(init?.headers).get("apns-push-type") === "background") {
      return new Promise<Response>((resolve) => { complete = resolve; });
    }
    return new Response(null, { status: 200 });
  });
  const pending = wake(name);
  await vi.waitFor(() => expect(complete).toBeTypeOf("function"));
  mac.send({ type: "revoke", pubkey: keys.pub });
  await macSettled(mac);
  expect(await record(name, keys.pub)).toBeUndefined();
  await runInDurableObject(room(name), () => complete(new Response(null, { status: 200 })));
  await pending;

  expect(await record(name, keys.pub)).toBeUndefined();
});

test("overlapping notifications share one in-flight background wake", async () => {
  const { mac, phone, room: name } = await paired();
  phone.close();
  await macSettled(mac);
  let complete!: (response: Response) => void;
  const pushes: string[] = [];
  vi.stubGlobal("fetch", async (_input: RequestInfo | URL, init?: RequestInit) => {
    const kind = new Headers(init?.headers).get("apns-push-type")!;
    pushes.push(kind);
    if (kind === "background" && !complete) {
      return new Promise<Response>((resolve) => { complete = resolve; });
    }
    return new Response(null, { status: 200 });
  });
  const pending = wake(name);
  await vi.waitFor(() => expect(complete).toBeTypeOf("function"));
  await wake(name);
  await runInDurableObject(room(name), () => complete(new Response(null, { status: 200 })));
  await pending;

  expect(pushes).toEqual(["alert", "background", "alert"]);
});

test("the silent-push budget is spent only when apple accepted the push", async () => {
  // The alert is fine; the background push fails at Apple.
  apns.resetToken();
  let background = 0;
  vi.stubGlobal("fetch", async (_input: RequestInfo | URL, init?: RequestInit) => {
    if (new Headers(init?.headers).get("apns-push-type") === "background") {
      background++;
      return new Response(null, { status: 503 });
    }
    return new Response(null, { status: 200 });
  });
  const { mac, phone, keys, room } = await paired();
  phone.ws.close();

  mac.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);
  await vi.waitFor(() => expect(background).toBe(1));
  expect(await record(room, keys.pub)).not.toHaveProperty("backgroundAt");

  // Not charged for a wake that never happened, so the very next notify tries again.
  mac.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);
  await vi.waitFor(() => expect(background).toBe(2));
});

test("a wake-up also nudges the app awake, at most once a minute", async () => {
  const calls = fakeApns();
  const { mac, phone, keys, room } = await paired();
  phone.ws.close();

  mac.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);

  expect(calls).toHaveLength(2);
  const silent = calls[1]!;
  expect(silent.url).toBe(`https://apns.test/3/device/${DEVICE_TOKEN}`);
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

test("an approval buzzes and wakes the app, so the card is cached before a button is pressed", async () => {
  const calls = fakeApns();
  const { mac, phone } = await paired();
  phone.ws.close();

  mac.send({ type: "notify", class: "approval", threadRef: "Ab3-_x9Z", actions: true });
  await macSettled(mac);
  expect(calls).toHaveLength(2);
  expect(calls[0]!.headers.get("apns-push-type")).toBe("alert");
  // The Mac's one bit becomes the category the phone draws buttons for; nothing else of the
  // action is in the payload.
  expect(calls[0]!.body.aps.category).toBe("approval-quick");
  expect(calls[1]!.headers.get("apns-push-type")).toBe("background");
});

test("a token production APNs refuses as bad is retried through sandbox, and that is remembered", async () => {
  // An Xcode-signed build registers a sandbox token, and the phone has no way to say so.
  const calls = fakeApns((url) => (url.startsWith("https://apns.test/") ? 400 : 200));
  const { mac, phone, keys, room } = await paired();
  const hosts = () => calls.map((call) => new URL(call.url).host);

  mac.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);
  expect(hosts()).toEqual(["apns.test", "apns-sandbox.test"]);
  expect(await record(room, keys.pub)).toMatchObject({ sandbox: true });

  // The next one goes straight there: production is not asked again.
  calls.length = 0;
  mac.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  await macSettled(mac);
  expect(hosts()).toEqual(["apns-sandbox.test"]);

  // A new token may be from either environment, so nothing is assumed about it.
  phone.send({ type: "push", deviceToken: SECOND_DEVICE_TOKEN });
  await settled(phone);
  expect(await record(room, keys.pub)).toEqual({ deviceToken: SECOND_DEVICE_TOKEN });
});

test.each([false, true])("messages over one MiB close before parsing (binary: %s)", async (binary) => {
  const name = fakeRoom(`payload-limit-${binary}`);
  const client = await connect(name);
  await client.next();
  // The wire cap counts bytes, including JSON and multi-byte UTF-8 characters.
  const oversized = JSON.stringify({ type: "ping", padding: "é".repeat(524_288) });
  await runInDurableObject(room(name), async (instance, state) => {
    const socket = state.getWebSockets()[0]!;
    // Exercise the handler itself; workerd also has a transport limit of its own.
    await (instance as unknown as { webSocketMessage(ws: WebSocket, data: string | ArrayBuffer): Promise<void> })
      .webSocketMessage(socket, binary ? new TextEncoder().encode(oversized).buffer as ArrayBuffer : oversized);
  });
  expect(await client.closed()).toBe(1009);
});

test("a message exactly one MiB is accepted", async () => {
  const client = await connect(fakeRoom("payload-boundary"));
  await client.next();
  client.raw(JSON.stringify({ type: "ping" }).padEnd(1_048_576));
  expect(await client.next()).toEqual({ type: "pong" });
});

test("the socket bucket survives an object being reconstructed", async () => {
  const client = await connect(fakeRoom("bucket-hibernation"));
  await client.next();
  await runInDurableObject(room(fakeRoom("bucket-hibernation")), async (_instance, state) => {
    const socket = state.getWebSockets()[0]!;
    const clock = vi.spyOn(Date, "now").mockReturnValue(Date.now());
    try {
      for (let i = 0; i < 61; i++) {
        const awake = new Room(state, env as unknown as Env);
        await awake.webSocketMessage(socket, JSON.stringify({ type: "ping" }));
      }
    } finally {
      clock.mockRestore();
    }
  });
  expect(await client.closed()).toBe(4029);
});

test("heartbeats are answered at the edge and never spend the bucket", async () => {
  const client = await connect(fakeRoom("ping-free"));
  await client.next();
  // Far more than one second's burst: pings are matched by the edge auto-response and never
  // reach the bucket, so the socket stays open and every one gets its pong.
  for (let i = 0; i < 100; i++) client.send({ type: "ping" });
  for (let i = 0; i < 100; i++) expect(await client.next()).toMatchObject({ type: "pong" });
});

test("the configured token cap evicts the first mint even when expiries tie across hibernation", async () => {
  const keys = await keypair();
  const name = await roomId(keys.pub);
  const mac = await connectMac(keys);
  await runInDurableObject(room(name), async (_instance, state) => {
    const socket = state.getWebSockets()[0]!;
    const clock = vi.spyOn(Date, "now").mockReturnValue(Date.now());
    let minted = 0;
    const random = vi.spyOn(crypto, "getRandomValues").mockImplementation((array) => {
      if (array) new Uint8Array(array.buffer, array.byteOffset, array.byteLength).fill([254, 253, 255][minted++]!);
      return array;
    });
    try {
      for (let i = 0; i < 3; i++) {
        const awake = new Room(state, { ...(env as unknown as Env), RELAY_MAX_TOKENS_PER_ROOM: "2" });
        await awake.webSocketMessage(socket, JSON.stringify({ type: "mint" }));
      }
    } finally {
      random.mockRestore();
      clock.mockRestore();
    }
  });
  const first = await mac.next();
  const second = await mac.next();
  const third = await mac.next();
  expect(first.expiresAt).toBe(second.expiresAt);
  expect(first.expiresAt).toBe(third.expiresAt);
  expect(await (await connectPhone(name, first.token)).phone.closed()).toBe(4001);
  expect(await (await connectPhone(name, second.token)).phone.next()).toMatchObject({ type: "joined" });
  expect(await (await connectPhone(name, third.token)).phone.next()).toMatchObject({ type: "joined" });
});

test("notify limits share a room budget across hibernation and reset after a minute", async () => {
  const calls = fakeApns();
  const { mac, macKeys, phone, room: name } = await paired();
  const now = Date.now();
  const notify = JSON.stringify({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  const deliver = (at: number) => runInDurableObject(room(name), async (_instance, state) => {
    const socket = state.getWebSockets().find((ws) => ws.deserializeAttachment()?.role === "mac")!;
    const clock = vi.spyOn(Date, "now").mockReturnValue(at);
    try {
      const awake = new Room(state, { ...(env as unknown as Env), RELAY_NOTIFY_PER_MINUTE: "2" });
      await awake.webSocketMessage(socket, notify);
    } finally {
      clock.mockRestore();
    }
  });
  await deliver(now);
  await deliver(now);
  await deliver(now);
  expect(await mac.next()).toEqual({ type: "state", state: "notify rate limit" });
  await vi.waitFor(() => expect(calls).toHaveLength(2));
  // A dropped notification leaves encrypted traffic and later windows working normally.
  await frame(mac, "c3RpbGwtb3Blbg", macKeys);
  expect(await phone.next()).toMatchObject({ type: "frame", payload: "c3RpbGwtb3Blbg" });
  await deliver(now + 60_000);
  await vi.waitFor(() => expect(calls).toHaveLength(3));
});


test("mint requests spend the same bucket as registration", async () => {
  const keys = await keypair();
  const name = await roomId(keys.pub);
  const mac = await connect(name);
  const { nonce } = await mac.next();
  const register = JSON.stringify({ type: "register", pubkey: keys.pub, nonceSig: await sign(nonce, keys) });
  await runInDurableObject(room(name), async (instance, state) => {
    const socket = state.getWebSockets()[0]!;
    const awake = instance as Room;
    const clock = vi.spyOn(Date, "now").mockReturnValue(Date.now());
    try {
      await awake.webSocketMessage(socket, register);
      for (let i = 0; i < 60; i++) await awake.webSocketMessage(socket, JSON.stringify({ type: "mint" }));
    } finally {
      clock.mockRestore();
    }
  });
  expect(await mac.next()).toMatchObject({ type: "registered" });
  for (let i = 0; i < 59; i++) expect(await mac.next()).toMatchObject({ type: "token" });
  expect(await mac.closed()).toBe(4029);
});

test("the default token cap retains the newest eight pairing tokens", async () => {
  const keys = await keypair();
  const name = await roomId(keys.pub);
  const mac = await connectMac(keys);
  const tokens = [];
  for (let i = 0; i < 9; i++) tokens.push(await mintToken(mac));
  expect(await (await connectPhone(name, tokens[0]!)).phone.closed()).toBe(4001);
  for (const token of tokens.slice(1)) {
    expect(await (await connectPhone(name, token)).phone.next()).toMatchObject({ type: "joined" });
  }
});
