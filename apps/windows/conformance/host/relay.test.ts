// What the Windows client expects of the relay, checked against the real Node relay of this commit.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { afterEach, beforeEach, test } from "node:test";

// The relay's sources import "./x.js" for tsc; Node runs the .ts files directly.
// Same hook as plugins/openclaw-yorozu/test/hub-host.ts.
registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  },
});
const { roomId, signChallenge, startRelay } = await import("../../../relay/src/index.ts");
const { client, connectMac, connectPhone, keypair, mintToken, rejoinPhone } = await import(
  "../../../relay/src/testing.ts"
);
const { CLOSE_HOST_OFFLINE, CLOSE_PROTOCOL, HOST_OFFLINE_REASON, MAX_DEVICES } = await import(
  "../../../relay/src/protocol.ts"
);

type Client = Awaited<ReturnType<typeof connectMac>>;
type Keys = ReturnType<typeof keypair>;

let relay: Awaited<ReturnType<typeof startRelay>>;
beforeEach(async () => {
  relay = await startRelay(0);
});
afterEach(() => relay.close());

/** The close code and reason the relay ends a connection with. */
const closeOf = (c: Client): Promise<{ code: number; reason: string }> =>
  new Promise((resolve) => {
    c.ws.on("close", (code: number, reason: Buffer) => resolve({ code, reason: reason.toString() }));
  });

/** A token join with keys the caller keeps, so the same token can be tried again. */
async function tokenJoin(room: string, token: string, keys: Keys): Promise<Client> {
  const phone = client(relay.port, room);
  await phone.open;
  await phone.next(); // the nonce
  phone.send({ type: "join", roomId: room, token, phonePubkey: keys.pub, sig: signChallenge(token, keys.priv) });
  return phone;
}

test("the wire constants the client is built on", () => {
  assert.equal(CLOSE_PROTOCOL, 4001);
  assert.equal(CLOSE_HOST_OFFLINE, 4011);
  assert.equal(HOST_OFFLINE_REASON, "host offline");
  assert.equal(MAX_DEVICES, 16);
});

test("a token join is answered with joined, without flowControl", async () => {
  const host = keypair();
  const mac = await connectMac(relay.port, host);
  const room = roomId(host.pub);
  const { phone } = await connectPhone(relay.port, room, await mintToken(mac));
  const joined = await phone.next();
  assert.equal(joined.type, "joined");
  assert.equal(joined.roomId, room);
  assert.equal(joined.ownerOnline, true);
  assert.equal("flowControl" in joined, false);
});

test("an unknown device's nonce join closes 4011 before the announce and 4001 after it", async () => {
  const host = keypair();
  const mac = await connectMac(relay.port, host);
  const room = roomId(host.pub);
  const device = keypair();

  assert.deepEqual(await closeOf(await rejoinPhone(relay.port, room, device)), {
    code: 4011,
    reason: "host offline",
  });

  mac.send({ type: "devices", devices: [] });
  mac.send({ type: "ping" });
  assert.equal((await mac.next()).type, "pong"); // the relay has handled the announce
  assert.deepEqual(await closeOf(await rejoinPhone(relay.port, room, device)), {
    code: 4001,
    reason: "unknown device",
  });
});

test("the 17th pending token join closes 4011 and does not spend its token", async () => {
  const host = keypair();
  const mac = await connectMac(relay.port, host);
  const room = roomId(host.pub);

  // Pending: joined by token, not yet in a `devices` announce from the host.
  for (let i = 0; i < 16; i++) {
    const { phone } = await connectPhone(relay.port, room, await mintToken(mac));
    assert.equal((await phone.next()).type, "joined");
  }

  const token = await mintToken(mac);
  const device = keypair();
  const offline = { code: 4011, reason: "host offline" };
  assert.deepEqual(await closeOf(await tokenJoin(room, token, device)), offline);
  assert.deepEqual(await closeOf(await tokenJoin(room, token, device)), offline);
});
