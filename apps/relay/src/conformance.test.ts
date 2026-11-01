import { expect, test, vi } from "vitest";
import { CLOSE_BAD_SIGNATURE, CLOSE_PROTOCOL, CLOSE_RATE_LIMIT, FRAMES_PER_SEC, MAX_DEVICES, TOKEN_TTL_MS } from "./protocol.js";

export type Keys = { pub: string; sign(data: string): Promise<string> };

export type Peer = {
  phones: number[];
  send(msg: unknown): void;
  raw(text: string): void;
  close(code?: number, reason?: string): void;
  next(): Promise<any>;
  closed(): Promise<number>;
  closedReason(): Promise<string>;
};

export type Adapter = {
  keypair(): Promise<Keys>;
  roomId(pub: string): Promise<string>;
  connect(room: string): Promise<Peer>;
  advance(room: string, ms: number): Promise<void>;
};

export const fakeRoom = (label: string): string => label.padEnd(43, "0");

export function conformance(relay: Adapter) {
  const { keypair, roomId, connect } = relay;

  async function connectMac(keys: Keys): Promise<Peer> {
    const room = await roomId(keys.pub);
    const mac = await connect(room);
    const { nonce } = await mac.next();
    mac.send({ type: "register", pubkey: keys.pub, nonceSig: await keys.sign(nonce) });
    expect(await mac.next()).toMatchObject({ type: "registered", roomId: room, pushProxy: true });
    return mac;
  }

  async function mintToken(mac: Peer): Promise<string> {
    mac.send({ type: "mint" });
    const { token } = await mac.next();
    return token as string;
  }

  async function connectPhone(room: string, token: string) {
    const keys = await keypair();
    const phone = await connect(room);
    await phone.next();
    phone.send({ type: "join", roomId: room, token, phonePubkey: keys.pub, sig: await keys.sign(token) });
    return { phone, keys };
  }

  async function rejoinPhone(room: string, keys: Keys): Promise<Peer> {
    const phone = await connect(room);
    const { nonce } = await phone.next();
    phone.send({ type: "join", roomId: room, phonePubkey: keys.pub, sig: await keys.sign(nonce) });
    return phone;
  }

  async function frame(peer: Peer, payload: string, keys: Keys): Promise<string> {
    const sig = await keys.sign(payload);
    peer.send({ type: "frame", payload, sig });
    return sig;
  }

  async function paired() {
    const macKeys = await keypair();
    const room = await roomId(macKeys.pub);
    const mac = await connectMac(macKeys);
    const { phone, keys } = await connectPhone(room, await mintToken(mac));
    expect(await phone.next()).toMatchObject({ type: "joined", ownerOnline: true });
    return { macKeys, room, mac, phone, keys };
  }

  test("forwards opaque frames in both directions", async () => {
    const { macKeys, mac, phone, keys } = await paired();

    await frame(phone, "Y2lwaGVydGV4dC1mcm9tLXBob25l", keys);
    expect(await mac.next()).toMatchObject({ type: "frame", payload: "Y2lwaGVydGV4dC1mcm9tLXBob25l" });
    expect(await phone.next()).toMatchObject({ type: "accepted" });

    await frame(mac, "Y2lwaGVydGV4dC1mcm9tLW1hYw", macKeys);
    expect(await phone.next()).toMatchObject({ type: "frame", payload: "Y2lwaGVydGV4dC1mcm9tLW1hYw" });
  });

  test("buffers frames while the mac is offline and drains them in order", async () => {
    const { macKeys, mac, phone, keys } = await paired();

    mac.close();
    expect(await phone.next()).toMatchObject({ type: "owner", online: false });

    const payloads = ["b25l", "dHdv", "dGhyZWU"];
    for (const payload of payloads) {
      await frame(phone, payload, keys);
      expect(await phone.next()).toMatchObject({ type: "accepted", buffered: true });
    }

    const reconnected = await connectMac(macKeys);
    let last = -1;
    for (const payload of payloads) {
      const replayed = await reconnected.next();
      expect(replayed).toMatchObject({ type: "frame", payload });
      expect(replayed.seq).toBe(last + 1);
      last = replayed.seq;
    }

    reconnected.close();
    const again = await connectMac(macKeys);
    for (const payload of payloads) {
      expect(await again.next()).toMatchObject({ type: "frame", payload });
    }

    again.send({ type: "ack", seq: last });
    again.close();
    const third = await connectMac(macKeys);
    await frame(third, "bGF0ZXI", macKeys);
    let msg = await phone.next();
    while (msg.type === "owner") msg = await phone.next();
    expect(msg).toMatchObject({ type: "frame", payload: "bGF0ZXI" });
  });

  test("the phone hears each frame accepted, after it is forwarded or buffered", async () => {
    const { macKeys, mac, phone, keys } = await paired();

    const live = await frame(phone, "bGl2ZQ", keys);
    expect(await mac.next()).toMatchObject({ type: "frame", payload: "bGl2ZQ" });
    expect(await phone.next()).toEqual({ type: "accepted", sig: live, buffered: false });

    mac.close();
    expect(await phone.next()).toMatchObject({ type: "owner", online: false });
    const held = await frame(phone, "aGVsZA", keys);
    expect(await phone.next()).toEqual({ type: "accepted", sig: held, buffered: true });
    const back = await connectMac(macKeys);
    expect(await back.next()).toMatchObject({ type: "frame", payload: "aGVsZA", seq: 0 });
  });

  test("frames are replayed in order and each is retained until acked", async () => {
    const { macKeys, mac, phone, keys } = await paired();
    mac.close();
    await phone.next();
    for (const payload of ["YQ", "Yg", "Yw"]) await frame(phone, payload, keys);

    const second = await connectMac(macKeys);
    expect((await second.next()).seq).toBe(0);
    expect((await second.next()).seq).toBe(1);
    expect((await second.next()).seq).toBe(2);
    second.send({ type: "ack", seq: 1 });
    await mintToken(second);
    second.close();

    const third = await connectMac(macKeys);
    expect(await third.next()).toMatchObject({ type: "frame", payload: "Yw", seq: 2 });
    third.send({ type: "mint" });
    expect(await third.next()).toMatchObject({ type: "token" });
  });

  test("only the room's mac may ack, and a malformed ack closes the socket", async () => {
    const { mac, phone } = await paired();
    phone.send({ type: "ack", seq: 0 });
    expect(await phone.closed()).toBe(CLOSE_PROTOCOL);
    mac.send({ type: "ack", seq: "zero" });
    expect(await mac.closed()).toBe(CLOSE_PROTOCOL);
  });

  test("join tokens are one-time", async () => {
    const { mac, room } = await paired();
    const token = await mintToken(mac);
    expect(await (await connectPhone(room, token)).phone.next()).toMatchObject({ type: "joined" });
    expect(await (await connectPhone(room, token)).phone.closed()).toBe(CLOSE_PROTOCOL);
  });

  test("an expired join token is refused, and a fresh one still works", async () => {
    const { mac, room } = await paired();
    const stale = await mintToken(mac);
    await relay.advance(room, TOKEN_TTL_MS + 1);
    expect(await (await connectPhone(room, stale)).phone.closed()).toBe(CLOSE_PROTOCOL);
    expect(await (await connectPhone(room, stale)).phone.closed()).toBe(CLOSE_PROTOCOL);
    const live = await mintToken(mac);
    expect(await (await connectPhone(room, live)).phone.next()).toMatchObject({ type: "joined" });
  });

  test("a join to a room nobody registered fails the same way, with or without a token", async () => {
    const room = await roomId((await keypair()).pub);
    expect(await (await connectPhone(room, "no-such-token")).phone.closed()).toBe(CLOSE_PROTOCOL);
    expect(await (await rejoinPhone(room, await keypair())).closed()).toBe(CLOSE_PROTOCOL);
  });

  test("a known device rejoins against the nonce, with no second token", async () => {
    const { mac, room, phone, keys } = await paired();
    phone.close();

    const again = await rejoinPhone(room, keys);
    expect(await again.next()).toMatchObject({ type: "joined", ownerOnline: true });

    await frame(again, "YWZ0ZXItcmVqb2lu", keys);
    expect(await mac.next()).toMatchObject({ type: "frame", payload: "YWZ0ZXItcmVqb2lu" });
  });

  test("a revoked device is dropped and cannot rejoin", async () => {
    const { mac, room, phone, keys } = await paired();
    mac.send({ type: "revoke", pubkey: keys.pub });
    expect(await phone.closed()).toBe(CLOSE_PROTOCOL);
    expect(await (await rejoinPhone(room, keys)).closed()).toBe(CLOSE_PROTOCOL);
  });

  test("only the room's mac may revoke, and a malformed revoke closes the socket", async () => {
    const { mac, room } = await paired();

    const stranger = await connect(room);
    await stranger.next();
    stranger.send({ type: "revoke", pubkey: (await keypair()).pub });
    expect(await stranger.closed()).toBe(CLOSE_PROTOCOL);

    mac.send({ type: "revoke" });
    expect(await mac.closed()).toBe(CLOSE_PROTOCOL);
  });

  test("rejects a nonce join from a pubkey the room does not know", async () => {
    const { room } = await paired();
    expect(await (await rejoinPhone(room, await keypair())).closed()).toBe(CLOSE_PROTOCOL);
  });

  test("a nonce join must be signed by the device it names", async () => {
    const { room, keys } = await paired();
    const impostor = await connect(room);
    await impostor.next();
    impostor.send({
      type: "join",
      roomId: room,
      phonePubkey: keys.pub,
      sig: await (await keypair()).sign("not the nonce"),
    });
    expect(await impostor.closed()).toBe(CLOSE_BAD_SIGNATURE);
  });

  test("rejects a registration with a bad challenge signature", async () => {
    const keys = await keypair();
    const mac = await connect(await roomId(keys.pub));
    await mac.next();
    mac.send({ type: "register", pubkey: keys.pub, nonceSig: await keys.sign("wrong") });
    expect(await mac.closed()).toBe(CLOSE_BAD_SIGNATURE);
  });

  test("rejects a join signed by the wrong key, without burning the token", async () => {
    const { mac, room } = await paired();
    const token = await mintToken(mac);

    const phone = await connect(room);
    await phone.next();
    phone.send({
      type: "join",
      roomId: room,
      token,
      phonePubkey: (await keypair()).pub,
      sig: await (await keypair()).sign(token),
    });
    expect(await phone.closed()).toBe(CLOSE_BAD_SIGNATURE);

    const retry = await connectPhone(room, token);
    expect(await retry.phone.next()).toMatchObject({ type: "joined" });
  });

  test("drops unsigned and mis-signed frames with a close code", async () => {
    const { mac, room, phone, keys } = await paired();

    phone.send({ type: "frame", payload: "dW5zaWduZWQ=" });
    expect(await phone.closed()).toBe(CLOSE_BAD_SIGNATURE);

    const second = await connectPhone(room, await mintToken(mac));
    await second.phone.next();
    second.phone.send({ type: "frame", payload: "dGFtcGVyZWQ", sig: await keys.sign("else") });
    expect(await second.phone.closed()).toBe(CLOSE_BAD_SIGNATURE);
  });

  test("rate limits per socket: a flooding phone closes, the mac and the other phone stay up", async () => {
    const { macKeys, mac, room, phone, keys } = await paired();
    const other = await connectPhone(room, await mintToken(mac));
    await other.phone.next();

    const payload = "Zmxvb2Q";
    const sig = await keys.sign(payload);
    for (let i = 0; i < FRAMES_PER_SEC + 20; i++) phone.send({ type: "frame", payload, sig });
    expect(await phone.closed()).toBe(CLOSE_RATE_LIMIT);

    await frame(other.phone, "bWFya2Vy", other.keys);
    expect(await other.phone.next()).toMatchObject({ type: "accepted", buffered: false });
    let forwarded = 0;
    for (let msg = await mac.next(); msg.payload !== "bWFya2Vy"; msg = await mac.next()) {
      expect(msg).toMatchObject({ type: "frame", payload });
      forwarded++;
    }
    expect(forwarded).toBeGreaterThan(0);
    expect(forwarded).toBeLessThan(FRAMES_PER_SEC + 20);
    await frame(mac, "c3RpbGwtb3Blbg", macKeys);
    expect(await other.phone.next()).toMatchObject({ type: "frame", payload: "c3RpbGwtb3Blbg" });
  });

  test("a mac's frame batch costs one token and lands on phones as plain frames", async () => {
    const { macKeys, mac, room, phone } = await paired();

    const batches = FRAMES_PER_SEC - 4;
    const batch = await Promise.all(
      Array.from({ length: MAX_DEVICES }, async (_, i) => {
        const payload = `Y29weS${i}`;
        return { payload, sig: await macKeys.sign(payload) };
      }),
    );
    for (let i = 0; i < batches; i++) mac.send({ type: "frame", frames: batch });
    for (let i = 0; i < batches * MAX_DEVICES; i++) {
      const copy = batch[i % MAX_DEVICES]!;
      expect(await phone.next()).toMatchObject({ type: "frame", payload: copy.payload, sig: copy.sig });
    }
    mac.send({ type: "mint" });
    expect(await mac.next()).toMatchObject({ type: "token" });

    mac.send({ type: "frame", frames: [...batch, batch[0]] });
    expect(await mac.closed()).toBe(CLOSE_BAD_SIGNATURE);
    const again = await connectMac(macKeys);
    again.send({ type: "frame", frames: [batch[0], { payload: "x", sig: batch[0]!.sig }] });
    expect(await again.closed()).toBe(CLOSE_BAD_SIGNATURE);

    const sender = await connectPhone(room, await mintToken(await connectMac(macKeys)));
    await sender.phone.next();
    sender.phone.send({ type: "frame", frames: [{ payload: "cA", sig: await sender.keys.sign("cA") }] });
    expect(await sender.phone.closed()).toBe(CLOSE_PROTOCOL);
  });

  test("json that is not an object closes the socket", async () => {
    for (const raw of ["null", "42", '"frame"', '[{"type":"ping"}]', "{oops"]) {
      const peer = await connect(fakeRoom("anything"));
      await peer.next();
      peer.raw(raw);
      expect(await peer.closed()).toBe(CLOSE_PROTOCOL);
    }
  });

  test("an oversized envelope closes the socket", async () => {
    const peer = await connect(fakeRoom("anything"));
    await peer.next();
    peer.raw(JSON.stringify({ type: "frame", payload: "A".repeat(2 * 1024 * 1024) }));
    expect(await peer.closed()).toBe(1009);
  });

  test("push registration accepts hexadecimal tokens and rejects malformed tokens", async () => {
    const { mac, room, phone } = await paired();
    for (const deviceToken of ["abcdef0123456789".repeat(4), "ABCDEF0123456789".repeat(8), "ab".repeat(100), "cd".repeat(512)]) {
      phone.send({ type: "push", deviceToken });
      phone.send({ type: "owner" });
      expect(await phone.next()).toMatchObject({ type: "owner", online: true });
    }

    for (const deviceToken of ["", "a".repeat(63), "a".repeat(65), "g".repeat(64), "a".repeat(63) + "\n", "a".repeat(1026)]) {
      const invalid = await connectPhone(room, await mintToken(mac));
      await invalid.phone.next();
      invalid.phone.send({ type: "push", deviceToken });
      expect(await invalid.phone.closed()).toBe(CLOSE_PROTOCOL);
    }
  });

  test("host push accepts known devices and silently ignores unknown devices", async () => {
    const { mac, keys } = await paired();
    const direct = await keypair();
    mac.send({ type: "devices", devices: [direct.pub] });
    for (const device of [keys.pub, direct.pub, (await keypair()).pub]) {
      mac.send({ type: "push", device, token: "AB".repeat(32) });
      mac.send({ type: "mint" });
      expect(await mac.next()).toMatchObject({ type: "token" });
    }
  });

  test("malformed host push closes with bad push", async () => {
    const device = (await keypair()).pub;
    for (const fields of [
      ...[undefined, null, 42, "", "a".repeat(63), "gg", "aa\n", "aa".repeat(513)]
        .map((token) => ({ device, token })),
      ...[undefined, null, 42, "", "D".repeat(42), "+".repeat(43), "D".repeat(44)]
        .map((device) => ({ device, token: "ab".repeat(32) })),
    ]) {
      const mac = await connectMac(await keypair());
      mac.send({ type: "push", ...fields });
      expect(await mac.closed()).toBe(CLOSE_PROTOCOL);
      expect(await mac.closedReason()).toBe("bad push");
    }
  });

  test("a device cannot register a token using the host push shape", async () => {
    const { phone, keys } = await paired();
    phone.send({ type: "push", device: keys.pub, token: "ab".repeat(32) });
    expect(await phone.closed()).toBe(CLOSE_PROTOCOL);
    expect(await phone.closedReason()).toBe("bad push");
  });

  test("an unknown type is ignored, from the mac and from a phone, and the socket stays open", async () => {
    const { mac, phone } = await paired();
    mac.send({ type: "nope", extra: 1 });
    mac.send({ type: "ping" });
    expect(await mac.next()).toMatchObject({ type: "pong" });
    phone.send({ type: "nope", extra: 1 });
    phone.send({ type: "owner" });
    expect(await phone.next()).toMatchObject({ type: "owner", online: true });
  });

  test("unknown fields on a known type are ignored", async () => {
    const { mac, phone, keys } = await paired();
    phone.send({ type: "owner", extra: { nested: true } });
    expect(await phone.next()).toMatchObject({ type: "owner", online: true });
    const sig = await keys.sign("cA");
    phone.send({ type: "frame", payload: "cA", sig, extra: 1 });
    expect(await mac.next()).toMatchObject({ type: "frame", payload: "cA" });
  });

  test("tells phones whether the room's mac is online", async () => {
    const { macKeys, mac, phone } = await paired();
    mac.close();
    expect(await phone.next()).toMatchObject({ type: "owner", online: false });
    await connectMac(macKeys);
    expect(await phone.next()).toMatchObject({ type: "owner", online: true });
  });

  test("tells the mac how many phones are listening", async () => {
    const macKeys = await keypair();
    const room = await roomId(macKeys.pub);
    const mac = await connectMac(macKeys);
    const { phone } = await connectPhone(room, await mintToken(mac));
    expect(await phone.next()).toMatchObject({ type: "joined" });
    await vi.waitFor(() => expect(mac.phones).toEqual([1]));
    phone.close();
    await vi.waitFor(() => expect(mac.phones).toEqual([1, 0]));

    const { phone: second } = await connectPhone(room, await mintToken(mac));
    expect(await second.next()).toMatchObject({ type: "joined" });
    mac.close();
    expect(await second.next()).toMatchObject({ type: "owner", online: false });
    const again = await connect(room);
    const { nonce } = await again.next();
    again.send({ type: "register", pubkey: macKeys.pub, nonceSig: await macKeys.sign(nonce) });
    expect(await again.next()).toMatchObject({ type: "registered", phones: 1 });
  });

  test("answers the heartbeat, and a phone can ask about presence again", async () => {
    const { mac, phone } = await paired();

    mac.send({ type: "ping" });
    expect(await mac.next()).toMatchObject({ type: "pong" });
    phone.send({ type: "ping" });
    expect(await phone.next()).toMatchObject({ type: "pong" });

    phone.send({ type: "owner" });
    expect(await phone.next()).toMatchObject({ type: "owner", online: true });

    mac.close();
    expect(await phone.next()).toMatchObject({ type: "owner", online: false });
    phone.send({ type: "owner" });
    expect(await phone.next()).toMatchObject({ type: "owner", online: false });
  });

  test("only a joined phone may ask about presence", async () => {
    const stranger = await connect(fakeRoom("some-room"));
    await stranger.next();
    stranger.send({ type: "owner" });
    expect(await stranger.closed()).toBe(CLOSE_PROTOCOL);
  });

  test("an announced device may rejoin, so state the relay lost comes back", async () => {
    const macKeys = await keypair();
    const room = await roomId(macKeys.pub);
    const mac = await connectMac(macKeys);
    const phoneKeys = await keypair();

    expect(await (await rejoinPhone(room, phoneKeys)).closed()).toBe(CLOSE_PROTOCOL);

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

    mac.send({ type: "devices", devices: [kept.pub] });
    expect(await (await rejoinPhone(room, gone)).closed()).toBe(CLOSE_PROTOCOL);
    expect(await (await rejoinPhone(room, kept)).next()).toMatchObject({ type: "joined" });
  });

  test("an announce that has not caught up yet leaves a connected device alone", async () => {
    const { mac, room, keys } = await paired();

    mac.send({ type: "devices", devices: [] });
    mac.send({ type: "mint" });
    await mac.next();

    expect(await (await rejoinPhone(room, keys)).next()).toMatchObject({ type: "joined" });
  });

  test("an announced list past the cap keeps the last MAX_DEVICES of it", async () => {
    const macKeys = await keypair();
    const room = await roomId(macKeys.pub);
    const mac = await connectMac(macKeys);
    const announced = await Promise.all(Array.from({ length: MAX_DEVICES + 1 }, () => keypair()));
    mac.send({ type: "devices", devices: announced.map(({ pub }) => pub) });

    expect(await (await rejoinPhone(room, announced[0]!)).closed()).toBe(CLOSE_PROTOCOL);
    expect(await (await rejoinPhone(room, announced.at(-1)!)).next()).toMatchObject({ type: "joined" });
  });

  test("only the room's mac may announce devices, and a malformed list closes the socket", async () => {
    const { mac, room } = await paired();

    const stranger = await connect(room);
    await stranger.next();
    stranger.send({ type: "devices", devices: [] });
    expect(await stranger.closed()).toBe(CLOSE_PROTOCOL);

    mac.send({ type: "devices", devices: [1] });
    expect(await mac.closed()).toBe(CLOSE_PROTOCOL);
  });

  test("a peer's close reason is cut and stripped before it is logged", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    try {
      const { mac } = await paired();
      mac.close(4099, "x".repeat(60) + "\n\u0000injected");
      const line = await vi.waitFor(() => {
        const found = log.mock.calls.map(([l]) => String(l)).find((l) => l.includes('"ev":"close"') && l.includes('"code":4099'));
        expect(found).toBeDefined();
        return found!;
      });
      expect(JSON.parse(line).reason).toBe("x".repeat(60) + "inje");
    } finally {
      log.mockRestore();
    }
  });
}
