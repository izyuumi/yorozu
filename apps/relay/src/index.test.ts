import { afterEach, expect, test } from "vitest";
import { roomId, signChallenge, startRelay, type Relay } from "./index.js";
import { MAX_DEVICES } from "./protocol.js";
import { client, connectMac, connectPhone, keypair, mintToken, rejoinPhone } from "./testing.js";

let relay: Relay;

afterEach(async () => {
  await relay?.close();
});

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

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

test("a known device rejoins against the nonce, with no second token", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const room = roomId(macKeys.pub);
  const mac = await connectMac(relay.port, macKeys);
  const { phone, keys } = await connectPhone(relay.port, room, await mintToken(mac));
  expect(await phone.next()).toMatchObject({ type: "joined" });

  phone.ws.close();
  await phone.closed;
  await sleep(50); // let the relay observe the disconnect

  const again = await rejoinPhone(relay.port, room, keys);
  expect(await again.next()).toMatchObject({ type: "joined", ownerOnline: true });

  // And it is a real join: frames flow without pairing again.
  const payload = Buffer.from("after-rejoin").toString("base64");
  again.send({ type: "frame", payload, sig: signChallenge(payload, keys.priv) });
  expect(await mac.next()).toMatchObject({ type: "frame", payload });
});

test("a known device rejoins even after the mac has gone away and come back", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const room = roomId(macKeys.pub);
  const mac = await connectMac(relay.port, macKeys);
  const { phone, keys } = await connectPhone(relay.port, room, await mintToken(mac));
  await phone.next(); // joined
  phone.ws.close();
  mac.ws.close();
  await sleep(50);

  await connectMac(relay.port, macKeys);
  const again = await rejoinPhone(relay.port, room, keys);
  expect(await again.next()).toMatchObject({ type: "joined" });
});

test("a revoked device is dropped and cannot rejoin", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const room = roomId(macKeys.pub);
  const mac = await connectMac(relay.port, macKeys);
  const { phone, keys } = await connectPhone(relay.port, room, await mintToken(mac));
  expect(await phone.next()).toMatchObject({ type: "joined" });

  // The Mac unpairs it: the live socket goes, and the nonce rejoin it used to be allowed
  // to make is refused.
  mac.send({ type: "revoke", pubkey: keys.pub });
  expect(await phone.closed).toBe(4001);

  const again = await rejoinPhone(relay.port, room, keys);
  expect(await again.closed).toBe(4001);
});

test("only the room's mac may revoke, and a malformed revoke closes the socket", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const mac = await connectMac(relay.port, macKeys);

  const stranger = client(relay.port, roomId(macKeys.pub));
  await stranger.open;
  await stranger.next(); // nonce
  stranger.send({ type: "revoke", pubkey: keypair().pub });
  expect(await stranger.closed).toBe(4001);

  mac.send({ type: "revoke" });
  expect(await mac.closed).toBe(4001);
});

test("rejects a nonce join from a pubkey the room does not know", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const room = roomId(macKeys.pub);
  await connectMac(relay.port, macKeys);

  const stranger = await rejoinPhone(relay.port, room, keypair());
  expect(await stranger.closed).toBe(4001);
});

test("a nonce join must be signed by the device it names", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const room = roomId(macKeys.pub);
  const mac = await connectMac(relay.port, macKeys);
  const { phone, keys } = await connectPhone(relay.port, room, await mintToken(mac));
  await phone.next(); // joined

  const impostor = client(relay.port, room);
  await impostor.open;
  await impostor.next(); // nonce
  // The known pubkey, but signed with somebody else's key over somebody else's nonce.
  impostor.send({
    type: "join",
    roomId: room,
    phonePubkey: keys.pub,
    sig: signChallenge("not the nonce", keypair().priv),
  });
  expect(await impostor.closed).toBe(4003);
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

test("tells phones whether the room's mac is online", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const room = roomId(macKeys.pub);
  const mac = await connectMac(relay.port, macKeys);
  const { phone } = await connectPhone(relay.port, room, await mintToken(mac));
  expect(await phone.next()).toMatchObject({ type: "joined", ownerOnline: true });

  mac.ws.close();
  await mac.closed;
  expect(await phone.next()).toMatchObject({ type: "owner", online: false });

  await connectMac(relay.port, macKeys);
  expect(await phone.next()).toMatchObject({ type: "owner", online: true });
});

test("answers the heartbeat, and a phone can ask about presence again", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const room = roomId(macKeys.pub);
  const mac = await connectMac(relay.port, macKeys);
  const { phone } = await connectPhone(relay.port, room, await mintToken(mac));
  await phone.next(); // joined

  // The heartbeat neither closes the socket nor reaches the other end.
  mac.send({ type: "ping" });
  expect(await mac.next()).toMatchObject({ type: "pong" });
  phone.send({ type: "ping" });
  expect(await phone.next()).toMatchObject({ type: "pong" });

  phone.send({ type: "owner" });
  expect(await phone.next()).toMatchObject({ type: "owner", online: true });

  mac.ws.close();
  await mac.closed;
  expect(await phone.next()).toMatchObject({ type: "owner", online: false });
  phone.send({ type: "owner" });
  expect(await phone.next()).toMatchObject({ type: "owner", online: false });
});

test("only a joined phone may ask about presence", async () => {
  relay = await startRelay(0);
  const stranger = client(relay.port);
  await stranger.open;
  await stranger.next(); // nonce
  stranger.send({ type: "owner" });
  expect(await stranger.closed).toBe(4001);
});

test("an announced device may rejoin, so state this relay lost comes back", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const room = roomId(macKeys.pub);
  const mac = await connectMac(relay.port, macKeys);
  const phoneKeys = keypair();

  // Nothing has ever paired here: the rejoin is refused until the Mac says otherwise.
  expect(await (await rejoinPhone(relay.port, room, phoneKeys)).closed).toBe(4001);

  mac.send({ type: "devices", devices: [phoneKeys.pub] });
  const phone = await rejoinPhone(relay.port, room, phoneKeys);
  expect(await phone.next()).toMatchObject({ type: "joined", roomId: room });
});

test("a shorter announced list drops the devices missing from it", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const room = roomId(macKeys.pub);
  const mac = await connectMac(relay.port, macKeys);
  const [gone, kept] = [keypair(), keypair()];
  mac.send({ type: "devices", devices: [gone.pub, kept.pub] });

  // The Mac's list is the source of truth, so a key absent from the next one is unpaired.
  mac.send({ type: "devices", devices: [kept.pub] });
  expect(await (await rejoinPhone(relay.port, room, gone)).closed).toBe(4001);
  expect(await (await rejoinPhone(relay.port, room, kept)).next()).toMatchObject({
    type: "joined",
  });
});

test("an announce that has not caught up yet leaves a connected device alone", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const room = roomId(macKeys.pub);
  const mac = await connectMac(relay.port, macKeys);
  const { phone, keys } = await connectPhone(relay.port, room, await mintToken(mac));
  expect(await phone.next()).toMatchObject({ type: "joined" });

  // The phone has just spent its token and the Mac is still being told about it, so an
  // announce that predates the news must not unpair it. `revoke` is what does that.
  mac.send({ type: "devices", devices: [] });
  mac.send({ type: "mint" });
  await mac.next(); // the token, which is answered after the announce ahead of it

  expect(await (await rejoinPhone(relay.port, room, keys)).next()).toMatchObject({
    type: "joined",
  });
});

test("an announced list past the cap keeps the last MAX_DEVICES of it", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const room = roomId(macKeys.pub);
  const mac = await connectMac(relay.port, macKeys);
  const announced = Array.from({ length: MAX_DEVICES + 1 }, () => keypair());
  mac.send({ type: "devices", devices: announced.map(({ pub }) => pub) });

  // The first one announced is the one over the cap; the last is inside it.
  expect(await (await rejoinPhone(relay.port, room, announced[0]!)).closed).toBe(4001);
  expect(await (await rejoinPhone(relay.port, room, announced.at(-1)!)).next()).toMatchObject({
    type: "joined",
  });
});

test("only the room's mac may announce devices, and a malformed list closes the socket", async () => {
  relay = await startRelay(0);
  const macKeys = keypair();
  const mac = await connectMac(relay.port, macKeys);

  const stranger = client(relay.port, roomId(macKeys.pub));
  await stranger.open;
  await stranger.next(); // nonce
  stranger.send({ type: "devices", devices: [] });
  expect(await stranger.closed).toBe(4001);

  mac.send({ type: "devices", devices: [1] });
  expect(await mac.closed).toBe(4001);
});
