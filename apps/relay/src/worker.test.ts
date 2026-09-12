import { SELF } from "cloudflare:test";
import { expect, test } from "vitest";

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
  for (const payload of payloads) {
    expect(await reconnected.next()).toMatchObject({ type: "frame", payload });
  }
  // Drained, not replayed: a second registration finds an empty buffer.
  const third = await connectMac(macKeys);
  await frame(third, "YWZ0ZXI", macKeys);
  expect(await phone.next()).toMatchObject({ type: "owner", online: true });
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
