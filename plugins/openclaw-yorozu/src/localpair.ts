// Local Mac pairing (#532, feature flag `local-pair`): a Mac on the Gateway's machine asks the loopback direct listener
// for `{"type":"local_pair"}` and gets the path of a 0600 file holding a pairing link; whoever can read this user's
// files can pair. Imports only node built-ins, so `node --test` runs it without OpenClaw.
import { randomBytes } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import type { Log } from "./hub.js";

/** The feature flag of the direct listener's `local_pair` message, both ways. Not a `peer_info` capability: it is
 * asked before any session, and a plugin without it refuses the message like any other unexpected one (4101). */
export const LOCAL_PAIR = "local-pair";
/** A code with less time left than this is not handed out again: the Mac needs the time to pair. */
export const MIN_LEFT_MS = 60_000;

export const localPairingPath = (stateDir: string): string => path.join(stateDir, "yorozu", "local-pairing");

/** The pairing link a local pair hands out. */
export type LocalCode = { link: string; secret: string; expiresAt: number };

/** Whether `code` may be handed out again: unexpired with a minute left, and its secret still pending. */
export const reusable = (code: LocalCode | null, pending: (secret: string) => boolean, now = Date.now()): code is LocalCode =>
  code !== null && code.expiresAt - now >= MIN_LEFT_MS && pending(code.secret);

/** Writes `contents` to `file` atomically: its directory 0700 and owned by this user, the file 0600 through a temp
 * file created exclusively beside it (`O_EXCL` never follows a symlink) and renamed over it (a rename replaces a
 * symlink, never writes through it). */
export async function writePrivateFile(file: string, contents: string): Promise<void> {
  const dir = path.dirname(file);
  await fs.mkdir(dir, { recursive: true, mode: 0o700 });
  const stat = await fs.lstat(dir);
  if (!stat.isDirectory() || (process.getuid && stat.uid !== process.getuid())) {
    throw new Error(`${dir} is not a directory of this user`);
  }
  if ((stat.mode & 0o777) !== 0o700) await fs.chmod(dir, 0o700);
  const temp = path.join(dir, `.${path.basename(file)}.${randomBytes(8).toString("hex")}`);
  const handle = await fs.open(temp, "wx", 0o600);
  try {
    await handle.writeFile(contents);
    await handle.sync();
  } finally {
    await handle.close();
  }
  try {
    await fs.rename(temp, file);
  } catch (error) {
    await fs.rm(temp, { force: true });
    throw error;
  }
}

export type LocalPairingOptions = {
  file: string;
  /** A new offline-style code: random token, 10-minute expiry, no relay mint request. */
  mint: () => Promise<LocalCode>;
  /** Whether a secret is still pending (unspent, unexpired). */
  pending: (secret: string) => boolean;
  log?: Log;
};

/** The local pairing file and its code: one at a time, deleted when its secret is spent, when it expires and on
 * close. */
export class LocalPairingFile {
  private code: LocalCode | null = null;
  private timer: NodeJS.Timeout | undefined;
  private queue: Promise<unknown> = Promise.resolve();
  private readonly opts: LocalPairingOptions;

  constructor(opts: LocalPairingOptions) {
    this.opts = opts;
  }

  /** Writes the file with a valid code, the current one while it is reusable, and returns its path. */
  ensure(now = Date.now()): Promise<string> {
    const next = this.queue.then(async () => {
      const old = this.code;
      const code = reusable(old, this.opts.pending, now) ? old : await this.opts.mint();
      if (code !== old) this.opts.log?.info("yorozu: local pairing code written for a Mac on this machine");
      this.code = code;
      await writePrivateFile(this.opts.file, `${code.link}\n`);
      clearTimeout(this.timer);
      this.timer = setTimeout(() => void this.drop(code.secret), Math.max(0, code.expiresAt - Date.now()));
      this.timer.unref();
      return this.opts.file;
    });
    this.queue = next.catch(() => {});
    return next;
  }

  /** A pending secret was spent: if it was the file's, the file goes. */
  spent(secret: string): void {
    if (this.code?.secret === secret) void this.drop(secret);
  }

  /** Deletes the file, whatever it holds: on shutdown, and at start for one an earlier process left behind. */
  close(): Promise<void> {
    return this.drop();
  }

  private drop(secret?: string): Promise<void> {
    const next = this.queue.then(async () => {
      if (secret !== undefined && this.code?.secret !== secret) return;
      this.code = null;
      clearTimeout(this.timer);
      this.timer = undefined;
      await fs.rm(this.opts.file, { force: true }).catch((error: unknown) =>
        this.opts.log?.warn(`yorozu: could not delete the local pairing file: ${String(error)}`));
    });
    this.queue = next.catch(() => {});
    return next;
  }
}
