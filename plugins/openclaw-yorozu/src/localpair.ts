import { randomBytes } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import type { Log } from "./hub.js";

export const LOCAL_PAIR = "local-pair";
export const MIN_LEFT_MS = 60_000;

export const localPairingPath = (stateDir: string): string => path.join(stateDir, "yorozu", "local-pairing");

export type LocalCode = { link: string; secret: string; expiresAt: number };

export const reusable = (code: LocalCode | null, pending: (secret: string) => boolean, now = Date.now()): code is LocalCode =>
  code !== null && code.expiresAt - now >= MIN_LEFT_MS && pending(code.secret);

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
  mint: () => Promise<LocalCode>;
  pending: (secret: string) => boolean;
  log?: Log;
};

export class LocalPairingFile {
  private code: LocalCode | null = null;
  private timer: NodeJS.Timeout | undefined;
  private queue: Promise<unknown> = Promise.resolve();
  private readonly opts: LocalPairingOptions;

  constructor(opts: LocalPairingOptions) {
    this.opts = opts;
  }

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

  spent(secret: string): void {
    if (this.code?.secret === secret) void this.drop(secret);
  }

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
