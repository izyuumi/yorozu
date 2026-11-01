// The sessions the plugin serves, each over its own path: the relay or the direct listener (#532). Imports only node
// built-ins and the pure wire and envelope files, so the direct path's end-to-end test runs it without OpenClaw.
import {
  ATTACHMENTS,
  encodeEvent,
  negotiate,
  parseEvent,
  PROTOCOL_VERSION,
  REACTIONS,
  REPLIES,
  rejection,
  type ErrorInfo,
  type Event,
  type Message,
  type PeerInfo,
} from "./envelope.js";
import { acceptHandshake, b64u, HANDSHAKE_MAX_AGE_MS, type Frame, type Keypair, type Session } from "./wire.js";

const TAKEN_MS = 24 * 60 * 60 * 1000;
const TAKEN_MAX = 10_000;

/** Close codes of the direct path (capability `direct`, #532), apart from the relay's. */
export const CLOSE = { unauthorized: 4101, replaced: 4102, tooLarge: 4103 } as const;

export type Log = { info: (message: string) => void; warn: (message: string) => void };
export type Path = "relay" | "direct";
/** Where a session's frames go: the one relay link every relay session shares, or one direct socket. */
export type Link = { path: Path; send: (payloads: string[]) => void; close?: (code: number, reason: string) => void };
export type Served = { session: Session; link: Link; peer?: PeerInfo; foreground?: string; active?: boolean };
export type Opened = { deviceKey: string; entry: Served; plain: Buffer };
export type Request = {
  deviceKey: string;
  event: Event;
  /** Seals for the device's current session, once it has sent `peer_info`. */
  reply: (events: Event[]) => void;
  refuse: (data: ErrorInfo) => void;
};

export type HubOptions = {
  keys: { static: Keypair; room: string };
  peerInfo: () => PeerInfo;
  /** The allowlisted device's X25519 key, base64url. */
  staticKeyOf: (deviceKey: string) => Promise<string | undefined>;
  /** Relay only (offline pairing is #532 step 5): stores a device whose proof matches a pending pairing. */
  pair?: (proof: string | undefined, staticPub: string, deviceKey: string, now: number) => Promise<boolean>;
  /** A relay handshake from a device that is not allowlisted. */
  refused?: (deviceKey: string) => void;
  onPeer?: (request: Request) => Promise<void>;
  onMessage: (message: Message) => void;
  /** Every other event after `peer_info`; false when the plugin does not take it from a device. */
  dispatch: (request: Request) => Promise<boolean>;
  log?: Log;
};

export function downgrade(event: Event, peer: PeerInfo): Event {
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

const seal = (session: Session, event: Event): string => session.seal(encodeEvent(event));

export class Hub {
  readonly served = new Map<string, Served>();
  private readonly bySid = new Map<string, string>();
  private readonly answered = new Map<string, number>();
  private readonly taken = new Map<string, number>();
  private readonly opts: HubOptions;

  constructor(opts: HubOptions) {
    this.opts = opts;
  }

  private drop(reason: string): null {
    this.opts.log?.info(`yorozu: handshake dropped (${reason})`);
    return null;
  }

  end(deviceKey: string, close?: { code: number; reason: string }): void {
    const old = this.served.get(deviceKey);
    if (!old) return;
    this.bySid.delete(b64u(old.session.sid));
    this.served.delete(deviceKey);
    if (close) old.link.close?.(close.code, close.reason);
  }

  /** The link went away: its sessions end. */
  detach(link: Link): void {
    for (const [key, entry] of this.served) if (entry.link === link) this.end(key);
  }

  /** Answers an init frame on `link`; the device's key when its session opened. */
  async handshake(payload: string, sig: string, link: Link): Promise<string | null> {
    const now = Date.now();
    const { keys } = this.opts;
    const accepted = acceptHandshake({ host: keys.static, room: keys.room, payload, sig, now });
    if (!accepted) return this.drop("invalid or stale");
    const deviceKey = b64u(accepted.deviceSigningKey);
    const staticPub = b64u(accepted.deviceStatic);
    for (const [sid, until] of this.answered) if (until < now) this.answered.delete(sid);
    if (this.answered.has(accepted.sid)) return this.drop("replayed");
    const known = (await this.opts.staticKeyOf(deviceKey)) === staticPub;
    const paired = !known && link.path === "relay" && (await this.opts.pair?.(accepted.payload.proof, staticPub, deviceKey, now));
    if (!known && !paired) {
      if (link.path === "relay") this.opts.refused?.(deviceKey);
      return this.drop("device not allowlisted");
    }
    if (this.answered.has(accepted.sid)) return this.drop("replayed");
    this.answered.set(accepted.sid, accepted.payload.ts + HANDSHAKE_MAX_AGE_MS);
    const old = this.served.get(deviceKey);
    this.end(deviceKey, old && old.link !== link ? { code: CLOSE.replaced, reason: "replaced" } : undefined);
    this.served.set(deviceKey, { session: accepted.session, link });
    this.bySid.set(accepted.sid, deviceKey);
    link.send([accepted.response, seal(accepted.session, { kind: "peer_info", data: this.opts.peerInfo() })]);
    this.opts.log?.info(`yorozu: session open over ${link.path} (${this.served.size} device${this.served.size === 1 ? "" : "s"})`);
    return deviceKey;
  }

  /** Opens a box that arrived on `link` under one of its sessions. */
  open(frame: Frame, link: Link): Opened | null {
    const deviceKey = frame.type === "box" ? this.bySid.get(b64u(frame.sid)) : undefined;
    const entry = deviceKey ? this.served.get(deviceKey) : undefined;
    const plain = entry?.link === link ? entry.session.open(frame) : null;
    if (!deviceKey || !entry || !plain) {
      this.opts.log?.info(`yorozu: dropped a frame no open session can read (${deviceKey ? "undecryptable" : "unknown session"})`);
      return null;
    }
    return { deviceKey, entry, plain };
  }

  async handle({ deviceKey, entry, plain }: Opened): Promise<void> {
    const { log } = this.opts;
    const event = parseEvent(plain);
    const refuse = (data: ErrorInfo) => {
      log?.warn(`yorozu: refused a device event: ${data.code}: ${data.message}`);
      const now = this.served.get(deviceKey);
      if (now) now.link.send([seal(now.session, { kind: "error", data })]);
    };
    if (entry.peer && (event === null || event.kind === "invalid" || event.kind === "unknown")) {
      return refuse(rejection(event));
    }
    if (event === null || event.kind === "invalid" || event.kind === "unknown") {
      return refuse({ code: "bad_request", message: "the session must start with peer_info" });
    }
    const reply = (events: Event[]) => {
      const now = this.served.get(deviceKey);
      if (now?.peer) now.link.send(events.map((answer) => seal(now.session, downgrade(answer, now.peer!))));
    };
    const request: Request = { deviceKey, event, reply, refuse };
    if (!entry.peer) {
      if (event.kind !== "peer_info") return refuse({ code: "bad_request", message: "the session must start with peer_info" });
      if (negotiate(this.opts.peerInfo(), event.data) === null) {
        entry.link.send([seal(entry.session, { kind: "error", data: { code: "update_required", message: "no common protocol version" } })]);
        this.end(deviceKey);
        return log?.info("yorozu: session closed (update required)");
      }
      entry.peer = event.data;
      await this.opts.onPeer?.(request);
      return log?.info(`yorozu: peer_info received (protocol ${PROTOCOL_VERSION})`);
    }
    if (event.kind === "message") {
      const { convId, messageId } = event.data;
      this.broadcast([{ kind: "delivered", data: { convId, messageId } }]);
      const now = Date.now();
      if (this.taken.has(messageId)) return;
      for (const [id, at] of this.taken) {
        if (at > now - TAKEN_MS && this.taken.size < TAKEN_MAX) break;
        this.taken.delete(id);
      }
      this.taken.set(messageId, now);
      return this.opts.onMessage(event.data);
    }
    if (event.kind === "foreground") {
      entry.foreground = event.data.convId ?? undefined;
      entry.active = event.data.active === true;
      return;
    }
    if (event.kind === "peer_info") return log?.info("yorozu: peer_info repeated; the first one stands");
    if (!(await this.opts.dispatch(request))) refuse({ code: "unsupported", message: `a device cannot send "${event.kind}"` });
  }

  /** Every device with a live session, each over its own path: the relay batch skips devices connected directly. */
  broadcast(events: Event[]): number {
    const live = [...this.served.values()].filter((entry) => entry.peer);
    const takes = (event: Event, peer: PeerInfo) => event.kind !== "reaction" || peer.capabilities.includes(REACTIONS);
    const out = new Map<Link, string[]>();
    for (const event of events) {
      for (const entry of live) {
        if (!takes(event, entry.peer!)) continue;
        const payloads = out.get(entry.link) ?? [];
        payloads.push(seal(entry.session, downgrade(event, entry.peer!)));
        out.set(entry.link, payloads);
      }
    }
    for (const [link, payloads] of out) link.send(payloads);
    return live.length;
  }

  /** Devices whose live session, on either path, has the app active or this conversation in front. */
  watching(convId: string): Set<string> {
    return new Set(
      [...this.served].filter(([, entry]) => entry.peer && (entry.active || entry.foreground === convId)).map(([key]) => key),
    );
  }

  /** Devices connected directly. */
  direct(): Set<string> {
    return new Set([...this.served].filter(([, entry]) => entry.link.path === "direct").map(([key]) => key));
  }

  /** The relay has no device sockets left: only relay sessions lose their foreground. */
  relayGone(): void {
    for (const entry of this.served.values()) {
      if (entry.link.path !== "relay") continue;
      entry.foreground = undefined;
      entry.active = undefined;
    }
  }
}
