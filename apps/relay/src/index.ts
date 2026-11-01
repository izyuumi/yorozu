import { createHash, createPublicKey, randomBytes, sign, verify, type KeyObject } from "node:crypto";
import { isIP, type AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";
import type { IncomingHttpHeaders } from "node:http";
import {
  allowFrame,
  allowNotify,
  AUTH_TIMEOUT_MS,
  CLOSE_BAD_SIGNATURE,
  CLOSE_POLICY,
  CLOSE_PROTOCOL,
  CLOSE_RATE_LIMIT,
  dropCount,
  evictions,
  frameWire,
  newBucket,
  MAX_PAYLOAD_BYTES,
  PHONE_BUFFER_CAP_BYTES,
  MAX_TOKENS_PER_ROOM,
  NOTIFY_PER_MINUTE,
  parseAck,
  parseDevices,
  parseEnvelope,
  parseFrames,
  parseJoin,
  parseNotify,
  parsePush,
  parseRegister,
  parseRevoke,
  PING,
  positiveLimit,
  PONG,
  safeReason,
  TOKEN_TTL_MS,
  type Bucket,
  type NotifyWindow,
} from "./protocol.js";

export function roomId(macPublicKey: string): string {
  return createHash("sha256").update(Buffer.from(macPublicKey, "base64url")).digest("base64url");
}

function publicKeyFrom(base64url: string): KeyObject {
  return createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: base64url }, format: "jwk" });
}

export function signChallenge(data: string, key: KeyObject): string {
  return sign(null, Buffer.from(data), key).toString("base64url");
}

function verifySignature(data: string, signature: string, key: KeyObject): boolean {
  try {
    return verify(null, Buffer.from(data), key, Buffer.from(signature, "base64url"));
  } catch {
    return false;
  }
}

export function trustedHops(value: string | undefined): number {
  if (!value) return 0;
  const hops = Number(value);
  return Number.isSafeInteger(hops) && hops > 0 ? hops : 1;
}

export function clientIp(headers: IncomingHttpHeaders, peer: string | undefined, hops: number): string {
  const fallback = peer ?? "unknown";
  if (hops === 0) return fallback;
  const cf = headers["cf-connecting-ip"];
  const cfIp = (Array.isArray(cf) ? cf[0] : cf)?.trim();
  if (cfIp && isIP(cfIp)) return cfIp;
  const forwarded = headers["x-forwarded-for"];
  const chain = (Array.isArray(forwarded) ? forwarded.join(",") : (forwarded ?? ""))
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry !== "");
  const ip = chain.length >= hops ? chain[chain.length - hops] : undefined;
  return ip && isIP(ip) ? ip : fallback;
}

type Buffered = { raw: string; bytes: number; at: number; seq: number };

function log(ev: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ ev, ...fields }));
}

type Room = {
  mac: WebSocket | null;
  seq: number;
  phones: Set<WebSocket>;
  tokens: Map<string, number>;
  devices: Map<string, number>;
  pushTokens: Map<string, string>;
  buffer: Buffered[];
  notifyWindow: NotifyWindow;
};

type Conn = {
  nonce: string;
  role: "mac" | "phone" | null;
  room: Room | null;
  roomId: string | null;
  key: KeyObject | null;
  bucket: Bucket;
};

function newRoom(): Room {
  return {
    mac: null,
    seq: 0,
    phones: new Set(),
    tokens: new Map(),
    devices: new Map(),
    pushTokens: new Map(),
    buffer: [],
    notifyWindow: { count: 0, startedAt: Date.now() },
  };
}

function sweepTokens(room: Room, now: number): void {
  for (const [token, expiresAt] of room.tokens) if (now > expiresAt) room.tokens.delete(token);
}

function trimBuffer(room: Room, now: number): void {
  const drop = dropCount(room.buffer, now);
  if (drop > 0) {
    log("buffer-trim", { dropped: drop, kept: room.buffer.length - drop });
    room.buffer.splice(0, drop);
  }
}

function bufferFrame(room: Room, raw: string, now: number): void {
  room.buffer.push({ raw, bytes: Buffer.byteLength(raw), at: now, seq: room.seq++ });
  trimBuffer(room, now);
}

function sendPhone(phone: WebSocket, raw: string): void {
  if (phone.readyState !== phone.OPEN) return;
  if (phone.bufferedAmount + Buffer.byteLength(raw) > PHONE_BUFFER_CAP_BYTES) {
    log("slow-phone", { bufferedBytes: phone.bufferedAmount });
    phone.close(1013, "slow receiver");
    return;
  }
  phone.send(raw);
}

function notifyPhones(room: Room): void {
  room.mac?.send(JSON.stringify({ type: "phones", count: room.phones.size }));
}

function notifyOwner(room: Room, online: boolean): void {
  const raw = JSON.stringify({ type: "owner", online });
  for (const phone of room.phones) sendPhone(phone, raw);
}

function drainBuffer(room: Room, mac: WebSocket, now: number): void {
  trimBuffer(room, now);
  if (room.buffer.length === 0) return;
  log("drain", { count: room.buffer.length });
  for (const entry of room.buffer) {
    mac.send(JSON.stringify({ ...(JSON.parse(entry.raw) as object), seq: entry.seq }));
  }
}

function ackBuffer(room: Room, seq: number): void {
  room.buffer = room.buffer.filter((entry) => entry.seq > seq);
}

export type Relay = { port: number; close: () => Promise<void> };

export function startRelay(port = Number(process.env.PORT ?? 8787)): Promise<Relay> {
  const rooms = new Map<string, Room>();
  const phoneKeys = new WeakMap<WebSocket, string>();
  const maxConnections = positiveLimit(process.env.RELAY_MAX_CONNS_PER_IP, 32);
  const maxTokens = positiveLimit(process.env.RELAY_MAX_TOKENS_PER_ROOM, MAX_TOKENS_PER_ROOM);
  const notifyLimit = positiveLimit(process.env.RELAY_NOTIFY_PER_MINUTE, NOTIFY_PER_MINUTE);
  const trustedProxies = trustedHops(process.env.RELAY_TRUST_PROXY);
  const connections = new Map<string, number>();
  const wss = new WebSocketServer({ port, maxPayload: MAX_PAYLOAD_BYTES });

  const forget = (room: Room, pubkeys: readonly string[]): void => {
    const gone = new Set(pubkeys);
    for (const pubkey of gone) {
      room.devices.delete(pubkey);
      room.pushTokens.delete(pubkey);
    }
    for (const phone of room.phones) {
      const key = phoneKeys.get(phone);
      if (key && gone.has(key)) phone.close(CLOSE_PROTOCOL, "revoked");
    }
  };

  const remember = (room: Room, pubkey: string, now: number): void => {
    forget(room, evictions([...room.devices], pubkey));
    room.devices.set(pubkey, now);
  };

  const dropRoomIfIdle = (id: string, room: Room): void => {
    if (
      !room.mac &&
      room.phones.size === 0 &&
      room.buffer.length === 0 &&
      room.tokens.size === 0 &&
      room.devices.size === 0
    ) {
      rooms.delete(id);
      log("room-drop");
    }
  };

  const sweep = setInterval(() => {
    const now = Date.now();
    for (const [id, room] of rooms) {
      sweepTokens(room, now);
      trimBuffer(room, now);
      dropRoomIfIdle(id, room);
    }
  }, 60_000);
  sweep.unref();
  wss.on("close", () => clearInterval(sweep));

  wss.on("connection", (ws, request) => {
    ws.on("error", (error) => log("error", { error: safeReason(error.message) }));
    const ip = clientIp(request.headers, request.socket.remoteAddress, trustedProxies);
    const count = connections.get(ip) ?? 0;
    if (count >= maxConnections) {
      log("drop", { code: CLOSE_POLICY, reason: "connection limit" });
      ws.close(CLOSE_POLICY, "connection limit");
      return;
    }
    connections.set(ip, count + 1);
    ws.once("close", () => {
      const remaining = (connections.get(ip) ?? 1) - 1;
      if (remaining === 0) connections.delete(ip);
      else connections.set(ip, remaining);
    });
    const conn: Conn = {
      nonce: randomBytes(32).toString("base64url"),
      role: null,
      room: null,
      roomId: null,
      key: null,
      bucket: newBucket(Date.now()),
    };
    ws.send(JSON.stringify({ type: "nonce", nonce: conn.nonce }));
    const authTimer = setTimeout(() => {
      if (conn.role !== null) return;
      log("drop", { code: CLOSE_POLICY, reason: "auth timeout" });
      ws.close(CLOSE_POLICY, "auth timeout");
    }, AUTH_TIMEOUT_MS);
    ws.once("close", () => clearTimeout(authTimer));

    ws.on("message", (data) => {
      if (ws.readyState !== ws.OPEN) return;
      const now = Date.now();
      const raw = data.toString();
      if (raw === PING) return ws.send(PONG);
      if (!allowFrame(conn.bucket, now)) return ws.close(CLOSE_RATE_LIMIT, "rate limit");

      const msg = parseEnvelope(raw);
      if (!msg) return ws.close(CLOSE_PROTOCOL, "bad json");

      switch (msg.type) {
        case "ping":
          return ws.send(PONG);

        case "owner": {
          if (conn.role !== "phone" || !conn.room) return ws.close(CLOSE_PROTOCOL, "not joined");
          return ws.send(JSON.stringify({ type: "owner", online: conn.room.mac !== null }));
        }

        case "register": {
          const reg = parseRegister(msg);
          if (!reg) return ws.close(CLOSE_PROTOCOL, "bad register");
          const { pubkey, nonceSig } = reg;
          let key: KeyObject;
          try {
            key = publicKeyFrom(pubkey);
          } catch {
            return ws.close(CLOSE_PROTOCOL, "bad pubkey");
          }
          if (!verifySignature(conn.nonce, nonceSig, key)) {
            return ws.close(CLOSE_BAD_SIGNATURE, "bad challenge");
          }
          const id = roomId(pubkey);
          if (conn.role && (conn.role !== "mac" || conn.roomId !== id)) {
            return ws.close(CLOSE_PROTOCOL, "already joined");
          }
          const room = rooms.get(id) ?? newRoom();
          rooms.set(id, room);
          if (room.mac && room.mac !== ws) room.mac.close(CLOSE_PROTOCOL, "replaced");
          room.mac = ws;
          conn.role = "mac";
          conn.room = room;
          conn.roomId = id;
          conn.key = key;
          clearTimeout(authTimer);
          ws.send(JSON.stringify({ type: "registered", roomId: id, phones: room.phones.size }));
          log("registered", { phones: room.phones.size });
          notifyOwner(room, true);
          drainBuffer(room, ws, now);
          return;
        }

        case "ack": {
          if (conn.role !== "mac" || !conn.room) return ws.close(CLOSE_PROTOCOL, "not registered");
          const ack = parseAck(msg);
          if (!ack) return ws.close(CLOSE_PROTOCOL, "bad ack");
          return ackBuffer(conn.room, ack.seq);
        }

        case "mint": {
          if (conn.role !== "mac" || !conn.room) return ws.close(CLOSE_PROTOCOL, "not registered");
          sweepTokens(conn.room, now);
          while (conn.room.tokens.size >= maxTokens) {
            conn.room.tokens.delete(conn.room.tokens.keys().next().value!);
          }
          const token = randomBytes(32).toString("base64url");
          const expiresAt = now + TOKEN_TTL_MS;
          conn.room.tokens.set(token, expiresAt);
          ws.send(JSON.stringify({ type: "token", token, expiresAt }));
          return;
        }

        case "revoke": {
          if (conn.role !== "mac" || !conn.room) return ws.close(CLOSE_PROTOCOL, "not registered");
          const revoke = parseRevoke(msg);
          if (!revoke) return ws.close(CLOSE_PROTOCOL, "bad revoke");
          forget(conn.room, [revoke.pubkey]);
          return;
        }

        case "devices": {
          if (conn.role !== "mac" || !conn.room) return ws.close(CLOSE_PROTOCOL, "not registered");
          const announced = parseDevices(msg);
          if (!announced) return ws.close(CLOSE_PROTOCOL, "bad devices");
          const keep = new Set(announced.devices);
          const room = conn.room;
          for (const phone of room.phones) {
            const key = phoneKeys.get(phone);
            if (key) keep.add(key);
          }
          for (const pubkey of keep) if (!room.devices.has(pubkey)) room.devices.set(pubkey, now);
          forget(room, [...room.devices.keys()].filter((pubkey) => !keep.has(pubkey)));
          return;
        }

        case "join": {
          const join = parseJoin(msg);
          if (!join) return ws.close(CLOSE_PROTOCOL, "bad join");
          const { roomId: id, token, phonePubkey, sig } = join;
          if (conn.role && (conn.role !== "phone" || conn.roomId !== id)) {
            return ws.close(CLOSE_PROTOCOL, "already joined");
          }
          const room = rooms.get(id) ?? newRoom();
          let key: KeyObject;
          try {
            key = publicKeyFrom(phonePubkey);
          } catch {
            return ws.close(CLOSE_PROTOCOL, "bad pubkey");
          }
          if (token === undefined) {
            if (!room.devices.has(phonePubkey)) return ws.close(CLOSE_PROTOCOL, "unknown device");
            if (!verifySignature(conn.nonce, sig, key)) {
              return ws.close(CLOSE_BAD_SIGNATURE, "bad join signature");
            }
            room.devices.set(phonePubkey, now);
          } else {
            const expiresAt = room.tokens.get(token);
            if (expiresAt === undefined) return ws.close(CLOSE_PROTOCOL, "unknown token");
            if (now > expiresAt) {
              room.tokens.delete(token);
              return ws.close(CLOSE_PROTOCOL, "expired token");
            }
            if (!verifySignature(token, sig, key)) {
              return ws.close(CLOSE_BAD_SIGNATURE, "bad join signature");
            }
            room.tokens.delete(token);
            remember(room, phonePubkey, now);
          }
          room.phones.add(ws);
          phoneKeys.set(ws, phonePubkey);
          conn.role = "phone";
          conn.room = room;
          conn.roomId = id;
          conn.key = key;
          clearTimeout(authTimer);
          ws.send(JSON.stringify({ type: "joined", roomId: id, ownerOnline: room.mac !== null }));
          notifyPhones(room);
          return;
        }

        case "frame": {
          if (!conn.role || !conn.room || !conn.key) return ws.close(CLOSE_PROTOCOL, "not joined");
          const frames = parseFrames(msg);
          if (!frames) return ws.close(CLOSE_BAD_SIGNATURE, "unsigned frame");
          if (msg.frames !== undefined && conn.role === "phone") {
            return ws.close(CLOSE_PROTOCOL, "batch from phone");
          }
          for (const { payload, sig } of frames) {
            if (!verifySignature(payload, sig, conn.key)) {
              return ws.close(CLOSE_BAD_SIGNATURE, "bad frame signature");
            }
          }

          if (conn.role === "phone") {
            const mac = conn.room.mac;
            if (mac) mac.send(raw);
            else bufferFrame(conn.room, raw, now);
            ws.send(JSON.stringify({ type: "accepted", sig: frames[0]!.sig, buffered: !mac }));
          } else {
            const wires = msg.frames === undefined ? [raw] : frames.map(frameWire);
            for (const phone of conn.room.phones) for (const wire of wires) sendPhone(phone, wire);
          }
          return;
        }

        case "push": {
          if (conn.role !== "phone" || !conn.room) return ws.close(CLOSE_PROTOCOL, "not joined");
          const push = parsePush(msg);
          if (!push) return ws.close(CLOSE_PROTOCOL, "bad push");
          const pubkey = phoneKeys.get(ws);
          if (pubkey) {
            for (const [other, token] of conn.room.pushTokens) {
              if (other !== pubkey && token === push.deviceToken) conn.room.pushTokens.delete(other);
            }
            conn.room.pushTokens.set(pubkey, push.deviceToken);
          }
          return;
        }

        case "notify": {
          if (conn.role !== "mac" || !conn.room) return ws.close(CLOSE_PROTOCOL, "not registered");
          const notify = parseNotify(msg);
          if (notify === null) return ws.close(CLOSE_PROTOCOL, "bad notify");
          if (!notify) return;
          if (!allowNotify(conn.room.notifyWindow, now, notifyLimit)) {
            ws.send(JSON.stringify({ type: "state", state: "notify rate limit" }));
          }
          return;
        }

        default:
          return; // An unknown type is ignored (it still costs a rate-limit token).
      }
    });

    ws.on("close", (code, reason) => {
      const { room, roomId: id } = conn;
      log("close", { role: conn.role, code, reason: safeReason(reason.toString()) });
      if (!room || !id) return;
      if (room.mac === ws) {
        room.mac = null;
        notifyOwner(room, false);
      }
      if (room.phones.delete(ws)) notifyPhones(room);
      dropRoomIfIdle(id, room);
    });
  });

  return new Promise((resolve) => {
    wss.on("listening", () =>
      resolve({
        port: (wss.address() as AddressInfo).port,
        close: () =>
          new Promise((done) => {
            clearInterval(sweep);
            for (const client of wss.clients) client.terminate();
            wss.close(() => done());
          }),
      }),
    );
  });
}

if (import.meta.main) {
  const relay = await startRelay();
  console.log(`relay listening on :${relay.port}`);
}
