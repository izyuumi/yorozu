import { createHash, createPublicKey, randomBytes, sign, verify, type KeyObject } from "node:crypto";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";
import {
  allowFrame,
  CLOSE_BAD_SIGNATURE,
  CLOSE_PROTOCOL,
  CLOSE_RATE_LIMIT,
  dropCount,
  evictions,
  frameWire,
  newBucket,
  parseAck,
  parseDevices,
  parseEnvelope,
  parseFrames,
  parseJoin,
  parsePush,
  parseRegister,
  parseRevoke,
  PING,
  PONG,
  safeReason,
  TOKEN_TTL_MS,
  type Bucket,
} from "./protocol.js";

/** Room ID is derived from the Mac public key; the relay never reads payloads. */
export function roomId(macPublicKey: string): string {
  return createHash("sha256").update(Buffer.from(macPublicKey, "base64url")).digest("base64url");
}

/** Raw 32-byte Ed25519 public key, base64url, as carried in the pairing QR. */
function publicKeyFrom(base64url: string): KeyObject {
  return createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: base64url }, format: "jwk" });
}

/** Sign an ASCII challenge with a raw Ed25519 key. Exported for clients and tests. */
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

type Buffered = { raw: string; bytes: number; at: number; seq: number };

/** One line per socket event, the same shape as the Worker's, so both relays read alike. */
function log(ev: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ ev, ...fields }));
}

type Room = {
  mac: WebSocket | null;
  /** Next buffer sequence number; never reused, so an ack cannot name a later frame. */
  seq: number;
  phones: Set<WebSocket>;
  /** token -> expiry epoch ms. Deleted on use: one-time. */
  tokens: Map<string, number>;
  /**
   * Phone signing pubkey -> when it last paired or rejoined. A known device rejoins against
   * the connect nonce, so a background or a network change does not cost a new token.
   */
  devices: Map<string, number>;
  /**
   * Phone signing pubkey -> APNs device token. Kept, as the Worker keeps it, so the two relays
   * hold the same state; this one has no Apple key and never sends to it.
   */
  pushTokens: Map<string, string>;
  buffer: Buffered[];
};

type Conn = {
  nonce: string;
  role: "mac" | "phone" | null;
  room: Room | null;
  roomId: string | null;
  /** Key whose signature every frame from this socket must carry. */
  key: KeyObject | null;
  /** Per socket: a flooding phone closes itself and nobody else. */
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
  };
}

/** Expired tokens go on mint, so a token nobody redeemed does not sit in memory forever. */
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

/**
 * Tells the room's phones whether its Mac holds a live socket, so they can show an offline
 * banner instead of a silent send. This is routing state the relay already keeps — it says
 * nothing about the ciphertext, so the relay stays blind.
 */
function notifyOwner(room: Room, online: boolean): void {
  const raw = JSON.stringify({ type: "owner", online });
  for (const phone of room.phones) phone.send(raw);
}

/**
 * Replays the buffer, each frame tagged with its sequence, and keeps it until the Mac acks:
 * a send onto a socket that is about to die is not a delivery. The runtime is idempotent on
 * event id, so a Mac that reconnects without acking harmlessly sees the frames again.
 */
function drainBuffer(room: Room, mac: WebSocket, now: number): void {
  trimBuffer(room, now);
  if (room.buffer.length === 0) return;
  log("drain", { count: room.buffer.length });
  for (const entry of room.buffer) {
    mac.send(JSON.stringify({ ...(JSON.parse(entry.raw) as object), seq: entry.seq }));
  }
  // Entries without a sequence cannot be acked, so they are let go on send. Every entry this
  // relay writes has one; the rule is here so both relays drain alike.
  room.buffer = room.buffer.filter((entry) => entry.seq !== undefined);
}

function ackBuffer(room: Room, seq: number): void {
  room.buffer = room.buffer.filter((entry) => entry.seq > seq);
}

export type Relay = { port: number; close: () => Promise<void> };

export function startRelay(port = Number(process.env.PORT ?? 8787)): Promise<Relay> {
  const rooms = new Map<string, Room>();
  /** Which device each phone socket joined as, so a revoke can close exactly that one. */
  const phoneKeys = new WeakMap<WebSocket, string>();
  const wss = new WebSocketServer({ port });

  /**
   * Drops devices the Mac no longer considers paired: forgotten, so they cannot rejoin
   * against the nonce, and their sockets go now rather than at their next reconnect.
   */
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

  /** Records a phone as a device this room knows. Capped, oldest evicted first. */
  const remember = (room: Room, pubkey: string, now: number): void => {
    forget(room, evictions([...room.devices], pubkey));
    room.devices.set(pubkey, now);
  };

  const dropRoomIfIdle = (id: string, room: Room): void => {
    // A room with known devices is kept: forgetting it would strand every paired phone on its
    // next rejoin. Only a room nobody ever paired to is dropped.
    if (
      !room.mac &&
      room.phones.size === 0 &&
      room.buffer.length === 0 &&
      room.tokens.size === 0 &&
      room.devices.size === 0
    ) {
      rooms.delete(id);
    }
  };

  wss.on("connection", (ws) => {
    const conn: Conn = {
      nonce: randomBytes(32).toString("base64url"),
      role: null,
      room: null,
      roomId: null,
      key: null,
      bucket: newBucket(Date.now()),
    };
    ws.send(JSON.stringify({ type: "nonce", nonce: conn.nonce }));

    ws.on("message", (data) => {
      const raw = data.toString();
      const now = Date.now();

      // Only the envelope is parsed; `payload` is forwarded byte-for-byte.
      const msg = parseEnvelope(raw);
      if (!msg) return ws.close(CLOSE_PROTOCOL, "bad json");

      switch (msg.type) {
        // The heartbeat both clients send on an otherwise quiet socket. The Worker relay
        // answers it at the edge without waking the room; here there is nothing to wake.
        case "ping":
          return ws.send(PONG);

        // "Is my Mac there?", asked by a phone after every join. Answered from the live socket
        // rather than a stored flag, so it cannot go stale.
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
          const room = rooms.get(id) ?? newRoom();
          rooms.set(id, room);
          // A fresh registration wins; the stale Mac socket is dropped.
          if (room.mac && room.mac !== ws) room.mac.close(CLOSE_PROTOCOL, "replaced");
          room.mac = ws;
          conn.role = "mac";
          conn.room = room;
          conn.roomId = id;
          conn.key = key;
          ws.send(JSON.stringify({ type: "registered", roomId: id }));
          log("registered", { phones: room.phones.size });
          notifyOwner(room, true);
          drainBuffer(room, ws, now);
          return;
        }

        // The Mac has handled the replayed frames up to this sequence number.
        case "ack": {
          if (conn.role !== "mac" || !conn.room) return ws.close(CLOSE_PROTOCOL, "not registered");
          const ack = parseAck(msg);
          if (!ack) return ws.close(CLOSE_PROTOCOL, "bad ack");
          return ackBuffer(conn.room, ack.seq);
        }

        case "mint": {
          if (conn.role !== "mac" || !conn.room) return ws.close(CLOSE_PROTOCOL, "not registered");
          sweepTokens(conn.room, now);
          const token = randomBytes(32).toString("base64url");
          const expiresAt = now + TOKEN_TTL_MS;
          conn.room.tokens.set(token, expiresAt);
          ws.send(JSON.stringify({ type: "token", token, expiresAt }));
          return;
        }

        // The Mac unpairing a phone: forgotten, so it cannot rejoin against the nonce, and
        // dropped now rather than at its next reconnect.
        case "revoke": {
          if (conn.role !== "mac" || !conn.room) return ws.close(CLOSE_PROTOCOL, "not registered");
          const revoke = parseRevoke(msg);
          if (!revoke) return ws.close(CLOSE_PROTOCOL, "bad revoke");
          forget(conn.room, [revoke.pubkey]);
          return;
        }

        // The Mac's whole paired list, sent right after `register` and again whenever it
        // changes. It replaces what this room knows rather than adding to it, so the Mac's
        // `devices.json` is the source of truth and state this relay lost comes back.
        //
        // A device holding a live socket is kept whatever the list says: it has just proved
        // itself, and the Mac's file may not have caught up with a token join it is still
        // being told about. Unpairing a connected phone is what `revoke` is for.
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
          // A room nobody registered yet is empty rather than absent, as it is on the Worker,
          // so a join there fails for the same reason on both: no such device, no such token.
          const room = rooms.get(id) ?? newRoom();
          let key: KeyObject;
          try {
            key = publicKeyFrom(phonePubkey);
          } catch {
            return ws.close(CLOSE_PROTOCOL, "bad pubkey");
          }
          if (token === undefined) {
            // A rejoin: the room already knows this device, so it proves itself against the
            // connect nonce rather than spending a token it no longer has.
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
            // Verified before burning, so a bad signature cannot consume the token.
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
          ws.send(JSON.stringify({ type: "joined", roomId: id, ownerOnline: room.mac !== null }));
          return;
        }

        case "frame": {
          if (!conn.role || !conn.room || !conn.key) return ws.close(CLOSE_PROTOCOL, "not joined");
          const frames = parseFrames(msg);
          if (!frames) return ws.close(CLOSE_BAD_SIGNATURE, "unsigned frame");
          // Only the Mac fans out; a phone batching would be a 16x discount on its bucket.
          if (msg.frames !== undefined && conn.role === "phone") {
            return ws.close(CLOSE_PROTOCOL, "batch from phone");
          }
          for (const { payload, sig } of frames) {
            if (!verifySignature(payload, sig, conn.key)) {
              return ws.close(CLOSE_BAD_SIGNATURE, "bad frame signature");
            }
          }
          if (!allowFrame(conn.bucket, now)) return ws.close(CLOSE_RATE_LIMIT, "rate limit");

          if (conn.role === "phone") {
            if (conn.room.mac) conn.room.mac.send(raw);
            else bufferFrame(conn.room, raw, now);
          } else {
            // Not buffered: a phone that is away catches up by asking the Mac on its next
            // join, which holds the whole history. The relay is only ever the fast path down.
            // A batch is unpacked here: each phone sees plain frames, never the batch.
            const wires = msg.frames === undefined ? [raw] : frames.map(frameWire);
            for (const phone of conn.room.phones) for (const wire of wires) phone.send(wire);
          }
          return;
        }

        // The push side-channel. This relay holds no Apple auth key and wakes nobody: the
        // token is filed against the device as the Worker files it, and `notify` is taken and
        // dropped, so one client speaks to either relay unchanged and a self-hosted room simply
        // has no notifications. The roles are enforced, so the two relays refuse the same things.
        case "push": {
          if (conn.role !== "phone" || !conn.room) return ws.close(CLOSE_PROTOCOL, "not joined");
          const push = parsePush(msg);
          if (!push) return ws.close(CLOSE_PROTOCOL, "bad push");
          const pubkey = phoneKeys.get(ws);
          if (pubkey) conn.room.pushTokens.set(pubkey, push.deviceToken);
          return;
        }

        case "notify":
          if (conn.role !== "mac") return ws.close(CLOSE_PROTOCOL, "not registered");
          return;

        default:
          return ws.close(CLOSE_PROTOCOL, "unknown type");
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
      room.phones.delete(ws);
      dropRoomIfIdle(id, room);
    });
  });

  return new Promise((resolve) => {
    wss.on("listening", () =>
      resolve({
        port: (wss.address() as AddressInfo).port,
        close: () =>
          new Promise((done) => {
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
