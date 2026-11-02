/** The relay deleted this host's room after 30 days without a connection from any member. */
export const CLOSE_EXPIRED = 4010;

export const ROOM_EXPIRED = "yorozu: relay pairing expired after 30 days without a connection; pair your devices again";

const DAY_MS = 24 * 60 * 60_000;
/** The relay's limits: a device idle this long is dropped, a room idle this long is deleted. */
export const DEVICE_IDLE_MS = 180 * DAY_MS;
export const ROOM_IDLE_MS = 30 * DAY_MS;
/** A device is reported as `seen` at most once in this time. */
export const SEEN_REPORT_MS = DAY_MS;
/** The relay's cap on one message's device list. */
const MAX_DEVICES = 16;

/**
 * Devices that connected over the direct path, which the relay never sees: the host reports them as `seen`, so the
 * relay's idle clocks mean "no connection by any path". In memory only.
 */
export class DirectSeen {
  private readonly at = new Map<string, number>();
  private readonly reported = new Map<string, number>();

  mark(key: string, now: number): void {
    this.at.set(key, now);
  }

  /** Keys seen since they were last reported, and not reported in the last 24 hours. */
  due(now: number): string[] {
    return [...this.at].filter(([key, at]) => {
      const last = this.reported.get(key);
      return last === undefined || (at > last && now - last >= SEEN_REPORT_MS);
    }).map(([key]) => key);
  }

  /** The device is no longer paired. */
  drop(key: string): void {
    this.at.delete(key);
    this.reported.delete(key);
  }

  sent(keys: readonly string[], now: number): void {
    for (const key of keys) this.reported.set(key, now);
  }

  recent(key: string, now: number, windowMs: number): boolean {
    const at = this.at.get(key);
    return at !== undefined && now - at < windowMs;
  }
}

/** Sends `seen` for `keys` (and whatever else is due), in messages the relay accepts. */
export function reportSeen(seen: DirectSeen, send: (raw: string) => void, now: number, keys: readonly string[] = []): void {
  const all = [...new Set([...keys, ...seen.due(now)])];
  for (let i = 0; i < all.length; i += MAX_DEVICES) {
    send(JSON.stringify({ type: "seen", devices: all.slice(i, i + MAX_DEVICES) }));
  }
  seen.sent(all, now);
}

type Store = {
  list: () => Promise<{ signingPub: string; name?: string }[]>;
  remove: (signingPub: string) => Promise<unknown>;
};

type Options = {
  store: Store;
  /** Ends the devices' sessions without revoking them at the relay, which already forgot them. */
  forget: (deviceKeys: string[]) => void;
  seen: DirectSeen;
  now?: () => number;
  log?: { warn: (message: string) => void };
};

/**
 * Drops the devices the relay expired after 180 idle days (`registered.expired`, `expired.devices`), apart from those
 * seen over direct in that time, which are reported as `seen` so the relay lets the announce re-add them; then
 * announces the allowlist.
 */
export async function announceDevices(expired: unknown, send: (raw: string) => void, opts: Options): Promise<void> {
  const now = (opts.now ?? Date.now)();
  const keys = new Set(Array.isArray(expired) ? expired.filter((key) => typeof key === "string") : []);
  const listed = (await opts.store.list()).filter((device) => keys.has(device.signingPub));
  const kept = listed.filter((device) => opts.seen.recent(device.signingPub, now, DEVICE_IDLE_MS));
  const gone = listed.filter((device) => !kept.includes(device));
  for (const device of gone) {
    await opts.store.remove(device.signingPub);
    opts.seen.drop(device.signingPub);
    const label = device.name ?? device.signingPub.slice(0, 8);
    opts.log?.warn(`yorozu: device ${label} pairing expired after 180 days without connecting; pair it again`);
  }
  if (gone.length) opts.forget(gone.map((device) => device.signingPub));
  reportSeen(opts.seen, send, now, kept.map((device) => device.signingPub));
  send(JSON.stringify({ type: "devices", devices: (await opts.store.list()).map((device) => device.signingPub) }));
}

/**
 * The relay closed with CLOSE_EXPIRED: every pairing is over, apart from devices seen over direct in the last 30 days,
 * which the next announce adds to the new room. Returns the keys removed.
 */
export async function expirePairing(opts: Options): Promise<string[]> {
  const now = (opts.now ?? Date.now)();
  const keys = (await opts.store.list())
    .map((device) => device.signingPub)
    .filter((key) => !opts.seen.recent(key, now, ROOM_IDLE_MS));
  for (const key of keys) {
    await opts.store.remove(key);
    opts.seen.drop(key);
  }
  if (keys.length) {
    opts.forget(keys);
    opts.log?.warn(ROOM_EXPIRED);
  }
  return keys;
}
