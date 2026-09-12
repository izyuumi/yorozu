/**
 * Client helpers for exercising a running relay. Shipped with the package (not with the
 * tests) so the runtime sidecar's tests can drive a fake phone through the real protocol.
 */
import { generateKeyPairSync, type KeyObject } from "node:crypto";
import WebSocket from "ws";
import { roomId, signChallenge } from "./index.js";

export interface Keys {
  /** Raw Ed25519 public key, base64url, as the relay expects it. */
  pub: string;
  priv: KeyObject;
}

export function keypair(): Keys {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return { pub: publicKey.export({ format: "jwk" }).x as string, priv: privateKey };
}

export type Client = ReturnType<typeof client>;

/**
 * Where a test client dials: a port on localhost, or a full URL so the same helpers can be
 * pointed at a deployed relay.
 */
export type Target = number | string;

/**
 * Minimal client: queue inbound JSON so callers can await messages in order. `room` becomes
 * the `?room=` the Worker relay routes on; the Node relay ignores it.
 */
export function client(target: Target, room?: string) {
  const url = new URL(typeof target === "number" ? `ws://127.0.0.1:${target}` : target);
  if (room) url.searchParams.set("room", room);
  const ws = new WebSocket(url);
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
    /** Signs and sends an opaque frame the way a paired device does. */
    frame: (payload: string, keys: Keys) =>
      ws.send(JSON.stringify({ type: "frame", payload, sig: signChallenge(payload, keys.priv) })),
    next: (): Promise<any> =>
      queue.length > 0 ? Promise.resolve(queue.shift()) : new Promise((r) => waiters.push(r)),
    closed: new Promise<number>((r) => ws.on("close", (code) => r(code))),
    open: new Promise<void>((r) => ws.on("open", () => r())),
  };
}

export async function connectMac(target: Target, keys: Keys): Promise<Client> {
  const mac = client(target, roomId(keys.pub));
  await mac.open;
  const { nonce } = await mac.next();
  mac.send({ type: "register", pubkey: keys.pub, nonceSig: signChallenge(nonce, keys.priv) });
  const registered = await mac.next();
  if (registered?.roomId !== roomId(keys.pub)) {
    throw new Error(`unexpected registration reply: ${JSON.stringify(registered)}`);
  }
  return mac;
}

export async function mintToken(mac: Client): Promise<string> {
  mac.send({ type: "mint" });
  const { token } = await mac.next();
  return token as string;
}

/**
 * Rejoins a room as a device it already knows: no token, and the signature is over the connect
 * nonce. Does not await the `joined` reply.
 */
export async function rejoinPhone(target: Target, room: string, keys: Keys): Promise<Client> {
  const phone = client(target, room);
  await phone.open;
  const { nonce } = await phone.next();
  phone.send({
    type: "join",
    roomId: room,
    phonePubkey: keys.pub,
    sig: signChallenge(nonce, keys.priv),
  });
  return phone;
}

/** Joins a room with a fresh phone identity. Does not await the `joined` reply. */
export async function connectPhone(
  target: Target,
  room: string,
  token: string,
): Promise<{ phone: Client; keys: Keys }> {
  const keys = keypair();
  const phone = client(target, room);
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
