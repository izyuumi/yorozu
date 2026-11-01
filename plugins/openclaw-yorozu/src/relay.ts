import { randomBytes } from "node:crypto";
import os from "node:os";
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import { captureEffectAuthority } from "openclaw/plugin-sdk/fetch-runtime";
import { computeBackoff, sleepWithAbort } from "openclaw/plugin-sdk/runtime-env";
import { WebSocket, WebSocketServer } from "openclaw/plugin-sdk/websocket-runtime";
import { receiveUpload, receiveUploadStatus, serveDownload } from "./attachments.js";
import { getDevice, listDevices, putDevice, removeDevice } from "./devices.js";
import { serveBonjour } from "./bonjour.js";
import { watchDirect } from "./hints.js";
import { bindAddresses, serveDirect, type DirectListener } from "./direct.js";
import {
  ATTACHMENTS,
  DEVICES,
  DIRECT,
  INVITE,
  LIVE_ACTIVITY_PUSH,
  PUSH_PROXY,
  REACTIONS,
  REPLIES,
  RESUME,
  PROTOCOL_VERSION,
  type DirectHints,
  type DeviceList,
  type DevicePatch,
  type Event,
  type Message,
  type Reaction,
  type PeerInfo,
} from "./envelope.js";
import { CLOSE, Hub, type Link, type Request } from "./hub.js";
import type { HostKeys } from "./keys.js";
import { applyTurn, cleanJobs, holdFor, plan, type TurnChange, type WireJob } from "./liveactivity.js";
import { firstLine, previewKey, previewPlaintext, pushTitle, sealPreview, threadRef } from "./push.js";
import { listCursors, mergeCursor } from "./reads.js";
import { b64u, decodeFrame, fingerprint, helloProof, signFrame } from "./wire.js";

const PING = JSON.stringify({ type: "ping" });
const PONG = JSON.stringify({ type: "pong" });
const HEARTBEAT_MS = 30_000;
const BACKOFF = { initialMs: 1_000, maxMs: 30_000, factor: 2, jitter: 0.3 };
const BATCH_FRAMES = 16;
const BATCH_BYTES = 1024 * 1024 - 4096;

const PEER_INFO: PeerInfo = {
  protocolMin: PROTOCOL_VERSION,
  protocolMax: PROTOCOL_VERSION,
  app: "0.1.0",
  name: os.hostname().replace(/\.local$/, ""),
  capabilities: [ATTACHMENTS, DEVICES, INVITE, REPLIES, REACTIONS, RESUME],
};

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
  /** The direct listener's port (`channels.yorozu.direct`); absent when it is off. */
  directPort?: number;
  directBonjour?: boolean;
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
  broadcast: (events: Event[]) => number;
  notify: ((convId: string, messageId: string, text: string) => Promise<void>) | null;
  activityTurn: (convId: string, change: TurnChange) => void;
} | null = null;

export function broadcast(events: Event[]): number {
  return host?.broadcast(events) ?? 0;
}

/** A turn moved on: devices whose Live Activity shows it get a counts-only push. */
export function activityTurn(convId: string, change: TurnChange): void {
  host?.activityTurn(convId, change);
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
  const alerted = new Map<string, Set<string>>();

  const url = new URL(opts.relayUrl);
  url.searchParams.set("room", keys.room);

  let relaySend: ((raw: string) => void) | null = null;
  let relayFrames: ((payloads: string[]) => void) | null = null;
  let relayActivities = false;
  let relayPushProxy = false;
  let direct: DirectListener | null = null;
  let hints: DirectHints | undefined;
  let stopWatching: (() => Promise<void>) | undefined;
  let bonjour: Awaited<ReturnType<typeof serveBonjour>> | undefined;
  // Every relay session shares this link; it sends through whichever relay socket is registered.
  const relayLink: Link = { path: "relay", send: (payloads) => relayFrames?.(payloads) };

  // Live Activities by device key, kept across sessions: the app is suspended while they matter.
  type Watch = { jobs: WireJob[]; sent: WireJob[]; turns: Record<string, string>; pushedAt?: number; timer?: NodeJS.Timeout };
  const activities = new Map<string, Watch>();
  const forgetActivity = (deviceKey: string, tellRelay: boolean): void => {
    clearTimeout(activities.get(deviceKey)?.timer);
    activities.delete(deviceKey);
    if (tellRelay) relaySend?.(JSON.stringify({ type: "activityToken", device: deviceKey }));
  };
  const pushActivity = (deviceKey: string): void => {
    const watch = activities.get(deviceKey);
    if (!watch || !relaySend) return;
    const now = Date.now();
    const next = plan(watch.sent, watch.jobs, now);
    if (!next) return;
    const hold = holdFor(next.priority, watch.pushedAt, now);
    if (hold > 0) {
      watch.timer ??= setTimeout(() => {
        watch.timer = undefined;
        pushActivity(deviceKey);
      }, hold).unref();
      return;
    }
    clearTimeout(watch.timer);
    watch.timer = undefined;
    relaySend(JSON.stringify({ type: "activityPush", device: deviceKey, ...next }));
    watch.sent = watch.jobs;
    watch.pushedAt = now;
    if (next.event === "end") activities.delete(deviceKey);
  };
  const reportActivity = (deviceKey: string, report: Extract<Event, { kind: "live_activity" }>["data"]): void => {
    if (!relayActivities) return;
    if (!report.pushToken) return forgetActivity(deviceKey, true);
    const old = activities.get(deviceKey);
    clearTimeout(old?.timer);
    const jobs = cleanJobs(report.jobs);
    // The app already shows these jobs; the throttle keeps counting from the last push.
    activities.set(deviceKey, { jobs, sent: jobs, turns: { ...report.turns }, ...(old?.pushedAt !== undefined ? { pushedAt: old.pushedAt } : {}) });
    relaySend?.(JSON.stringify({ type: "activityToken", device: deviceKey, token: report.pushToken }));
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
  const syncHere = (convId: string, reader: string): void => {
    const marked = alerted.get(convId);
    alerted.delete(convId);
    const connected = hub.direct();
    const devices = [...(marked ?? [])].filter((key) => key !== reader && !connected.has(key));
    if (!devices.length) return;
    relaySend?.(JSON.stringify({ type: "notify", class: "sync", threadRef: threadRef(convId), devices }));
  };

  async function dispatch({ deviceKey, event, reply, refuse }: Request): Promise<boolean> {
    switch (event.kind) {
      case "reaction":
        opts.onReaction(event.data);
        return true;
      case "read_cursor": {
        const merged = await mergeCursor(event.data);
        hub.broadcast([{ kind: "read_cursor", data: merged }]);
        if (!merged.unread) syncHere(merged.convId, deviceKey);
        return true;
      }
      case "upload":
        reply(await receiveUpload(event.data, opts.mediaMaxBytes));
        return true;
      case "upload_status":
        reply(await receiveUploadStatus(event.data, opts.mediaMaxBytes));
        return true;
      case "download":
        reply([await serveDownload(event.data)]);
        return true;
      case "live_activity":
        reportActivity(deviceKey, event.data);
        return true;
      case "push_token":
        if (relayPushProxy && relaySend) relaySend(JSON.stringify({ type: "push", device: deviceKey, token: event.data.token }));
        else log?.info(`yorozu: push token dropped (the relay is ${relaySend ? "without pushProxy" : "unreachable"})`);
        return true;
      case "error":
        log?.info(`yorozu: device error ${event.data.code}`);
        return true;
      case "device_list":
        reply([await deviceList(deviceKey)]);
        return true;
      case "device_patch":
        reply([await patchDevice(event.data, deviceKey)]);
        return true;
      case "pair_invite":
        void (async () => {
          let answer: Event;
          try {
            const { link, webLink, fingerprint, expiresAt } = await beginPairing();
            answer = { kind: "pair_invite", data: { link, webLink, fingerprint, expiresAt } };
            log?.info("yorozu: pairing code made for a paired device");
          } catch (error) {
            answer = { kind: "pair_invite", data: { error: error instanceof Error ? error.message : String(error) } };
          }
          reply([answer]);
        })();
        return true;
      case "cron_list":
      case "conv_list":
      case "history":
      case "conv_patch": {
        const answer = await opts.onRequest?.(event);
        if (answer) reply([answer]);
        else if (event.kind !== "conv_patch") refuse({ code: "unsupported", message: `this host does not answer "${event.kind}"` });
        return true;
      }
      default:
        return false;
    }
  }

  const hub: Hub = new Hub({
    keys,
    log,
    peerInfo: () => ({
      ...peerInfo,
      capabilities: [
        ...peerInfo.capabilities,
        ...(relayActivities ? [LIVE_ACTIVITY_PUSH] : []),
        ...(direct?.listening ? [DIRECT] : []),
        ...(relayPushProxy ? [PUSH_PROXY] : []),
      ],
    }),
    directHints: () => direct?.listening ? hints : undefined,
    staticKeyOf: async (deviceKey) => (await getDevice(deviceKey))?.staticPub,
    pair: async (proof, staticPub, deviceKey, now) => {
      const secret = provenSecret(proof, staticPub, deviceKey, now);
      if (!secret) return false;
      pending.delete(secret);
      const evicted = await putDevice({ signingPub: deviceKey, staticPub, pairedAt: now });
      me.forget(evicted);
      log?.info(`yorozu: device paired${evicted.length ? " (the oldest made way)" : ""}`);
      return true;
    },
    refused: (deviceKey) => relaySend?.(JSON.stringify({ type: "revoke", pubkey: deviceKey })),
    onPeer: async ({ deviceKey, event, reply }) => {
      if (event.kind !== "peer_info") return;
      const name = event.data.name?.trim().slice(0, 64);
      const device = name ? await getDevice(deviceKey) : undefined;
      if (device && name && device.name !== name) await putDevice({ ...device, name });
      const cursors = await listCursors();
      if (cursors.length) reply(cursors.map((data) => ({ kind: "read_cursor", data })));
    },
    onMessage: opts.onMessage,
    dispatch,
  });

  const me: NonNullable<typeof host> = (host = {
    relayUrl: opts.relayUrl,
    keys,
    mint: null,
    broadcast: (events) => hub.broadcast(events),
    notify: null,
    forget: (deviceKeys) => {
      for (const key of deviceKeys) {
        hub.end(key, { code: CLOSE.unauthorized, reason: "revoked" });
        forgetActivity(key, false);
        relaySend?.(JSON.stringify({ type: "revoke", pubkey: key }));
      }
    },
    activityTurn: (convId, change) => {
      const now = Date.now();
      for (const [deviceKey, watch] of activities) {
        if (!Object.values(watch.turns).includes(convId)) continue;
        watch.jobs = applyTurn(watch.jobs, watch.turns, convId, change, now);
        pushActivity(deviceKey);
      }
    },
  });

  if (opts.directPort !== undefined) {
    direct = await serveDirect({
      addresses: bindAddresses(os.networkInterfaces()),
      port: opts.directPort,
      keys,
      hub,
      server: (options) => new WebSocketServer(options),
      transmit: (socket, raw) =>
        void captureEffectAuthority()
          .initiate(() => socket.send(raw))
          .catch((error: unknown) => log?.warn(`yorozu: direct send failed: ${String(error)}`)),
      log,
    });
    stopWatching = await watchDirect({ listener: direct, port: opts.directPort, log, changed: async (next) => {
      hints = next;
      if (next) hub.broadcast([{ kind: "direct_hints", data: next }]);
      if (opts.directBonjour !== false) {
        const addresses = next?.lan.filter((i) => !i.address.includes(":")) ?? [];
        if (!addresses.length) {
          await bonjour?.close();
          bonjour = undefined;
        } else if (bonjour) await bonjour.update(addresses);
        else bonjour = await serveBonjour({ hostStaticPub: keys.static.publicKey, port: opts.directPort!, addresses, log });
      }
    } });
    if (!direct.listening) log?.warn(`yorozu: direct listener could not bind port ${opts.directPort}; relay only`);
  }

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
      const notifyHere = async (convId: string, messageId: string, text: string): Promise<void> => {
        const body = firstLine(text);
        if (!body) return;
        const watching = hub.watching(convId);
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
            relayFrames = sendFrames;
            relayActivities = msg.liveActivity === true;
            relayPushProxy = msg.pushProxy === true;
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
              if (frame?.type === "init") await hub.handshake(msg.payload, msg.sig, relayLink);
              else if (frame?.type === "box") {
                const opened = hub.open(frame, relayLink);
                if (opened) await hub.handle(opened);
              }
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
          case "activityGone":
            if (typeof msg.device === "string") forgetActivity(msg.device, false);
            return;
          case "phones":
            if (msg.count === 0) hub.relayGone();
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
          relayFrames = null;
          me.mint = null;
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
  await stopWatching?.();
  await bonjour?.close();
  await direct?.close();
  if (host === me) host = null;
}
