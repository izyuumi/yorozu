import { afterAll, beforeAll, expect, test, vi } from "vitest";
import { roomId, signChallenge, startRelay, type Relay } from "./index.js";
import { client, keypair } from "./testing.js";
import { conformance, type Adapter } from "./conformance.test.js";

/**
 * The Node relay against the shared conformance suite. Everything on the wire is covered
 * there; only what is Node's alone lives here.
 */

let relay: Relay;
beforeAll(async () => {
  relay = await startRelay(0);
});
afterAll(async () => {
  vi.useRealTimers();
  await relay.close();
});

const adapter: Adapter = {
  keypair: async () => {
    const keys = keypair();
    return { pub: keys.pub, sign: async (data) => signChallenge(data, keys.priv) };
  },
  roomId: async (pub) => roomId(pub),
  connect: async (room) => {
    const peer = client(relay.port, room);
    await peer.open;
    return {
      send: peer.send,
      raw: (text) => peer.ws.send(text),
      close: (code, reason) => peer.ws.close(code, reason),
      next: peer.next,
      closed: () => peer.closed,
    };
  },
  // The relay reads `Date.now()` in-process, so moving the clock is enough. Only `Date` is
  // faked: `ws` keeps its real timers.
  advance: async (_room, ms) => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(Date.now() + ms);
  },
};

conformance(adapter);

test("room id is base64url sha256 of the raw public key", () => {
  const { pub } = keypair();
  expect(roomId(pub)).toMatch(/^[\w-]{43}$/);
  expect(roomId(pub)).toBe(roomId(pub));
  expect(roomId(pub)).not.toBe(roomId(keypair().pub));
});

test("a key may only register in its own room", async () => {
  const keys = keypair();
  const squatter = client(relay.port, roomId(keypair().pub));
  await squatter.open;
  const { nonce } = await squatter.next();
  squatter.send({ type: "register", pubkey: keys.pub, nonceSig: signChallenge(nonce, keys.priv) });
  // Derived from the key, so the `?room=` it dialed is ignored and it lands in its own room.
  expect(await squatter.next()).toMatchObject({ type: "registered", roomId: roomId(keys.pub) });
});
