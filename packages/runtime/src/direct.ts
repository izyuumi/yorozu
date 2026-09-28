/**
 * The direct path: an opt-in websocket on 127.0.0.1 that `tailscale serve` publishes to the
 * tailnet over HTTPS. It speaks the relay's own wire — `nonce`, signed `join`, signed `frame` —
 * so a phone uses the same client and the same sealed boxes on either path. It is not a relay:
 * only a device already paired may join (pairing, APNs and fallback stay on the relay), and
 * there is one room, this Mac's.
 */
import { randomBytes } from "node:crypto";
import { WebSocketServer, type WebSocket } from "ws";
import { fromBase64Url, verifyFrame } from "@yorozu/shared";

const AUTH_TIMEOUT_MS = 10_000;
const MAX_PAYLOAD_BYTES = 1_048_576;
const PONG = JSON.stringify({ type: "pong" });

export interface DirectOptions {
  port: number;
  /** Whether this Ed25519 key (base64url) belongs to a paired device. */
  known(signingPub: string): boolean;
  /** A verified frame's `payload`, from the device that joined as `signingPub`. */
  onFrame(signingPub: string, payload: string): void;
  onJoin?(signingPub: string): void;
  onLeave?(signingPub: string): void;
  onError?(message: string): void;
}

export interface Direct {
  /** The socket a device is joined on, if any. One per device: a new join replaces the old. */
  socketFor(signingPub: string): WebSocket | undefined;
  /** Drops a device, for when the Mac unpairs it. */
  drop(signingPub: string): void;
  close(): Promise<void>;
}

export function startDirect(options: DirectOptions): Direct {
  const joined = new Map<string, WebSocket>();
  // Loopback only: `tailscale serve` is what the tailnet reaches, never this port.
  const wss = new WebSocketServer({ host: "127.0.0.1", port: options.port, maxPayload: MAX_PAYLOAD_BYTES });
  wss.on("error", (e) => options.onError?.(`direct-error ${e.message}`));

  wss.on("connection", (ws) => {
    const nonce = randomBytes(32).toString("base64url");
    let key: string | undefined;
    ws.on("error", () => {});
    ws.send(JSON.stringify({ type: "nonce", nonce }));
    const auth = setTimeout(() => { if (!key) ws.close(1008, "auth timeout"); }, AUTH_TIMEOUT_MS);
    ws.once("close", () => {
      clearTimeout(auth);
      if (key && joined.get(key) === ws) {
        joined.delete(key);
        options.onLeave?.(key);
      }
    });

    ws.on("message", (data) => {
      let msg: Record<string, unknown>;
      try {
        const parsed = JSON.parse(data.toString()) as unknown;
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
        msg = parsed as Record<string, unknown>;
      } catch {
        return ws.close(4001, "bad json");
      }
      if (msg.type === "ping") return ws.send(PONG);
      if (msg.type === "join") {
        const pub = msg.phonePubkey;
        // A token is a pairing, and pairing happens on the relay.
        if (key || msg.token !== undefined || typeof pub !== "string" || typeof msg.sig !== "string") {
          return ws.close(4001, "bad join");
        }
        if (!options.known(pub)) return ws.close(4001, "unknown device");
        let ok = false;
        try { ok = verifyFrame(fromBase64Url(pub), Buffer.from(nonce), fromBase64Url(msg.sig)); } catch {}
        if (!ok) return ws.close(4003, "bad join signature");
        key = pub;
        clearTimeout(auth);
        joined.get(pub)?.close(4001, "replaced");
        joined.set(pub, ws);
        ws.send(JSON.stringify({ type: "joined", ownerOnline: true }));
        options.onJoin?.(pub);
        return;
      }
      if (!key) return ws.close(4001, "not joined");
      // The Mac is this end, so it is always there.
      if (msg.type === "owner") return ws.send(JSON.stringify({ type: "owner", online: true }));
      if (msg.type === "frame") {
        if (typeof msg.payload !== "string" || typeof msg.sig !== "string") return ws.close(4001, "bad frame");
        let ok = false;
        try { ok = verifyFrame(fromBase64Url(key), Buffer.from(msg.payload), fromBase64Url(msg.sig)); } catch {}
        if (!ok) return ws.close(4003, "bad signature");
        try { options.onFrame(key, msg.payload); }
        catch (e) { options.onError?.(`direct-frame-error ${e instanceof Error ? e.message : String(e)}`); }
      }
      // `push` and `flowAck` are relay business; ignored here.
    });
  });

  return {
    socketFor: (pub) => {
      const ws = joined.get(pub);
      return ws?.readyState === ws?.OPEN ? ws : undefined;
    },
    drop: (pub) => joined.get(pub)?.close(4001, "revoked"),
    close: () => new Promise((done) => {
      for (const client of wss.clients) client.terminate();
      wss.close(() => done());
    }),
  };
}
