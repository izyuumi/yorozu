import {
  ATTACHMENTS,
  DIRECT,
  type DirectHints,
  encodeEvent,
  negotiate,
  parseEvent,
  PRESENTATION,
  PROTOCOL_VERSION,
  REACTIONS,
  REPLIES,
  rejection,
  type ErrorInfo,
  type Event,
  type Message,
  type PeerInfo,
} from "./envelope.js";
import { acceptHandshake, b64u, HANDSHAKE_MAX_AGE_MS, type AcceptedHandshake, type Frame, type Keypair, type Session } from "./wire.js";

const TAKEN_MS = 24 * 60 * 60 * 1000;
const TAKEN_MAX = 10_000;

export const CLOSE = { unauthorized: 4101, replaced: 4102, tooLarge: 4103 } as const;

export type Log = { info: (message: string) => void; warn: (message: string) => void };
export type Path = "relay" | "direct";
export type Link = { path: Path; send: (payloads: string[]) => void; close?: (code: number, reason: string) => void };
export type DeviceSession = { browser?: true } & (
  | { phase: "awaitingPeer"; session: Session; link: Link }
  | { phase: "live"; session: Session; link: Link; peer: PeerInfo; foreground?: string; active?: boolean });
export type Opened = { deviceKey: string; entry: DeviceSession; plain: Buffer };
export type Request = {
  deviceKey: string;
  event: Event;
  reply: (events: Event[]) => void;
  refuse: (data: ErrorInfo) => void;
};

export type StaticKey = { browser: true } | { staticPub: string } | { absent: true } | { unread: true };

export type HubOptions = {
  keys: { static: Keypair; room: string };
  peerInfo: () => PeerInfo;
  staticKeyOf: (deviceKey: string) => Promise<StaticKey | string | null | undefined>;
  pair?: (proof: string | undefined, staticPub: string, deviceKey: string, now: number, path: Path) => Promise<boolean>;
  browser?: {
    canPair: (accepted: AcceptedHandshake, now: number) => boolean;
    authorize: (accepted: AcceptedHandshake, wasKnown: boolean, stillPending: () => boolean) => Promise<boolean>;
  };
  refused?: (deviceKey: string) => void;
  directHints?: () => DirectHints | undefined;
  onPeer?: (request: Request) => Promise<void>;
  claim?: (message: Message) => "fresh" | "duplicate";
  onMessage: (message: Message) => void;
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
  if (!peer.capabilities.includes(PRESENTATION)) {
    if (event.kind === "reply" && event.data.presentation) {
      const { presentation: _, ...reply } = event.data;
      event = { kind: "reply", data: reply };
    } else if (event.kind === "history" && "items" in event.data && event.data.items.some((item) => "presentation" in item)) {
      const items = event.data.items.map((item) => {
        if (!("presentation" in item)) return item;
        const { presentation: _, ...rest } = item;
        return rest;
      });
      event = { kind: "history", data: { ...event.data, items } };
    }
  }
  if (peer.capabilities.includes(ATTACHMENTS) || event.kind !== "reply" || !event.data.attachments) return event;
  const { attachments, ...reply } = event.data;
  const lines = attachments.map((a) => `(Attachment: ${a.name}; update Yorozu to open it.)`);
  return { kind: "reply", data: { ...reply, text: [reply.text, ...lines].filter(Boolean).join("\n\n") } };
}

type BrowserChallenge = { deviceKey: string; entry: DeviceSession; accepted: AcceptedHandshake; known: boolean; expires: number; confirming?: boolean };

const seal = (session: Session, event: Event): string => session.seal(encodeEvent(event));

function browserOutput(event: Event): Event[] {
  if (event.kind === "reply") {
    const {convId, messageId, text, ts} = event.data;
    return [{kind: "reply", data: {convId, messageId, text, ts}}];
  }
  if (event.kind === "history" && "items" in event.data) {
    const items = event.data.items.flatMap((item) => item.kind === "user" || item.kind === "agent"
      ? [{kind: item.kind, id: item.id, seq: item.seq, ts: item.ts, text: item.text}] : []);
    return [{kind: "history", data: {...event.data, items, browserOldest: event.data.items[0]?.seq}}];
  }
  return ["conv_list", "conv_update", "delivered", "run_started", "typing", "error"].includes(event.kind) ? [event] : [];
}

export class Hub {
  readonly served = new Map<string, DeviceSession>();
  private readonly bySid = new Map<string, string>();
  private readonly answered = new Map<string, number>();
  private readonly browserChallenges = new Map<string, BrowserChallenge>();
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

  revoke(deviceKey: string): void {
    for (const [sid, challenge] of this.browserChallenges) if (challenge.deviceKey === deviceKey) this.browserChallenges.delete(sid);
    this.end(deviceKey, { code: CLOSE.unauthorized, reason: "revoked" });
  }

  detach(link: Link): void {
    for (const [sid, value] of this.browserChallenges) if (value.entry.link === link) this.browserChallenges.delete(sid);
    for (const [key, entry] of this.served) if (entry.link === link) this.end(key);
  }

  async handshake(payload: string, sig: string, link: Link): Promise<string | null> {
    const now = Date.now();
    const { keys } = this.opts;
    const accepted = acceptHandshake({ host: keys.static, room: keys.room, payload, sig, now });
    if (!accepted) return this.drop("invalid or stale");
    const deviceKey = b64u(accepted.deviceSigningKey);
    const staticPub = b64u(accepted.deviceStatic);
    for (const [sid, until] of this.answered) if (until < now) this.answered.delete(sid);
    if (this.answered.has(accepted.sid)) return this.drop("replayed");
    const found = await this.opts.staticKeyOf(deviceKey).catch((): StaticKey => ({ unread: true }));
    const listed: StaticKey = typeof found === "string" ? { staticPub: found } : found ?? { absent: true };
    if ("unread" in listed) return this.drop("device allowlist unreadable");
    if (accepted.browser) {
      const browser = this.opts.browser;
      if (!browser || link.path !== "relay") return this.drop("browser mode unavailable");
      const known = "browser" in listed;
      if (!known && (!("absent" in listed) || !browser.canPair(accepted, now))) return this.drop("browser not authorized");
      for (const [sid, challenge] of this.browserChallenges) if (challenge.expires <= now) this.browserChallenges.delete(sid);
      if (this.answered.has(accepted.sid) || this.bySid.has(accepted.sid) || this.browserChallenges.has(accepted.sid) ||
          this.browserChallenges.size >= 32 || this.answered.size >= 4096) return this.drop("browser init replayed or at capacity");
      this.answered.set(accepted.sid, now + 2 * HANDSHAKE_MAX_AGE_MS);
      const entry: DeviceSession = { phase: "awaitingPeer", session: accepted.session, link, browser: true };
      this.browserChallenges.set(accepted.sid, { deviceKey, entry, accepted, known, expires: now + 15_000 });
      link.send([accepted.response]);
      return deviceKey;
    }
    if ("browser" in listed) return this.drop("mode mismatch");
    const known = "staticPub" in listed && listed.staticPub === staticPub;
    const paired = !known && (await this.opts.pair?.(accepted.payload.proof, staticPub, deviceKey, now, link.path));
    if (!known && !paired) {
      if (link.path === "relay") this.opts.refused?.(deviceKey);
      return this.drop("device not allowlisted");
    }
    if (this.answered.has(accepted.sid)) return this.drop("replayed");
    this.answered.set(accepted.sid, accepted.payload.ts + HANDSHAKE_MAX_AGE_MS);
    const old = this.served.get(deviceKey);
    this.end(deviceKey, old && old.link !== link ? { code: CLOSE.replaced, reason: "replaced" } : undefined);
    this.served.set(deviceKey, { phase: "awaitingPeer", session: accepted.session, link });
    this.bySid.set(accepted.sid, deviceKey);
    link.send([accepted.response, seal(accepted.session, { kind: "peer_info", data: this.opts.peerInfo() })]);
    this.opts.log?.info(`yorozu: session open over ${link.path} (${this.served.size} device${this.served.size === 1 ? "" : "s"})`);
    return deviceKey;
  }

  open(frame: Frame, link: Link): Opened | null {
    const pending = frame.type === "box" ? this.browserChallenges.get(b64u(frame.sid)) : undefined;
    if (pending?.entry.link === link && !pending.confirming && pending.expires > Date.now()) {
      const plain = pending.entry.session.open(frame);
      return plain ? { deviceKey: pending.deviceKey, entry: pending.entry, plain } : null;
    }
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
    const sid = entry.browser ? b64u(entry.session.sid) : undefined;
    const challenge = sid ? this.browserChallenges.get(sid) : undefined;
    if (sid && challenge?.entry === entry) {
      if (challenge.confirming) return;
      if (event?.kind !== "peer_info" || negotiate(this.opts.peerInfo(), event.data) === null ||
          !event.data.capabilities.includes("browser-ephemeral-v1")) { this.browserChallenges.delete(sid); return; }
      challenge.confirming = true;
      const stillPending = () => this.browserChallenges.get(sid) === challenge && challenge.expires > Date.now();
      if (!stillPending() || !(await this.opts.browser?.authorize(challenge.accepted, challenge.known, stillPending)) || !stillPending()) {
        this.browserChallenges.delete(sid);
        return;
      }
      this.browserChallenges.delete(sid);
      const old = this.served.get(deviceKey);
      this.end(deviceKey, old && old.link !== entry.link ? { code: CLOSE.replaced, reason: "replaced" } : undefined);
      this.served.set(deviceKey, entry);
      this.bySid.set(sid, deviceKey);
      const hostPeer = this.opts.peerInfo();
      entry.link.send([seal(entry.session, { kind: "peer_info", data: {
        ...hostPeer, capabilities: ["browser-ephemeral-v1"],
      } })]);
    }
    if (this.served.get(deviceKey) !== entry) return;
    const refuse = (data: ErrorInfo) => {
      log?.warn(`yorozu: refused a device event: ${data.code}: ${data.message}`);
      const now = this.served.get(deviceKey);
      if (now) now.link.send([seal(now.session, { kind: "error", data })]);
    };
    if (entry.phase === "live" && (event === null || event.kind === "invalid" || event.kind === "unknown")) {
      return refuse(rejection(event));
    }
    if (event === null || event.kind === "invalid" || event.kind === "unknown") {
      return refuse({ code: "bad_request", message: "the session must start with peer_info" });
    }
    const reply = (events: Event[]) => {
      const now = this.served.get(deviceKey);
      if (now?.phase === "live") {
        const allowed = now.browser ? events.flatMap(browserOutput) : events.map((answer) => downgrade(answer, now.peer));
        if (allowed.length) now.link.send(allowed.map((answer) => seal(now.session, answer)));
      }
    };
    const request: Request = { deviceKey, event, reply, refuse };
    if (entry.phase === "awaitingPeer") {
      if (event.kind !== "peer_info") return refuse({ code: "bad_request", message: "the session must start with peer_info" });
      if (negotiate(this.opts.peerInfo(), event.data) === null) {
        entry.link.send([seal(entry.session, { kind: "error", data: { code: "update_required", message: "no common protocol version" } })]);
        this.end(deviceKey);
        return log?.info("yorozu: session closed (update required)");
      }
      if (this.served.get(deviceKey) !== entry) return;
      this.served.set(deviceKey, { phase: "live", session: entry.session, link: entry.link, peer: event.data, ...(entry.browser && { browser: true }) });
      const hints = entry.browser ? undefined : this.opts.directHints?.();
      if (hints && event.data.capabilities.includes(DIRECT)) reply([{ kind: "direct_hints", data: hints }]);
      await this.opts.onPeer?.(request);
      return log?.info(`yorozu: peer_info received (protocol ${PROTOCOL_VERSION})`);
    }
    if (entry.browser && !["message", "history", "conv_list", "foreground", "peer_info"].includes(event.kind)) {
      return refuse({ code: "unsupported", message: "browser devices can only chat" });
    }
    if (event.kind === "message") {
      if (entry.browser && (Object.keys(event.data).length !== 3 || !event.data.text.trim() || event.data.text.length > 60_000)) {
        return refuse({ code: "unsupported", message: "browser messages accept only text", convId: event.data.convId, messageId: event.data.messageId });
      }
      const { convId, messageId } = event.data;
      const claim = this.opts.claim?.(event.data);
      this.broadcast([{ kind: "delivered", data: { convId, messageId } }]);
      if (claim) {
        if (claim === "fresh") this.opts.onMessage(event.data);
        return;
      }
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
      if (this.served.get(deviceKey) !== entry) return;
      entry.foreground = event.data.convId ?? undefined;
      entry.active = event.data.active === true;
      return;
    }
    if (event.kind === "peer_info") return log?.info("yorozu: peer_info repeated; the first one stands");
    if (!(await this.opts.dispatch(request))) refuse({ code: "unsupported", message: `a device cannot send "${event.kind}"` });
  }

  broadcast(events: Event[]): number {
    const live = [...this.served.values()].filter((entry) => entry.phase === "live");
    const takes = (event: Event, peer: PeerInfo, browser?: true) =>
      event.kind === "direct_hints" ? !browser && !!this.opts.directHints?.() && peer.capabilities.includes(DIRECT) :
        event.kind !== "reaction" || peer.capabilities.includes(REACTIONS);
    const out = new Map<Link, string[]>();
    for (const event of events) {
      for (const entry of live) {
        if (!takes(event, entry.peer, entry.browser)) continue;
        const payloads = out.get(entry.link) ?? [];
        const allowed = entry.browser ? browserOutput(event) : [downgrade(event, entry.peer)];
        if (!allowed.length) continue;
        payloads.push(...allowed.map((answer) => seal(entry.session, answer)));
        out.set(entry.link, payloads);
      }
    }
    for (const [link, payloads] of out) link.send(payloads);
    return live.length;
  }

  watching(convId: string): Set<string> {
    return new Set(
      [...this.served].filter(([, entry]) => entry.phase === "live" && (entry.active || entry.foreground === convId)).map(([key]) => key),
    );
  }

  direct(): Set<string> {
    return new Set([...this.served].filter(([, entry]) => entry.link.path === "direct").map(([key]) => key));
  }

  browserRelayDown(link: Link): void {
    for (const [sid, value] of this.browserChallenges) if (value.entry.link === link) this.browserChallenges.delete(sid);
    for (const [key, entry] of this.served) if (entry.browser && entry.link === link) this.end(key);
  }

  relayGone(): void {
    for (const entry of this.served.values()) {
      if (entry.phase !== "live" || entry.link.path !== "relay") continue;
      entry.foreground = undefined;
      entry.active = undefined;
    }
  }
}
