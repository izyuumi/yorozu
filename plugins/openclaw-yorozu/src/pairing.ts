import { randomBytes, timingSafeEqual } from "node:crypto";
import type { DirectHints } from "./envelope.js";
import type { Log, Path } from "./hub.js";
import { b64u, helloProof } from "./wire.js";

export const OFFLINE_MS = 10 * 60_000;
export const QR_LAN = 4;
export const QR_TAILSCALE = 2;

export type Code = { token: string; expiresAt: number; directOnly: boolean };
type Mint = () => Promise<{ token: string; expiresAt: number }>;

export async function mintCode(mint: Mint | null, hints: DirectHints | undefined, log?: Log, now = Date.now()): Promise<Code> {
  let failure: unknown;
  if (mint) {
    try {
      return { ...(await mint()), directOnly: false };
    } catch (error) {
      failure = error;
    }
  }
  if (!hints) {
    if (failure) throw failure;
    throw new Error("the yorozu channel reaches neither its relay nor its direct listener; check `openclaw channels status`");
  }
  log?.info("yorozu: relay unreachable; pairing code works over the direct path only");
  return { token: b64u(randomBytes(32)), expiresAt: now + OFFLINE_MS, directOnly: true };
}

const q = (value: string) => encodeURIComponent(value).replace(/%3A/gi, ":").replace(/%2F/gi, "/");

export function pairingQuery(opts: {
  relayUrl: string; hostStatic: Uint8Array; token: string; room: string; secret: string; hints?: DirectHints; browser?: boolean;
}): string {
  const { hints } = opts;
  const lan = hints?.lan.slice(0, QR_LAN).map((i) => `${q(i.address)}/${i.prefix}`) ?? [];
  const ts = hints?.tailscale.slice(0, QR_TAILSCALE).map((i) => q(i.address)) ?? [];
  return `v=${opts.browser ? 4 : 3}&relay=${q(opts.relayUrl)}&key=${b64u(opts.hostStatic)}&token=${q(opts.token)}&room=${opts.room}&secret=${opts.secret}` +
    (hints ? `&port=${hints.port}` : "") + (lan.length ? `&lan=${lan.join(",")}` : "") + (ts.length ? `&ts=${ts.join(",")}` : "");
}

export class PendingPairings {
  private readonly secrets = new Map<string, { expiresAt: number; browser: boolean }>();
  onSpend?: (secret: string) => void;

  has(secret: string, now = Date.now()): boolean {
    const until = this.secrets.get(secret);
    return until !== undefined && until.expiresAt >= now;
  }

  add(expiresAt: number, now = Date.now(), browser = false): string {
    for (const [old, until] of this.secrets) if (until.expiresAt < now) this.secrets.delete(old);
    const secret = b64u(randomBytes(32));
    this.secrets.set(secret, { expiresAt, browser });
    return secret;
  }

  spend(proof: string | undefined, staticPub: string, signingPub: string, now = Date.now(), browser = false): boolean {
    return this.match(proof, staticPub, signingPub, now, browser, true);
  }

  acceptsBrowser(proof: string | undefined, staticPub: string, signingPub: string, now = Date.now()): boolean {
    return this.match(proof, staticPub, signingPub, now, true, false);
  }

  private match(proof: string | undefined, staticPub: string, signingPub: string, now: number, browser: boolean, spend: boolean): boolean {
    if (!proof) return false;
    const given = Buffer.from(proof, "utf8");
    for (const [secret, until] of this.secrets) {
      if (until.browser === browser && until.expiresAt >= now && sameBytes(Buffer.from(helloProof(secret, staticPub, signingPub), "utf8"), given)) {
        if (spend) {
          this.secrets.delete(secret);
          this.onSpend?.(secret);
        }
        return true;
      }
    }
    return false;
  }
}

const sameBytes = (a: Buffer, b: Buffer) => a.length === b.length && timingSafeEqual(a, b);

type AnnounceState = { phase: "idle" } | { phase: "sending"; again: boolean };
type AnnounceOptions = {
  allowlist: () => Promise<string[]>;
  relaySend: () => ((raw: string) => void) | null;
  log?: Log;
};

export class Announcer {
  private state: AnnounceState = { phase: "idle" };
  private settled: Promise<void> = Promise.resolve();
  private readonly opts: AnnounceOptions;

  constructor(opts: AnnounceOptions) {
    this.opts = opts;
  }

  announce(): void {
    if (this.state.phase === "sending") {
      this.state.again = true;
      return;
    }
    const state: Extract<AnnounceState, { phase: "sending" }> = { phase: "sending", again: false };
    this.state = state;
    this.settled = this.run(state);
  }

  idle(): Promise<void> {
    return this.settled;
  }

  private async run(state: Extract<AnnounceState, { phase: "sending" }>): Promise<void> {
    do {
      state.again = false;
      try {
        const send = this.opts.relaySend();
        if (send) {
          const devices = await this.opts.allowlist();
          if (send === this.opts.relaySend()) send(JSON.stringify({ type: "devices", devices }));
        }
      } catch (error) {
        this.opts.log?.warn(`yorozu: allowlist announce failed: ${String(error)}`);
      }
    } while (state.again);
    this.state = { phase: "idle" };
  }
}

export function pairer(opts: {
  pending: PendingPairings;
  put: (device: { signingPub: string; staticPub: string; pairedAt: number }) => Promise<string[]>;
  forget: (deviceKeys: string[]) => void;
  allowlist: () => Promise<string[]>;
  relaySend: () => ((raw: string) => void) | null;
  log?: Log;
}, announcer = new Announcer(opts)): (proof: string | undefined, staticPub: string, deviceKey: string, now: number, path: Path) => Promise<boolean> {
  return async (proof, staticPub, deviceKey, now, path) => {
    if (!opts.pending.spend(proof, staticPub, deviceKey, now)) return false;
    const evicted = await opts.put({ signingPub: deviceKey, staticPub, pairedAt: now });
    opts.forget(evicted);
    opts.log?.info(`yorozu: device paired${path === "direct" ? " over direct" : ""}${evicted.length ? " (the oldest made way)" : ""}`);
    announcer.announce();
    return true;
  };
}
