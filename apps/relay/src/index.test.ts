import { generateKeyPairSync, type KeyObject } from "node:crypto";
import { afterEach, expect, test } from "vitest";
import WebSocket from "ws";
import { roomId, signChallenge, startRelay, type Relay } from "./index.js";

let relay: Relay;

afterEach(async () => {
  await relay?.close();
});

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function keypair() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return { pub: publicKey.export({ format: "jwk" }).x as string, priv: privateKey };
}

/** Minimal client: queue inbound JSON so tests can await messages in order. */
function client(port: number) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const queue: any[] = [];
  const waiters: ((v: any) => void)[] = [];
  ws.on("message", (d) => {
    const msg = JSON.parse(d.toString());
    const waiter = waiters.shift();
    if (waiter) waiter(msg);
    else queue.push(msg);
  });
  return {
    ws,
    send: (msg: unknown) => ws.send(JSON.stringify(msg)),
    next: (): Promise<any> =>
      queue.length > 0 ? Promise.resolve(queue.shift()) : new Promise((r) => waiters.push(r)),
    closed: new Promise<number>((r) => ws.on("close", (code) => r(code))),
    open: new Promise<void>((r) => ws.on("open", () => r())),
  };
}

async function connectMac(port: number, keys: { pub: string; priv: KeyObject }) {
  const mac = client(port);
  await mac.open;
  const { nonce } = await mac.next();
  mac.send({ type: "register", pubkey: keys.pub, nonceSig: signChallenge(nonce, keys.priv) });
  const registered = await mac.next();
  expect(registered).toMatchObject({ type: "registered", roomId: roomId(keys.pub) });
  return mac;
}

async function mintToken(mac: ReturnType<typeof client>) {
  mac.send({ type: "mint" });
  const { token } = await mac.next();
  return token as string;
}

async function connectPhone(port: number, room: string, token: string) {
  const keys = keypair();
  const phone = client(port);
  await phone.open;
  await phone.next(); // nonce
  phone.send({
    type: "join",
    roomId: room,
    token,
    phonePubkey: keys.pub,
    sig: signChallenge(token, keys.priv),
  });
  return { phone, keys };
}

test("room id is base64url sha256 of the raw public key", () => {
  const { pub } = keypair();
  expect(roomId(pub)).toMatch(/^[\w-]{43}$/);
  expect(roomId(pub)).toBe(roomId(pub));
  expect(roomId(pub)).not.toBe(roomId(keypair().pub));
});

test("forwards opaque frames in both directions", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const mac = await connectMac(relay.port, macKeys);
  const token = await mintToken(mac);
  const { phone, keys: phoneKeys } = await connectPhone(relay.port, roomId(macKeys.pub), token);
  expect(await phone.next()).toMatchObject({ type: "joined" });

  const up = Buffer.from("ciphertext-from-phone").toString("base64");
  phone.send({ type: "frame", payload: up, sig: signChallenge(up, phoneKeys.priv) });
  expect(await mac.next()).toMatchObject({ type: "frame", payload: up });

  const down = Buffer.from("ciphertext-from-mac").toString("base64");
  mac.send({ type: "frame", payload: down, sig: signChallenge(down, macKeys.priv) });
  expect(await phone.next()).toMatchObject({ type: "frame", payload: down });
});

test("buffers frames while the mac is offline and drains them in order", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const room = roomId(macKeys.pub);
  const mac = await connectMac(relay.port, macKeys);
  const token = await mintToken(mac);
  const { phone, keys: phoneKeys } = await connectPhone(relay.port, room, token);
  await phone.next(); // joined

  mac.ws.close();
  await mac.closed;
  await sleep(50); // let the relay observe the disconnect

  const payloads = ["one", "two", "three"].map((s) => Buffer.from(s).toString("base64"));
  for (const payload of payloads) {
    phone.send({ type: "frame", payload, sig: signChallenge(payload, phoneKeys.priv) });
  }
  await sleep(50);

  const reconnected = await connectMac(relay.port, macKeys);
  for (const payload of payloads) {
    expect(await reconnected.next()).toMatchObject({ type: "frame", payload });
  }
});

test("join tokens are one-time", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const room = roomId(macKeys.pub);
  const mac = await connectMac(relay.port, macKeys);
  const token = await mintToken(mac);

  const { phone } = await connectPhone(relay.port, room, token);
  expect(await phone.next()).toMatchObject({ type: "joined" });

  const replay = await connectPhone(relay.port, room, token);
  expect(await replay.phone.closed).toBe(4001);
});

test("rejects a registration with a bad challenge signature", async () => {
  relay = await startRelay(0);
  const keys = keypair();
  const mac = client(relay.port);
  await mac.open;
  await mac.next(); // nonce
  mac.send({ type: "register", pubkey: keys.pub, nonceSig: signChallenge("wrong", keys.priv) });
  expect(await mac.closed).toBe(4003);
});

test("rejects a join signed by the wrong key", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const mac = await connectMac(relay.port, macKeys);
  const token = await mintToken(mac);

  const phone = client(relay.port);
  await phone.open;
  await phone.next(); // nonce
  phone.send({
    type: "join",
    roomId: roomId(macKeys.pub),
    token,
    phonePubkey: keypair().pub,
    sig: signChallenge(token, keypair().priv),
  });
  expect(await phone.closed).toBe(4003);

  // The failed join must not have burned the token.
  const retry = await connectPhone(relay.port, roomId(macKeys.pub), token);
  expect(await retry.phone.next()).toMatchObject({ type: "joined" });
});

test("drops unsigned and mis-signed frames with a close code", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const mac = await connectMac(relay.port, macKeys);
  const token = await mintToken(mac);
  const { phone, keys: phoneKeys } = await connectPhone(relay.port, roomId(macKeys.pub), token);
  await phone.next(); // joined

  phone.send({ type: "frame", payload: "dW5zaWduZWQ=" });
  expect(await phone.closed).toBe(4003);

  const second = await connectPhone(relay.port, roomId(macKeys.pub), await mintToken(mac));
  await second.phone.next(); // joined
  const payload = Buffer.from("tampered").toString("base64");
  second.phone.send({
    type: "frame",
    payload,
    sig: signChallenge("something-else", phoneKeys.priv),
  });
  expect(await second.phone.closed).toBe(4003);
});

test("rate limits frames per room", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const mac = await connectMac(relay.port, macKeys);
  const token = await mintToken(mac);
  const { phone, keys: phoneKeys } = await connectPhone(relay.port, roomId(macKeys.pub), token);
  await phone.next(); // joined

  const payload = Buffer.from("flood").toString("base64");
  const sig = signChallenge(payload, phoneKeys.priv);
  for (let i = 0; i < 80; i++) phone.send({ type: "frame", payload, sig });
  expect(await phone.closed).toBe(4029);
});
