import { createHmac } from "node:crypto";
import { createSocket, type RemoteInfo, type Socket } from "node:dgram";
import { isIP } from "node:net";
import { directAddress } from "./direct.js";
import type { Log } from "./hub.js";

const GROUP = "224.0.0.251";
const PORT = 5353;
export const SERVICE = "_yorozu._tcp.local";
export const bonjourTag = (hostStaticPub: Uint8Array): string => {
  if (hostStaticPub.length !== 32) throw new Error("expected a 32-byte static public key");
  return createHmac("sha256", hostStaticPub).update("yorozu-bonjour").digest().subarray(0, 9).toString("base64url");
};

export function encodeName(name: string): Buffer {
  const labels = name.replace(/\.$/, "").split(".");
  if (labels.some((label) => !label.length || Buffer.byteLength(label) > 63)) throw new Error("invalid DNS name");
  const bytes = Buffer.concat([...labels.map((label) => Buffer.concat([Buffer.from([Buffer.byteLength(label)]), Buffer.from(label)])), Buffer.from([0])]);
  if (bytes.length > 255) throw new Error("DNS name too long");
  return bytes;
}

export function decodeName(packet: Buffer, offset: number): { name: string; offset: number } {
  const labels: string[] = [];
  const seen = new Set<number>();
  let end: number | undefined;
  let length = 1;
  for (;;) {
    if (offset >= packet.length || seen.has(offset)) throw new Error("invalid DNS name");
    seen.add(offset);
    const size = packet[offset++]!;
    if ((size & 0xc0) === 0xc0) {
      if (offset >= packet.length) throw new Error("short DNS pointer");
      end ??= offset + 1;
      offset = ((size & 0x3f) << 8) | packet[offset]!;
      continue;
    }
    if (size & 0xc0 || offset + size > packet.length) throw new Error("invalid DNS label");
    if (!size) return { name: labels.join("."), offset: end ?? offset };
    length += size + 1;
    if (length > 255) throw new Error("DNS name too long");
    labels.push(packet.subarray(offset, offset + size).toString("utf8"));
    offset += size;
  }
}

type Question = { name: string; type: number; qu: boolean };
export function parseQuery(packet: Buffer): { id: number; questions: Question[] } | null {
  if (packet.length < 12 || packet.length > 9000 || (packet.readUInt16BE(2) & 0xf800)) return null;
  try {
    let offset = 12;
    const questions: Question[] = [];
    for (let i = 0; i < packet.readUInt16BE(4); i++) {
      const decoded = decodeName(packet, offset);
      offset = decoded.offset;
      const type = packet.readUInt16BE(offset);
      const cls = packet.readUInt16BE(offset + 2);
      offset += 4;
      if ((cls & 0x7fff) === 1 || (cls & 0x7fff) === 255) questions.push({ name: decoded.name.toLowerCase(), type, qu: !!(cls & 0x8000) });
    }
    // Validate known-answer and additional records too; malformed datagrams never elicit traffic.
    const records = packet.readUInt16BE(6) + packet.readUInt16BE(8) + packet.readUInt16BE(10);
    for (let i = 0; i < records; i++) {
      offset = decodeName(packet, offset).offset;
      const length = packet.readUInt16BE(offset + 8);
      offset += 10 + length;
      if (offset > packet.length) return null;
    }
    if (offset !== packet.length) return null;
    return { id: packet.readUInt16BE(0), questions };
  } catch { return null; }
}

const u16 = (n: number) => { const b = Buffer.alloc(2); b.writeUInt16BE(n); return b; };
export function buildResponse(tag: string, port: number, address: string, ttl = 120, id = 0): Buffer {
  if (isIP(address) !== 4) throw new Error("Bonjour requires IPv4");
  const instance = `${tag}.${SERVICE}`;
  const host = `${tag}.local`;
  const record = (name: string, type: number, data: Buffer) => {
    const header = Buffer.alloc(10);
    header.writeUInt16BE(type);
    header.writeUInt16BE(type === 12 ? 1 : 0x8001, 2);
    header.writeUInt32BE(ttl, 4);
    header.writeUInt16BE(data.length, 8);
    return Buffer.concat([encodeName(name), header, data]);
  };
  const text = Buffer.from(`t=${tag}`);
  const records = [record(SERVICE, 12, encodeName(instance)),
    record(instance, 33, Buffer.concat([u16(0), u16(0), u16(port), encodeName(host)])),
    record(instance, 16, Buffer.concat([Buffer.from([text.length]), text])),
    record(host, 1, Buffer.from(address.split(".").map(Number)))];
  const header = Buffer.alloc(12);
  header.writeUInt16BE(id);
  header.writeUInt16BE(0x8400, 2);
  header.writeUInt16BE(records.length, 6);
  return Buffer.concat([header, ...records]);
}

type Address = { address: string; prefix: number };
type Receiver = { socket: Socket; handlers: Set<(packet: Buffer, remote: RemoteInfo) => void>; memberships: Map<string, number> };
let receiver: Promise<Receiver> | undefined;
async function receiveSocket(): Promise<Receiver> {
  // One receive socket per process; replies use per-interface sockets (macOS cannot send from the group bind).
  return receiver ??= (async () => {
    const socket = createSocket({ type: "udp4", reuseAddr: true });
    socket.on("error", () => {});
    await bind(socket, GROUP);
    const handlers: Receiver["handlers"] = new Set();
    socket.on("message", (packet, remote) => { for (const handler of handlers) handler(packet, remote); });
    return { socket, handlers, memberships: new Map() };
  })().catch((error: unknown) => { receiver = undefined; throw error; });
}
function bind(socket: Socket, address: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const fail = (error: Error) => { socket.close(); reject(error); };
    socket.once("error", fail);
    socket.bind(PORT, address, () => { socket.removeListener("error", fail); socket.unref(); resolve(); });
  });
}
const ipv4 = (address: string) => address.split(".").reduce((n, part) => (n * 256 + Number(part)) >>> 0, 0);
export function sameSubnet(local: Address, remote: string): boolean {
  if (isIP(remote) !== 4) return false;
  const mask = local.prefix === 0 ? 0 : (0xffffffff << (32 - local.prefix)) >>> 0;
  return (ipv4(local.address) & mask) === (ipv4(remote) & mask);
}

/** IPv4 only for now. Production passes LAN hints; an injected loopback address permits the integration test. */
export async function serveBonjour(opts: { hostStaticPub: Uint8Array; port: number; addresses: Address[]; log?: Log }): Promise<{
  update: (addresses: Address[]) => Promise<void>; close: () => Promise<void>;
}> {
  const tag = bonjourTag(opts.hostStaticPub);
  const senders = new Map<string, { socket: Socket; info: Address }>();
  let rx: Receiver | undefined;
  let closed = false;
  let announceTimer: NodeJS.Timeout | undefined;
  const send = (socket: Socket, address: string, ttl = 120, remote?: RemoteInfo, id = 0): Promise<void> =>
    new Promise((resolve) => socket.send(buildResponse(tag, opts.port, address, ttl, id), remote?.port ?? PORT, remote?.address ?? GROUP, () => resolve()));
  const answer = (packet: Buffer, remote: RemoteInfo) => {
    const query = parseQuery(packet);
    if (!query) return;
    const matching = query.questions.filter((q) => {
      const name = q.name;
      return (name === SERVICE && (q.type === 12 || q.type === 255)) ||
        (name === `${tag}.${SERVICE}`.toLowerCase() && [16, 33, 255].includes(q.type)) ||
        (name === `${tag}.local`.toLowerCase() && [1, 255].includes(q.type));
    });
    if (!matching.length) return;
    const sender = [...senders.values()].find((s) => sameSubnet(s.info, remote.address)) ?? senders.values().next().value;
    if (sender) void send(sender.socket, sender.info.address, 120, matching.some((q) => q.qu) ? remote : undefined, matching.some((q) => q.qu) ? query.id : 0);
  };
  const remove = async (address: string) => {
    const sender = senders.get(address);
    if (!sender) return;
    senders.delete(address);
    await send(sender.socket, address, 0);
    sender.socket.close();
    if (rx) {
      const count = (rx.memberships.get(address) ?? 1) - 1;
      if (count) rx.memberships.set(address, count);
      else {
        rx.memberships.delete(address);
        try { rx.socket.dropMembership(GROUP, address); } catch {}
      }
    }
  };
  const update = async (addresses: Address[]) => {
    if (closed) return;
    clearTimeout(announceTimer);
    const allowed = addresses.filter((i) => isIP(i.address) === 4 && directAddress(i.address) &&
      !i.address.startsWith("100.") && Number.isInteger(i.prefix) && i.prefix >= 0 && i.prefix <= 32);
    for (const address of senders.keys()) if (!allowed.some((i) => i.address === address)) await remove(address);
    for (const info of allowed) {
      const old = senders.get(info.address);
      if (old) { old.info = info; continue; }
      let socket: Socket | undefined;
      let joined = false;
      try {
        rx ??= await receiveSocket();
        rx.handlers.add(answer);
        if (!rx.memberships.has(info.address)) { rx.socket.addMembership(GROUP, info.address); joined = true; }
        socket = createSocket({ type: "udp4", reuseAddr: true });
        socket.on("error", () => {});
        await bind(socket, info.address);
        socket.setMulticastInterface(info.address);
        socket.setMulticastTTL(255);
        rx.memberships.set(info.address, (rx.memberships.get(info.address) ?? 0) + 1);
        senders.set(info.address, { socket, info });
      } catch (error) {
        try { socket?.close(); } catch {}
        if (joined) { try { rx?.socket.dropMembership(GROUP, info.address); } catch {} }
        opts.log?.warn(`yorozu: Bonjour on ${info.address} failed: ${String(error)}`);
      }
    }
    const announce = () => { for (const { socket, info } of senders.values()) void send(socket, info.address); };
    announce();
    announceTimer = setTimeout(announce, 1_000);
    announceTimer.unref();
  };
  await update(opts.addresses);
  return { update, close: async () => {
    closed = true;
    clearTimeout(announceTimer);
    for (const address of senders.keys()) await remove(address);
    if (rx) {
      rx.handlers.delete(answer);
      if (!rx.handlers.size) { rx.socket.close(); receiver = undefined; }
    }
  } };
}
