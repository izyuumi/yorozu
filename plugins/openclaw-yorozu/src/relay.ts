/**
 * The host side of the relay (apps/relay; docs/ios-relay-contract.md): one outbound WebSocket to the room
 * `base64url(sha256(host Ed25519 pub))`, registered with a signature over the relay's nonce, redialled with
 * backoff until the account stops. It answers v3 handshakes from allowlisted devices, and from a device proving a
 * pending pairing, which it then adds to the allowlist; it keeps one session per device in memory, across its own
 * reconnects. `beginPairing` and `unpairDevice` are what the Gateway methods behind `openclaw yorozu` call.
 * A device's `message` is answered `delivered` and handed to `onMessage` once per `messageId`; `broadcast` sends
 * events to every served device (src/conversation.ts).
 */
import { randomBytes } from "node:crypto";
import os from "node:os";
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import { captureEffectAuthority } from "openclaw/plugin-sdk/fetch-runtime";
import { computeBackoff, sleepWithAbort } from "openclaw/plugin-sdk/runtime-env";
import { WebSocket } from "openclaw/plugin-sdk/websocket-runtime";
import { receiveUpload, serveDownload } from "./attachments.js";
import { getDevice, listDevices, putDevice, removeDevice } from "./devices.js";
import {
  ATTACHMENTS,
  DEVICES,
  encodeEvent,
  negotiate,
  parseEvent,
  PROTOCOL_VERSION,
  type DeviceList,
  type DevicePatch,
  type Event,
  type Message,
  type PeerInfo,
} from "./envelope.js";
import type { HostKeys } from "./keys.js";
import { firstLine, previewKey, previewPlaintext, pushTitle, sealPreview, threadRef } from "./push.js";
import { listCursors, mergeCursor } from "./reads.js";
import {
  acceptHandshake,
  b64u,
  decodeFrame,
  fingerprint,
  HANDSHAKE_MAX_AGE_MS,
  helloProof,
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
/** A host batch: at most 16 frames and 1 MiB in all (docs/ios-relay-contract.md, "Relay"); slack for the JSON. */
const BATCH_FRAMES = 16;
const BATCH_BYTES = 1024 * 1024 - 4096;
/** Taken `messageId`s are remembered this long, as long as the relay replays buffered frames. */
const TAKEN_MS = 24 * 60 * 60 * 1000;
const TAKEN_MAX = 10_000;

const PEER_INFO: PeerInfo = {
  protocolMin: PROTOCOL_VERSION,
  protocolMax: PROTOCOL_VERSION,
  app: "0.1.0", // package.json `version`
  name: os.hostname().replace(/\.local$/, ""),
  capabilities: [ATTACHMENTS, DEVICES],
};

/** An attachment-bearing event as a peer without `attachments` reads it: the files as a line of text each. */
function downgrade(event: Event, peer: PeerInfo): Event {
  if (peer.capabilities.includes(ATTACHMENTS) || event.kind !== "reply" || !event.data.attachments) return event;
  const { attachments, ...reply } = event.data;
  const lines = attachments.map((a) => `(Attachment: ${a.name}; update Yorozu to open it.)`);
  return { kind: "reply", data: { ...reply, text: [reply.text, ...lines].filter(Boolean).join("\n\n") } };
}

/**
 * `foreground`: the conversation the device last reported on screen with the app in the foreground (#431); `active`:
 * the app is in the foreground at all, so the device gets no push (it shows its own notice).
 */
type Served = { session: Session; peer?: PeerInfo; foreground?: string; active?: boolean };
type Status = { connected: boolean; error?: string };

export type RelayHostOptions = {
  relayUrl: string;
  keys: HostKeys;
  signal: AbortSignal;
  log?: ChannelGatewayContext["log"];
  onStatus: (status: Status) => void;
  /** A device's message, once per `messageId`, after `delivered` went out. */
  onMessage: (message: Message) => void;
  /**
   * A device's request (`cron_list`, `conv_list`, `history`, `conv_patch`); what it returns goes to that device
   * only (a `conv_patch` answers every device itself, with `conv_update`, and returns only an error).
   */
  onRequest?: (event: Event) => Promise<Event | undefined>;
  /** The attachment limit (`mediaMaxMb`), told to devices in `peer_info` and enforced on uploads. */
  mediaMaxBytes: number;
  /** Told to devices in `peer_info`, for Settings. */
  agent?: string;
  hostVersion?: string;
};

/** What `openclaw yorozu pair` prints. */
export type Pairing = {
  /** `yorozu://pair?v=3&…` (docs/ios-relay-contract.md, "Pairing"). */
  link: string;
  /** The same query in the web link's fragment: what the QR carries, so a phone's camera opens the app. */
  webLink: string;
  fingerprint: string;
  /** Epoch ms, the relay's: the token and the secret both stop working after it. */
  expiresAt: number;
  /** Paired devices before this one; at `MAX_DEVICES` the oldest makes way. */
  devices: number;
};

/** The web link a pairing QR carries (`QrPayload.link`). */
const PAIR_WEB_LINK = "https://yorozu.yumi.to/pair";
const MINT_TIMEOUT_MS = 10_000;

/** Secrets of pairings minted and not yet used -> their expiry (epoch ms). In memory: a restart voids them. */
const pending = new Map<string, number>();
/** The running host, while `runRelayHost` runs; `mint` only while it is registered at the relay. */
let host: {
  relayUrl: string;
  keys: HostKeys;
  mint: (() => Promise<{ token: string; expiresAt: number }>) | null;
  /** Drops the devices' sessions and makes the relay forget them and close their sockets. */
  forget: (deviceKeys: string[]) => void;
  /** Seals each event for every served device and sends them, in order; null while not registered. */
  broadcast: ((events: Event[]) => number) | null;
  /** Sends the relay one `notify` for a finished reply; null while not registered. */
  notify: ((convId: string, messageId: string, text: string) => Promise<void>) | null;
} | null = null;

/**
 * Sends the events to every device with a live session, each sealed under that device's session. Returns how
 * many devices that was: 0 while the relay is not reachable or no device is connected (the transcript keeps it).
 */
export function broadcast(events: Event[]): number {
  return host?.broadcast?.(events) ?? 0;
}

/**
 * One push for a finished reply in `convId` (#431): `messageId` is its first chunk, `text` its text. Every paired
 * device gets it except one with a live session that has this conversation in the foreground. Dropped while the
 * relay is not reachable (the reply itself is in the transcript).
 */
export async function notifyReply(convId: string, messageId: string, text: string): Promise<void> {
  await host?.notify?.(convId, messageId, text);
}

/** Mints a one-time relay token and a secret for one new device; throws while the relay is not reachable. */
export async function beginPairing(): Promise<Pairing> {
  if (!host?.mint) throw new Error("the yorozu channel is not connected to its relay; check `openclaw channels status`");
  const { relayUrl, keys } = host;
  const { token, expiresAt } = await host.mint();
  const secret = b64u(randomBytes(32));
  const now = Date.now();
  for (const [old, until] of pending) if (until < now) pending.delete(old);
  pending.set(secret, expiresAt);
  // URLComponents' spelling (QrPayload.encoded): `:` and `/` stay as they are in a query.
  const q = (value: string) => encodeURIComponent(value).replace(/%3A/gi, ":").replace(/%2F/gi, "/");
  const query = `v=3&relay=${q(relayUrl)}&key=${b64u(keys.static.publicKey)}&token=${q(token)}&room=${keys.room}&secret=${secret}`;
  return {
    link: `yorozu://pair?${query}`,
    webLink: `${PAIR_WEB_LINK}#${query}`,
    fingerprint: fingerprint(keys.static.publicKey),
    expiresAt,
    devices: (await listDevices()).length,
  };
}

/** Takes a device off the allowlist, drops its session and has the relay forget it. False if it was not there. */
export async function unpairDevice(deviceKey: string): Promise<boolean> {
  const removed = await removeDevice(deviceKey);
  host?.forget([deviceKey]);
  return removed;
}

/** The pending secret `proof` proves for this device, if any. */
function provenSecret(proof: string | undefined, staticPub: string, signingPub: string, now: number): string | undefined {
  if (!proof) return undefined;
  for (const [secret, until] of pending) {
    if (until >= now && helloProof(secret, staticPub, signingPub) === proof) return secret;
  }
  return undefined;
}

/** Stays pending until `signal` aborts, then settles once the socket is closed. */
export async function runRelayHost(opts: RelayHostOptions): Promise<void> {
  const { keys, signal, log } = opts;
  const peerInfo: PeerInfo = {
    ...PEER_INFO,
    mediaMaxBytes: opts.mediaMaxBytes,
    ...(opts.agent && { agent: opts.agent }),
    ...(opts.hostVersion && { hostVersion: opts.hostVersion }),
  };
  /** Device Ed25519 key (base64url) -> its live session; sid (base64url) -> device. */
  const served = new Map<string, Served>();
  const bySid = new Map<string, string>();
  /** Answered sids -> until when a replay of them is still fresh enough to need refusing. */
  const answered = new Map<string, number>();
  /** Taken messageIds -> when; a repeat is answered `delivered` again and not run twice. */
  const taken = new Map<string, number>();
  /**
   * Conversation -> the devices alerted for it since it was last read, so a read sends a silent `sync` to exactly
   * those (they clear the alert). In memory: after a restart a read clears nothing until the next alert.
   */
  const alerted = new Map<string, Set<string>>();

  const url = new URL(opts.relayUrl);
  // The Worker relay routes on the room before the socket says anything.
  url.searchParams.set("room", keys.room);

  const drop = (reason: string) => log?.info(`yorozu: handshake dropped (${reason})`);
  /** Sends to the relay while registered; replaced on every connection. */
  let relaySend: ((raw: string) => void) | null = null;
  const endSession = (deviceKey: string): void => {
    const old = served.get(deviceKey);
    if (old) bySid.delete(b64u(old.session.sid));
    served.delete(deviceKey);
  };
  const me: NonNullable<typeof host> = (host = {
    relayUrl: opts.relayUrl,
    keys,
    mint: null,
    broadcast: null,
    notify: null,
    forget: (deviceKeys) => {
      for (const key of deviceKeys) {
        endSession(key);
        relaySend?.(JSON.stringify({ type: "revoke", pubkey: key }));
      }
    },
  });

  function connect(): Promise<boolean> {
    return new Promise((resolve) => {
      const ws = new WebSocket(url, { handshakeTimeout: 10_000 });
      let registered = false;
      let pongDue = false;
      let queue = Promise.resolve();
      /** `mint` requests in flight; the relay answers them in order. */
      const minting: { resolve: (t: { token: string; expiresAt: number }) => void; reject: (e: Error) => void }[] = [];

      /** Every send is behind the effect-authority fence; outside a host scope that just sends. */
      const send = (raw: string): void => {
        if (ws.readyState !== WebSocket.OPEN) return;
        captureEffectAuthority()
          .initiate(() => ws.send(raw))
          .catch((error: unknown) => log?.warn(`yorozu: relay send failed: ${String(error)}`));
      };
      /** Signs the payloads and sends them in as few batches as the relay's limits allow. */
      const sendFrames = (payloads: string[]): void => {
        let batch: { payload: string; sig: string }[] = [];
        let bytes = 0;
        const flush = () => {
          if (batch.length) send(JSON.stringify(batch.length === 1 ? { type: "frame", ...batch[0] } : { type: "frame", frames: batch }));
          batch = [];
          bytes = 0;
        };
        for (const payload of payloads) {
          const frame = { payload, sig: signFrame(keys.signing.privateKey, payload) };
          const size = payload.length + frame.sig.length + 32;
          if (batch.length === BATCH_FRAMES || (batch.length && bytes + size > BATCH_BYTES)) flush();
          batch.push(frame);
          bytes += size;
        }
        flush();
      };
      const broadcastHere = (events: Event[]): number => {
        const live = [...served.values()].filter((entry) => entry.peer);
        sendFrames(events.flatMap((event) => live.map((entry) => seal(entry.session, downgrade(event, entry.peer!)))));
        return live.length;
      };
      const seal = (session: Session, event: Event): string => session.seal(encodeEvent(event));
      /**
       * The relay alerts every device with a push token in the room; `devices` names the ones to alert, for a relay
       * that honours it, and only those get a sealed preview. A relay that ignores it alerts the others with its fixed
       * text, which a client with the conversation on screen does not show.
       */
      const notifyHere = async (convId: string, messageId: string, text: string): Promise<void> => {
        const body = firstLine(text);
        if (!body) return;
        // A device with the app in front shows its own notice; one with this conversation open needs none.
        const watching = new Set(
          [...served].filter(([, entry]) => entry.peer && (entry.active || entry.foreground === convId)).map(([key]) => key),
        );
        const devices = (await listDevices()).filter((device) => device.push !== false && !watching.has(device.signingPub));
        if (!devices.length) return log?.info("yorozu: notify skipped (every device has the app open or push off)");
        const marked = alerted.get(convId) ?? new Set<string>();
        for (const device of devices) marked.add(device.signingPub);
        alerted.set(convId, marked);
        const title = await pushTitle(convId);
        const plaintext = previewPlaintext({ b: body, c: "reply", e: threadRef(messageId), t: title, v: convId });
        const previews: Record<string, { n: string; c: string }> = {};
        for (const device of devices) {
          const key = plaintext && previewKey(keys.static.privateKey, device.staticPub);
          if (key) previews[device.signingPub] = sealPreview(key, plaintext);
        }
        send(
          JSON.stringify({
            type: "notify",
            class: "reply",
            threadRef: threadRef(convId),
            eventRef: threadRef(messageId),
            ...(Object.keys(previews).length ? { previews } : {}),
            devices: devices.map((device) => device.signingPub),
          }),
        );
        log?.info(`yorozu: notify sent (${devices.length} device${devices.length === 1 ? "" : "s"}, ${watching.size} skipped)`);
      };
      /**
       * `convId` was read on `reader`: a silent `sync` to the other devices alerted for it since, so each clears that
       * alert with no app open. The relay skips a device whose socket is live (it got the `read_cursor` itself).
       */
      const syncHere = (convId: string, reader: string): void => {
        const marked = alerted.get(convId);
        alerted.delete(convId);
        // Not filtered on `served`: a session outlives its device's socket, which the relay alone knows about.
        const devices = [...(marked ?? [])].filter((key) => key !== reader);
        if (!devices.length) return;
        send(JSON.stringify({ type: "notify", class: "sync", threadRef: threadRef(convId), devices }));
      };
      /** Settings: every paired device, as `deviceKey` sees them. */
      const deviceList = async (deviceKey: string): Promise<Event> => {
        const devices = (await listDevices()).map((d) => ({
          id: d.signingPub,
          ...(d.name && { name: d.name }),
          pairedAt: d.pairedAt,
          push: d.push !== false,
          current: d.signingPub === deviceKey,
        }));
        return { kind: "device_list", data: { devices } satisfies DeviceList };
      };
      /** Push on or off, or removal (Settings, #415); answered with the list. Removal ends that device's session. */
      const patchDevice = async (patch: DevicePatch, deviceKey: string): Promise<Event> => {
        const device = await getDevice(patch.id);
        if (!device) return { kind: "device_list", data: { error: "unknown device" } };
        if (patch.removed) {
          await removeDevice(patch.id);
          me.forget([patch.id]);
          log?.info("yorozu: device removed from Settings");
        } else if (patch.push !== undefined && (device.push !== false) !== patch.push) {
          await putDevice({ ...device, push: patch.push });
        }
        return deviceList(deviceKey);
      };

      async function handshake(payload: string, sig: string): Promise<void> {
        const now = Date.now();
        const accepted = acceptHandshake({ host: keys.static, room: keys.room, payload, sig, now });
        if (!accepted) return drop("invalid or stale");
        const deviceKey = b64u(accepted.deviceSigningKey);
        const staticPub = b64u(accepted.deviceStatic);
        for (const [sid, until] of answered) if (until < now) answered.delete(sid);
        if (answered.has(accepted.sid)) return drop("replayed");
        const known = (await getDevice(deviceKey))?.staticPub === staticPub;
        const secret = known ? undefined : provenSecret(accepted.payload.proof, staticPub, deviceKey, now);
        if (!known && !secret) {
          // Only a device the relay let into the room can send a frame; one this host does not know goes too.
          send(JSON.stringify({ type: "revoke", pubkey: deviceKey }));
          return drop("device not allowlisted");
        }
        answered.set(accepted.sid, accepted.payload.ts + HANDSHAKE_MAX_AGE_MS);
        if (secret) {
          pending.delete(secret);
          const evicted = await putDevice({ signingPub: deviceKey, staticPub, pairedAt: now });
          me.forget(evicted);
          log?.info(`yorozu: device paired${evicted.length ? " (the oldest made way)" : ""}`);
        }
        endSession(deviceKey);
        served.set(deviceKey, { session: accepted.session });
        bySid.set(accepted.sid, deviceKey);
        sendFrames([accepted.response, seal(accepted.session, { kind: "peer_info", data: peerInfo })]);
        log?.info(`yorozu: session open (${served.size} device${served.size === 1 ? "" : "s"})`);
      }

      async function box(frame: Frame): Promise<void> {
        const deviceKey = frame.type === "box" ? bySid.get(b64u(frame.sid)) : undefined;
        const entry = deviceKey ? served.get(deviceKey) : undefined;
        const plain = entry?.session.open(frame);
        if (!deviceKey || !entry || !plain) return;
        const event = parseEvent(plain);
        if (!entry.peer) {
          // Nothing else counts until the peer's `peer_info`.
          if (event?.kind !== "peer_info") return;
          if (negotiate(peerInfo, event.data) === null) {
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
          // The device's model, diagnostic only, kept for `openclaw yorozu devices`.
          const name = event.data.name?.trim().slice(0, 64);
          const device = name ? await getDevice(deviceKey) : undefined;
          if (device && name && device.name !== name) await putDevice({ ...device, name });
          // A device that was away (or is new) learns every conversation's read state.
          const cursors = await listCursors();
          if (cursors.length) sendFrames(cursors.map((data) => seal(entry.session, { kind: "read_cursor", data })));
          return log?.info(`yorozu: peer_info received (protocol ${PROTOCOL_VERSION})`);
        }
        if (event?.kind === "message") {
          const { convId, messageId } = event.data;
          broadcastHere([{ kind: "delivered", data: { convId, messageId } }]);
          const now = Date.now();
          if (taken.has(messageId)) return;
          for (const [id, at] of taken) {
            if (at > now - TAKEN_MS && taken.size < TAKEN_MAX) break;
            taken.delete(id);
          }
          taken.set(messageId, now);
          return opts.onMessage(event.data);
        }
        if (event?.kind === "read_cursor") {
          // To every device, the sender too: one behind the stored cursor catches up.
          const merged = await mergeCursor(event.data);
          broadcastHere([{ kind: "read_cursor", data: merged }]);
          if (!merged.unread) syncHere(merged.convId, deviceKey);
          return;
        }
        // Attachment transfers answer the one device that asked, never every device (each frame reaches them all).
        if (event?.kind === "upload" || event?.kind === "download") {
          const replies =
            event.kind === "upload" ? await receiveUpload(event.data, opts.mediaMaxBytes) : [await serveDownload(event.data)];
          // The device's session as it is now: it may have handshaken again meanwhile.
          const now = served.get(deviceKey);
          if (now?.peer) sendFrames(replies.map((reply) => seal(now.session, reply)));
          return;
        }
        if (event?.kind === "foreground") {
          entry.foreground = event.data.convId ?? undefined;
          entry.active = event.data.active === true;
          return;
        }
        if (event?.kind === "error") return log?.info(`yorozu: device error ${event.data.code}`);
        if (event?.kind === "device_list" || event?.kind === "device_patch") {
          const answer = event.kind === "device_list" ? await deviceList(deviceKey) : await patchDevice(event.data, deviceKey);
          // The device's session as it is now: it may have handshaken again, or removed itself.
          const now = served.get(deviceKey);
          if (now?.peer) sendFrames([seal(now.session, answer)]);
          return;
        }
        if (event?.kind === "cron_list" || event?.kind === "conv_list" || event?.kind === "history" || event?.kind === "conv_patch") {
          const answer = await opts.onRequest?.(event);
          // The device's session as it is now: it may have handshaken again meanwhile.
          const now = served.get(deviceKey);
          if (answer && now?.peer) sendFrames([seal(now.session, answer)]);
        }
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
            relaySend = send;
            me.broadcast = broadcastHere;
            me.notify = notifyHere;
            me.mint = () =>
              new Promise((resolve, reject) => {
                const waiter = { resolve, reject };
                minting.push(waiter);
                setTimeout(() => {
                  const i = minting.indexOf(waiter);
                  if (i < 0) return;
                  minting.splice(i, 1);
                  reject(new Error("the relay did not answer the token request"));
                }, MINT_TIMEOUT_MS).unref();
                send(JSON.stringify({ type: "mint" }));
              });
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
              else if (frame?.type === "box") await box(frame);
            }
            // A frame the relay buffered while this host was away comes with a `seq` and replays until acked.
            if (Number.isSafeInteger(msg.seq)) send(JSON.stringify({ type: "ack", seq: msg.seq }));
            return;
          }
          case "token": {
            const waiter = minting.shift();
            if (typeof msg.token === "string" && Number.isSafeInteger(msg.expiresAt)) {
              waiter?.resolve({ token: msg.token, expiresAt: msg.expiresAt as number });
            } else waiter?.reject(new Error("the relay sent a malformed token"));
            return;
          }
          case "state":
            return log?.info(`yorozu: relay state: ${String(msg.state).slice(0, 64)}`);
          case "phones":
            // No device socket left: none has a conversation on screen, whatever it last said (#431).
            if (msg.count === 0) {
              for (const entry of served.values()) {
                entry.foreground = undefined;
                entry.active = undefined;
              }
            }
            return;
          default:
            return; // `owner`: not needed yet.
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
        if (registered) {
          relaySend = null;
          me.mint = null;
          me.broadcast = null;
          me.notify = null;
          for (const waiter of minting.splice(0)) waiter.reject(new Error("the relay connection closed"));
        }
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
  if (host === me) host = null;
}
