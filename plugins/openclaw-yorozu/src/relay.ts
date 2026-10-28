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
  INVITE,
  REACTIONS,
  REPLIES,
  negotiate,
  parseEvent,
  PROTOCOL_VERSION,
  rejection,
  type DeviceList,
  type DevicePatch,
  type ErrorInfo,
  type Event,
  type Message,
  type Reaction,
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

const PING = JSON.stringify({ type: "ping" });
const PONG = JSON.stringify({ type: "pong" });
const HEARTBEAT_MS = 30_000;
const BACKOFF = { initialMs: 1_000, maxMs: 30_000, factor: 2, jitter: 0.3 };
const BATCH_FRAMES = 16;
const BATCH_BYTES = 1024 * 1024 - 4096;
const TAKEN_MS = 24 * 60 * 60 * 1000;
const TAKEN_MAX = 10_000;

const PEER_INFO: PeerInfo = {
  protocolMin: PROTOCOL_VERSION,
  protocolMax: PROTOCOL_VERSION,
  app: "0.1.0",
  name: os.hostname().replace(/\.local$/, ""),
  capabilities: [ATTACHMENTS, DEVICES, INVITE, REPLIES, REACTIONS],
};

function downgrade(event: Event, peer: PeerInfo): Event {
  if (!peer.capabilities.includes(REPLIES)) {
    if (event.kind === "reply" && event.data.replyTo) {
      const { replyTo: _, ...reply } = event.data;
      event = { kind: "reply", data: reply };
    } else if (event.kind === "history" && "items" in event.data) {
      const items = event.data.items.map((item) => ("replyTo" in item ? { ...item, replyTo: undefined } : item));
      event = { kind: "history", data: { ...event.data, items } };
    }
  }
  if (!peer.capabilities.includes(REACTIONS) && event.kind === "history" && "items" in event.data) {
    const items = event.data.items.map((item) => ("reactions" in item ? { ...item, reactions: undefined } : item));
    event = { kind: "history", data: { ...event.data, items } };
  }
  if (peer.capabilities.includes(ATTACHMENTS) || event.kind !== "reply" || !event.data.attachments) return event;
  const { attachments, ...reply } = event.data;
  const lines = attachments.map((a) => `(Attachment: ${a.name}; update Yorozu to open it.)`);
  return { kind: "reply", data: { ...reply, text: [reply.text, ...lines].filter(Boolean).join("\n\n") } };
}

type Served = { session: Session; peer?: PeerInfo; foreground?: string; active?: boolean };
type Status = { connected: boolean; error?: string };

export type RelayHostOptions = {
  relayUrl: string;
  keys: HostKeys;
  signal: AbortSignal;
  log?: ChannelGatewayContext["log"];
  onStatus: (status: Status) => void;
  onMessage: (message: Message) => void;
  onReaction: (reaction: Reaction) => void;
  onRequest?: (event: Event) => Promise<Event | undefined>;
  mediaMaxBytes: number;
  agent?: string;
  hostVersion?: string;
};

export type Pairing = {
  link: string;
  webLink: string;
  fingerprint: string;
  expiresAt: number;
  devices: number;
};

const PAIR_WEB_LINK = "https://yorozu.yumi.to/pair";
const MINT_TIMEOUT_MS = 10_000;

const pending = new Map<string, number>();
let host: {
  relayUrl: string;
  keys: HostKeys;
  mint: (() => Promise<{ token: string; expiresAt: number }>) | null;
  forget: (deviceKeys: string[]) => void;
  broadcast: ((events: Event[]) => number) | null;
  notify: ((convId: string, messageId: string, text: string) => Promise<void>) | null;
} | null = null;

export function broadcast(events: Event[]): number {
  return host?.broadcast?.(events) ?? 0;
}

export async function notifyReply(convId: string, messageId: string, text: string): Promise<void> {
  await host?.notify?.(convId, messageId, text);
}

export async function beginPairing(): Promise<Pairing> {
  if (!host?.mint) throw new Error("the yorozu channel is not connected to its relay; check `openclaw channels status`");
  const { relayUrl, keys } = host;
  const { token, expiresAt } = await host.mint();
  const secret = b64u(randomBytes(32));
  const now = Date.now();
  for (const [old, until] of pending) if (until < now) pending.delete(old);
  pending.set(secret, expiresAt);
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

export async function unpairDevice(deviceKey: string): Promise<boolean> {
  const removed = await removeDevice(deviceKey);
  host?.forget([deviceKey]);
  return removed;
}

function provenSecret(proof: string | undefined, staticPub: string, signingPub: string, now: number): string | undefined {
  if (!proof) return undefined;
  for (const [secret, until] of pending) {
    if (until >= now && helloProof(secret, staticPub, signingPub) === proof) return secret;
  }
  return undefined;
}

export async function runRelayHost(opts: RelayHostOptions): Promise<void> {
  const { keys, signal, log } = opts;
  const peerInfo: PeerInfo = {
    ...PEER_INFO,
    mediaMaxBytes: opts.mediaMaxBytes,
    ...(opts.agent && { agent: opts.agent }),
    ...(opts.hostVersion && { hostVersion: opts.hostVersion }),
  };
  const served = new Map<string, Served>();
  const bySid = new Map<string, string>();
  const answered = new Map<string, number>();
  const taken = new Map<string, number>();
  const alerted = new Map<string, Set<string>>();

  const url = new URL(opts.relayUrl);
  url.searchParams.set("room", keys.room);

  const drop = (reason: string) => log?.info(`yorozu: handshake dropped (${reason})`);
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
      const minting: { resolve: (t: { token: string; expiresAt: number }) => void; reject: (e: Error) => void }[] = [];

      const send = (raw: string): void => {
        if (ws.readyState !== WebSocket.OPEN) return;
        captureEffectAuthority()
          .initiate(() => ws.send(raw))
          .catch((error: unknown) => log?.warn(`yorozu: relay send failed: ${String(error)}`));
      };
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
        const takes = (event: Event, peer: PeerInfo) => event.kind !== "reaction" || peer.capabilities.includes(REACTIONS);
        sendFrames(
          events.flatMap((event) =>
            live.filter((entry) => takes(event, entry.peer!)).map((entry) => seal(entry.session, downgrade(event, entry.peer!))),
          ),
        );
        return live.length;
      };
      const seal = (session: Session, event: Event): string => session.seal(encodeEvent(event));
      const notifyHere = async (convId: string, messageId: string, text: string): Promise<void> => {
        const body = firstLine(text);
        if (!body) return;
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
      const syncHere = (convId: string, reader: string): void => {
        const marked = alerted.get(convId);
        alerted.delete(convId);
        const devices = [...(marked ?? [])].filter((key) => key !== reader);
        if (!devices.length) return;
        send(JSON.stringify({ type: "notify", class: "sync", threadRef: threadRef(convId), devices }));
      };
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
        if (!deviceKey || !entry || !plain) {
          return log?.info(`yorozu: dropped a frame no open session can read (${deviceKey ? "undecryptable" : "unknown session"})`);
        }
        const event = parseEvent(plain);
        const refuse = (data: ErrorInfo) => {
          log?.warn(`yorozu: refused a device event: ${data.code}: ${data.message}`);
          const now = served.get(deviceKey);
          if (now) sendFrames([seal(now.session, { kind: "error", data })]);
        };
        if (entry.peer && (event === null || event.kind === "invalid" || event.kind === "unknown")) {
          return refuse(rejection(event));
        }
        if (!entry.peer) {
          if (event?.kind !== "peer_info") {
            return refuse({ code: "bad_request", message: "the session must start with peer_info" });
          }
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
          const name = event.data.name?.trim().slice(0, 64);
          const device = name ? await getDevice(deviceKey) : undefined;
          if (device && name && device.name !== name) await putDevice({ ...device, name });
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
        if (event?.kind === "reaction") return opts.onReaction(event.data);
        if (event?.kind === "read_cursor") {
          const merged = await mergeCursor(event.data);
          broadcastHere([{ kind: "read_cursor", data: merged }]);
          if (!merged.unread) syncHere(merged.convId, deviceKey);
          return;
        }
        if (event?.kind === "upload" || event?.kind === "download") {
          const replies =
            event.kind === "upload" ? await receiveUpload(event.data, opts.mediaMaxBytes) : [await serveDownload(event.data)];
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
          const now = served.get(deviceKey);
          if (now?.peer) sendFrames([seal(now.session, answer)]);
          return;
        }
        if (event?.kind === "pair_invite") {
          void (async () => {
            let answer: Event;
            try {
              const { link, webLink, fingerprint, expiresAt } = await beginPairing();
              answer = { kind: "pair_invite", data: { link, webLink, fingerprint, expiresAt } };
              log?.info("yorozu: pairing code made for a paired device");
            } catch (error) {
              answer = { kind: "pair_invite", data: { error: error instanceof Error ? error.message : String(error) } };
            }
            const now = served.get(deviceKey);
            if (now?.peer) sendFrames([seal(now.session, answer)]);
          })();
          return;
        }
        if (event?.kind === "cron_list" || event?.kind === "conv_list" || event?.kind === "history" || event?.kind === "conv_patch") {
          const answer = await opts.onRequest?.(event);
          if (!answer) {
            if (event.kind === "conv_patch") return;
            return refuse({ code: "unsupported", message: `this host does not answer "${event.kind}"` });
          }
          const now = served.get(deviceKey);
          if (now?.peer) sendFrames([seal(now.session, downgrade(answer, now.peer))]);
          return;
        }
        if (event?.kind === "peer_info") return log?.info("yorozu: peer_info repeated; the first one stands");
        return refuse({ code: "unsupported", message: `a device cannot send "${event?.kind}"` });
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
            if (msg.count === 0) {
              for (const entry of served.values()) {
                entry.foreground = undefined;
                entry.active = undefined;
              }
            }
            return;
          default:
            return;
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
