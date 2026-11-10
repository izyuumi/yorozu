// The fake host and Noise IK device the hub's tests share. It holds no tests: `node --test` loads it and finds none.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import type { Event, Message, PeerInfo } from "../src/envelope.ts";
import type { HubOptions, Link } from "../src/hub.ts";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  },
});
const { Hub } = await import("../src/hub.ts");
const { encodeEvent, parseEvent } = await import("../src/envelope.ts");
const { b64u, decodeFrame, ed25519Keypair, encodeFrame, NoiseIK, prologue, roomId, signFrame, x25519Keypair } =
  await import("../src/wire.ts");

export const peer: PeerInfo = { app: "test", protocolMin: 3, protocolMax: 3, capabilities: [] };
export const hello: Event = { kind: "peer_info", data: peer };
export const convId = "11111111-1111-4111-8111-111111111111";
export const messageId = "22222222-2222-4222-8222-222222222222";
export const answer: Event = { kind: "conv_list", data: { conversations: [] } };
export const newDevice = () => ({ signing: ed25519Keypair(), static: x25519Keypair() });

// Same fake Link and Noise IK setup as pairing.test.ts and apps/relay/src/direct.test.ts.
export function host(options: Partial<Pick<HubOptions, "onPeer" | "dispatch" | "directHints">> = {}) {
  const keys = { static: x25519Keypair(), room: roomId(ed25519Keypair().publicKey) };
  const device = newDevice();
  const deviceKey = b64u(device.signing.publicKey);
  const allowed = new Map([[deviceKey, b64u(device.static.publicKey)]]);
  const messages: Message[] = [];
  const hub = new Hub({
    keys, peerInfo: () => peer,
    staticKeyOf: async (key) => allowed.get(key),
    onMessage: (message) => { messages.push(message); },
    dispatch: async () => false,
    ...options,
  });

  async function connect(deviceKeys = device, via?: { link: Link; sent: string[]; closed: { code: number; reason: string }[] }) {
    const deviceKey = b64u(deviceKeys.signing.publicKey);
    allowed.set(deviceKey, b64u(deviceKeys.static.publicKey));
    const sent: string[] = via?.sent ?? [];
    const closed: { code: number; reason: string }[] = via?.closed ?? [];
    const link: Link = via?.link ?? {
      path: "direct", send: (payloads) => { sent.push(...payloads); },
      close: (code, reason) => { closed.push({ code, reason }); },
    };
    const ik = new NoiseIK("initiator", deviceKeys.static, keys.static.publicKey, prologue(keys.room, deviceKeys.signing.publicKey));
    const message = ik.writeMessage(Buffer.from(JSON.stringify({ ts: Date.now() })));
    const payload = encodeFrame({ type: "init", deviceSigningKey: deviceKeys.signing.publicKey, message });
    assert.equal(await hub.handshake(payload, signFrame(deviceKeys.signing.privateKey, payload), link), deviceKey);
    const response = decodeFrame(sent.shift()!);
    assert.ok(response?.type === "response");
    ik.readMessage(response.message);
    const session = ik.split(message.subarray(0, 8));

    /** Everything sent so far, as the JSON on the wire: what a client reads, including kinds `parseEvent` takes from no device. */
    function wire(): unknown[] {
      return sent.splice(0).map((payload) => {
        const frame = decodeFrame(payload);
        assert.ok(frame?.type === "box");
        const plain = session.open(frame);
        assert.ok(plain, "the intended session can decrypt its reply");
        return JSON.parse(plain.toString("utf8"));
      });
    }
    function drain() {
      return wire().map((value) => {
        const event = parseEvent(Buffer.from(JSON.stringify(value)));
        assert.ok(event && event.kind !== "invalid" && event.kind !== "unknown");
        return event;
      });
    }
    assert.deepEqual(drain(), [hello]);
    function seal(event: Event) {
      const frame = decodeFrame(session.seal(encodeEvent(event)));
      assert.ok(frame?.type === "box");
      return frame;
    }
    function open(event: Event) {
      const frame = seal(event);
      const opened = hub.open(frame, link);
      assert.ok(opened, "the original link opens its session's frame before replacement/end");
      return opened;
    }
    return { deviceKey, link, sent, closed, wire, drain, seal, open, send: (event: Event) => hub.handle(open(event)) };
  }
  return { hub, deviceKey, messages, connect };
}
