// Pairing codes (#532 step 5): the link the QR carries, the code minted while the relay is down, and the one-time
// secrets a device's hello proof must match on either path. Imports only node built-ins and the pure wire files, so
// `node --test` runs it without OpenClaw.
import { randomBytes, timingSafeEqual } from "node:crypto";
import type { DirectHints } from "./envelope.js";
import type { Log, Path } from "./hub.js";
import { b64u, helloProof } from "./wire.js";

/** An offline code's lifetime: the relay's tokens live as long. */
export const OFFLINE_MS = 10 * 60_000;
/** The QR stays readable: at most this many LAN and Tailscale addresses, and no MagicDNS name. */
export const QR_LAN = 4;
export const QR_TAILSCALE = 2;

export type Code = { token: string; expiresAt: number; directOnly: boolean };
type Mint = () => Promise<{ token: string; expiresAt: number }>;

/** A relay token, or, when the relay cannot mint one but the direct listener has hints, a random token the relay
 * doesn't know (a relay join with it fails as "unknown token"): that code pairs over the direct path only. */
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

/** The pairing link's query; with hints, `port`, up to 4 `lan=<addr>/<prefix>` and 2 `ts=<addr>`, comma-separated. */
export function pairingQuery(opts: {
  relayUrl: string; hostStatic: Uint8Array; token: string; room: string; secret: string; hints?: DirectHints;
}): string {
  const { hints } = opts;
  const lan = hints?.lan.slice(0, QR_LAN).map((i) => `${q(i.address)}/${i.prefix}`) ?? [];
  const ts = hints?.tailscale.slice(0, QR_TAILSCALE).map((i) => q(i.address)) ?? [];
  return `v=3&relay=${q(opts.relayUrl)}&key=${b64u(opts.hostStatic)}&token=${q(opts.token)}&room=${opts.room}&secret=${opts.secret}` +
    (hints ? `&port=${hints.port}` : "") + (lan.length ? `&lan=${lan.join(",")}` : "") + (ts.length ? `&ts=${ts.join(",")}` : "");
}

/** The one-time secrets of the pairing codes not yet used, each until its code expires. */
export class PendingPairings {
  private readonly secrets = new Map<string, number>();
  /** Told each secret a device spends, so the local pairing file holding it goes (#532 `local-pair`). */
  onSpend?: (secret: string) => void;

  /** Whether `secret` is pending: not spent, not expired. */
  has(secret: string, now = Date.now()): boolean {
    const until = this.secrets.get(secret);
    return until !== undefined && until >= now;
  }

  /** A new secret for a code that expires at `expiresAt`. */
  add(expiresAt: number, now = Date.now()): string {
    for (const [old, until] of this.secrets) if (until < now) this.secrets.delete(old);
    const secret = b64u(randomBytes(32));
    this.secrets.set(secret, expiresAt);
    return secret;
  }

  /** Whether `proof` matches an unexpired secret; that secret is spent, so a second use is refused. */
  spend(proof: string | undefined, staticPub: string, signingPub: string, now = Date.now()): boolean {
    if (!proof) return false;
    const given = Buffer.from(proof, "utf8");
    for (const [secret, until] of this.secrets) {
      if (until >= now && sameBytes(Buffer.from(helloProof(secret, staticPub, signingPub), "utf8"), given)) {
        this.secrets.delete(secret);
        this.onSpend?.(secret);
        return true;
      }
    }
    return false;
  }
}

/** Constant-time equality; unequal lengths never match. */
const sameBytes = (a: Buffer, b: Buffer) => a.length === b.length && timingSafeEqual(a, b);

/** The hub's `pair`: stores a device whose proof spends a pending secret. After a pairing over the direct path the
 * relay gets the allowlist at once if it is connected, else on its next `registered`. */
export function pairer(opts: {
  pending: PendingPairings;
  /** Stores the device; the keys of the devices it evicted. */
  put: (device: { signingPub: string; staticPub: string; pairedAt: number }) => Promise<string[]>;
  forget: (deviceKeys: string[]) => void;
  allowlist: () => Promise<string[]>;
  relaySend: () => ((raw: string) => void) | null;
  log?: Log;
}): (proof: string | undefined, staticPub: string, deviceKey: string, now: number, path: Path) => Promise<boolean> {
  return async (proof, staticPub, deviceKey, now, path) => {
    if (!opts.pending.spend(proof, staticPub, deviceKey, now)) return false;
    const evicted = await opts.put({ signingPub: deviceKey, staticPub, pairedAt: now });
    opts.forget(evicted);
    opts.log?.info(`yorozu: device paired${path === "direct" ? " over direct" : ""}${evicted.length ? " (the oldest made way)" : ""}`);
    const send = path === "direct" ? opts.relaySend() : null;
    if (send) send(JSON.stringify({ type: "devices", devices: await opts.allowlist() }));
    return true;
  };
}
