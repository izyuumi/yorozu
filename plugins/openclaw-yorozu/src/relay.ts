/**
 * The host side of the relay (apps/relay; docs/ios-relay-contract.md): one outbound WebSocket to the room
 * `base64url(sha256(host Ed25519 pub))`, registered with a signature over the relay's nonce, redialled with
 * backoff until the account stops. It answers v3 handshakes from allowlisted devices and keeps one session per
 * device in memory, across its own reconnects. Message handling is #424.
 */
import os from "node:os";
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import { captureEffectAuthority } from "openclaw/plugin-sdk/fetch-runtime";
import { computeBackoff, sleepWithAbort } from "openclaw/plugin-sdk/runtime-env";
import { WebSocket } from "openclaw/plugin-sdk/websocket-runtime";
import { getDevice, listDevices } from "./devices.js";
import { encodeEvent, negotiate, parseEvent, PROTOCOL_VERSION, type Event, type PeerInfo } from "./envelope.js";
import type { HostKeys } from "./keys.js";
import {
  acceptHandshake,
  b64u,
  decodeFrame,
  HANDSHAKE_MAX_AGE_MS,
  signFrame,
  type Frame,
  type Session,
} from "./wire.js";

/** The relay answers this exact string at its edge (apps/relay `PING`/`PONG`). */
const PING = JSON.stringify({ type: "ping" });
const PONG = JSON.stringify({ type: "pong" });
/** A ping every 30 s; one still unanswered at the next means a half-open socket, which is dropped. */
const HEARTBEAT_MS = 30_000;
const BACKOFF = { initialMs: 1_000, maxMs: 30_000, factor: 2, jitter: 0.3 };

const PEER_INFO: PeerInfo = {
  protocolMin: PROTOCOL_VERSION,
  protocolMax: PROTOCOL_VERSION,
  app: "0.1.0", // package.json `version`
  name: os.hostname().replace(/\.local$/, ""),
  capabilities: [],
};

type Served = { session: Session; peer?: PeerInfo };
type Status = { connected: boolean; error?: string };

export type RelayHostOptions = {
  relayUrl: string;
  keys: HostKeys;
  signal: AbortSignal;
  log?: ChannelGatewayContext["log"];
  onStatus: (status: Status) => void;
};

/** Stays pending until `signal` aborts, then settles once the socket is closed. */
export async function runRelayHost(opts: RelayHostOptions): Promise<void> {
  const { keys, signal, log } = opts;
  /** Device Ed25519 key (base64url) -> its live session; sid (base64url) -> device. */
  const served = new Map<string, Served>();
  const bySid = new Map<string, string>();
  /** Answered sids -> until when a replay of them is still fresh enough to need refusing. */
  const answered = new Map<string, number>();

  const url = new URL(opts.relayUrl);
  // The Worker relay routes on the room before the socket says anything.
  url.searchParams.set("room", keys.room);

  const drop = (reason: string) => log?.info(`yorozu: handshake dropped (${reason})`);

  function connect(): Promise<boolean> {
    return new Promise((resolve) => {
      const ws = new WebSocket(url, { handshakeTimeout: 10_000 });
      let registered = false;
      let pongDue = false;
      let queue = Promise.resolve();

      /** Every send is behind the effect-authority fence; outside a host scope that just sends. */
      const send = (raw: string): void => {
        if (ws.readyState !== WebSocket.OPEN) return;
        captureEffectAuthority()
          .initiate(() => ws.send(raw))
          .catch((error: unknown) => log?.warn(`yorozu: relay send failed: ${String(error)}`));
      };
      const sendFrames = (payloads: string[]): void => {
        const frames = payloads.map((payload) => ({ payload, sig: signFrame(keys.signing.privateKey, payload) }));
        send(JSON.stringify(frames.length === 1 ? { type: "frame", ...frames[0] } : { type: "frame", frames }));
      };
      const seal = (session: Session, event: Event): string => session.seal(encodeEvent(event));

      async function handshake(payload: string, sig: string): Promise<void> {
        const now = Date.now();
        const accepted = acceptHandshake({ host: keys.static, room: keys.room, payload, sig, now });
        if (!accepted) return drop("invalid or stale");
        const deviceKey = b64u(accepted.deviceSigningKey);
        const device = await getDevice(deviceKey);
        if (!device || device.staticPub !== b64u(accepted.deviceStatic)) return drop("device not allowlisted");
        for (const [sid, until] of answered) if (until < now) answered.delete(sid);
        if (answered.has(accepted.sid)) return drop("replayed");
        answered.set(accepted.sid, accepted.payload.ts + HANDSHAKE_MAX_AGE_MS);
        const old = served.get(deviceKey);
        if (old) bySid.delete(b64u(old.session.sid));
        served.set(deviceKey, { session: accepted.session });
        bySid.set(accepted.sid, deviceKey);
        sendFrames([accepted.response, seal(accepted.session, { kind: "peer_info", data: PEER_INFO })]);
        log?.info(`yorozu: session open (${served.size} device${served.size === 1 ? "" : "s"})`);
      }

      function box(frame: Frame): void {
        const deviceKey = frame.type === "box" ? bySid.get(b64u(frame.sid)) : undefined;
        const entry = deviceKey ? served.get(deviceKey) : undefined;
        const plain = entry?.session.open(frame);
        if (!deviceKey || !entry || !plain) return;
        const event = parseEvent(plain);
        if (!entry.peer) {
          // Nothing else counts until the peer's `peer_info`.
          if (event?.kind !== "peer_info") return;
          if (negotiate(PEER_INFO, event.data) === null) {
            sendFrames([
              seal(entry.session, {
                kind: "error",
                data: { code: "update_required", message: "no common protocol version" },
              }),
            ]);
            served.delete(deviceKey);
            bySid.delete(b64u(entry.session.sid));
            return log?.info("yorozu: session closed (update required)");
          }
          entry.peer = event.data;
          return log?.info(`yorozu: peer_info received (protocol ${PROTOCOL_VERSION})`);
        }
        // Message kinds arrive with #424.
      }

      async function receive(raw: string): Promise<void> {
        if (raw === PONG) {
          pongDue = false;
          return;
        }
        let msg: Record<string, unknown>;
        try {
          msg = JSON.parse(raw) as Record<string, unknown>;
        } catch {
          return;
        }
        switch (msg.type) {
          case "nonce":
            if (typeof msg.nonce !== "string") return;
            return send(
              JSON.stringify({
                type: "register",
                pubkey: b64u(keys.signing.publicKey),
                nonceSig: signFrame(keys.signing.privateKey, msg.nonce),
              }),
            );
          case "registered": {
            registered = true;
            log?.info(`yorozu: registered at relay, room ${keys.room}`);
            opts.onStatus({ connected: true });
            // The allowlist is the source of truth for which devices may rejoin the room.
            const devices = (await listDevices()).map((d) => d.signingPub);
            return send(JSON.stringify({ type: "devices", devices }));
          }
          case "pong":
            pongDue = false;
            return;
          case "frame": {
            if (typeof msg.payload === "string" && typeof msg.sig === "string") {
              const frame = decodeFrame(msg.payload);
              if (frame?.type === "init") await handshake(msg.payload, msg.sig);
              else if (frame?.type === "box") box(frame);
            }
            // A frame the relay buffered while this host was away comes with a `seq` and replays until acked.
            if (Number.isSafeInteger(msg.seq)) send(JSON.stringify({ type: "ack", seq: msg.seq }));
            return;
          }
          case "state":
            return log?.info(`yorozu: relay state: ${String(msg.state).slice(0, 64)}`);
          default:
            return; // `owner`, `phones`, `token`: not needed yet.
        }
      }

      const heartbeat = setInterval(() => {
        if (pongDue) return ws.terminate();
        pongDue = true;
        send(PING);
      }, HEARTBEAT_MS);
      const stop = () => {
        ws.close(1000, "stopping");
        setTimeout(() => ws.terminate(), 1_000).unref();
      };
      signal.addEventListener("abort", stop, { once: true });

      ws.on("message", (data) => {
        // In order, so acks follow the frames they cover.
        queue = queue
          .then(() => receive(String(data)))
          .catch((error: unknown) => log?.warn(`yorozu: relay message failed: ${String(error)}`));
      });
      ws.on("error", (error) => {
        if (!signal.aborted) log?.warn(`yorozu: relay socket error: ${error.message}`);
      });
      ws.on("close", (code, reason) => {
        clearInterval(heartbeat);
        signal.removeEventListener("abort", stop);
        if (!signal.aborted) {
          const why = `relay closed (${code}${reason.length ? ` ${reason.toString().slice(0, 64)}` : ""})`;
          log?.warn(`yorozu: ${why}`);
          opts.onStatus({ connected: false, error: why });
        }
        resolve(registered);
      });
    });
  }

  let attempt = 0;
  while (!signal.aborted) {
    if (await connect()) attempt = 0;
    if (signal.aborted) break;
    const delay = computeBackoff(BACKOFF, ++attempt);
    log?.info(`yorozu: reconnecting in ${Math.round(delay / 100) / 10} s`);
    await sleepWithAbort(delay, signal).catch(() => {});
  }
}
