import { createHash, createPublicKey, randomBytes, sign, verify, type KeyObject } from "node:crypto";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";

const TOKEN_TTL_MS = 10 * 60_000;
const BUFFER_TTL_MS = 24 * 60 * 60_000;
const BUFFER_CAP_BYTES = 5 * 1024 * 1024;
const FRAMES_PER_SEC = 60;

/** Close codes. The relay closes rather than silently ignoring a bad frame. */
const CLOSE_PROTOCOL = 4001;
const CLOSE_BAD_SIGNATURE = 4003;
const CLOSE_RATE_LIMIT = 4029;

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

type Buffered = { raw: string; bytes: number; at: number };

type Room = {
  mac: WebSocket | null;
  phones: Set<WebSocket>;
  /** token -> expiry epoch ms. Deleted on use: one-time. */
  tokens: Map<string, number>;
  buffer: Buffered[];
  bufferBytes: number;
  bucket: number;
  refilledAt: number;
};

type Conn = {
  nonce: string;
  role: "mac" | "phone" | null;
  room: Room | null;
  roomId: string | null;
  /** Key whose signature every frame from this socket must carry. */
  key: KeyObject | null;
};

function newRoom(now: number): Room {
  return {
    mac: null,
    phones: new Set(),
    tokens: new Map(),
    buffer: [],
    bufferBytes: 0,
    bucket: FRAMES_PER_SEC,
    refilledAt: now,
  };
}

/** Token bucket, per room: sustained FRAMES_PER_SEC with a one-second burst. */
function allowFrame(room: Room, now: number): boolean {
  const refill = ((now - room.refilledAt) / 1000) * FRAMES_PER_SEC;
  room.bucket = Math.min(FRAMES_PER_SEC, room.bucket + refill);
  room.refilledAt = now;
  if (room.bucket < 1) return false;
  room.bucket -= 1;
  return true;
}

/** TTLs are enforced lazily on access, so an idle relay holds no timers. */
function pruneBuffer(room: Room, now: number): void {
  while (room.buffer.length > 0 && now - room.buffer[0]!.at > BUFFER_TTL_MS) {
    room.bufferBytes -= room.buffer.shift()!.bytes;
  }
}

function bufferFrame(room: Room, raw: string, now: number): void {
  pruneBuffer(room, now);
  const bytes = Buffer.byteLength(raw);
  room.buffer.push({ raw, bytes, at: now });
  room.bufferBytes += bytes;
  while (room.bufferBytes > BUFFER_CAP_BYTES && room.buffer.length > 0) {
    room.bufferBytes -= room.buffer.shift()!.bytes;
  }
}

function drainBuffer(room: Room, mac: WebSocket, now: number): void {
  pruneBuffer(room, now);
  for (const entry of room.buffer) mac.send(entry.raw);
  room.buffer = [];
  room.bufferBytes = 0;
}

export type Relay = { port: number; close: () => Promise<void> };

export function startRelay(port = Number(process.env.PORT ?? 8787)): Promise<Relay> {
  const rooms = new Map<string, Room>();
  const wss = new WebSocketServer({ port });

  const dropRoomIfIdle = (id: string, room: Room): void => {
    if (!room.mac && room.phones.size === 0 && room.buffer.length === 0 && room.tokens.size === 0) {
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
    };
    ws.send(JSON.stringify({ type: "nonce", nonce: conn.nonce }));

    ws.on("message", (data) => {
      const raw = data.toString();
      const now = Date.now();

      // Only the envelope is parsed; `payload` is forwarded byte-for-byte.
      let msg: Record<string, unknown>;
      try {
        msg = JSON.parse(raw);
      } catch {
        return ws.close(CLOSE_PROTOCOL, "bad json");
      }

      switch (msg.type) {
        case "register": {
          const { pubkey, nonceSig } = msg;
          if (typeof pubkey !== "string" || typeof nonceSig !== "string") {
            return ws.close(CLOSE_PROTOCOL, "bad register");
          }
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
          const room = rooms.get(id) ?? newRoom(now);
          rooms.set(id, room);
          // A fresh registration wins; the stale Mac socket is dropped.
          if (room.mac && room.mac !== ws) room.mac.close(CLOSE_PROTOCOL, "replaced");
          room.mac = ws;
          conn.role = "mac";
          conn.room = room;
          conn.roomId = id;
          conn.key = key;
          ws.send(JSON.stringify({ type: "registered", roomId: id }));
          drainBuffer(room, ws, now);
          return;
        }

        case "mint": {
          if (conn.role !== "mac" || !conn.room) return ws.close(CLOSE_PROTOCOL, "not registered");
          const token = randomBytes(32).toString("base64url");
          const expiresAt = now + TOKEN_TTL_MS;
          conn.room.tokens.set(token, expiresAt);
          ws.send(JSON.stringify({ type: "token", token, expiresAt }));
          return;
        }

        case "join": {
          const { roomId: id, token, phonePubkey, sig } = msg;
          if (
            typeof id !== "string" ||
            typeof token !== "string" ||
            typeof phonePubkey !== "string" ||
            typeof sig !== "string"
          ) {
            return ws.close(CLOSE_PROTOCOL, "bad join");
          }
          const room = rooms.get(id);
          const expiresAt = room?.tokens.get(token);
          if (!room || expiresAt === undefined) return ws.close(CLOSE_PROTOCOL, "unknown token");
          if (now > expiresAt) {
            room.tokens.delete(token);
            return ws.close(CLOSE_PROTOCOL, "expired token");
          }
          let key: KeyObject;
          try {
            key = publicKeyFrom(phonePubkey);
          } catch {
            return ws.close(CLOSE_PROTOCOL, "bad pubkey");
          }
          // Verified before burning, so a bad signature cannot consume the token.
          if (!verifySignature(token, sig, key)) {
            return ws.close(CLOSE_BAD_SIGNATURE, "bad join signature");
          }
          room.tokens.delete(token);
          room.phones.add(ws);
          conn.role = "phone";
          conn.room = room;
          conn.roomId = id;
          conn.key = key;
          ws.send(JSON.stringify({ type: "joined", roomId: id }));
          return;
        }

        case "frame": {
          const { payload, sig } = msg;
          if (!conn.role || !conn.room || !conn.key) return ws.close(CLOSE_PROTOCOL, "not joined");
          if (typeof payload !== "string" || typeof sig !== "string") {
            return ws.close(CLOSE_BAD_SIGNATURE, "unsigned frame");
          }
          if (!verifySignature(payload, sig, conn.key)) {
            return ws.close(CLOSE_BAD_SIGNATURE, "bad frame signature");
          }
          if (!allowFrame(conn.room, now)) return ws.close(CLOSE_RATE_LIMIT, "rate limit");

          if (conn.role === "phone") {
            if (conn.room.mac) conn.room.mac.send(raw);
            else bufferFrame(conn.room, raw, now);
          } else {
            for (const phone of conn.room.phones) phone.send(raw);
          }
          return;
        }

        default:
          return ws.close(CLOSE_PROTOCOL, "unknown type");
      }
    });

    ws.on("close", () => {
      const { room, roomId: id } = conn;
      if (!room || !id) return;
      if (room.mac === ws) room.mac = null;
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
