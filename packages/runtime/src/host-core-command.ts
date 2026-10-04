/** Leaf command resolution shared by the private kernel-lease compatibility bridge. */
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";

export function rustHostCommand(): string {
  if (process.env.YOROZU_HOST_CORE) return resolve(process.env.YOROZU_HOST_CORE);
  const name = `yorozu-host-core${process.platform === "win32" ? ".exe" : ""}`;
  const bundled = join(import.meta.dirname, "..", "..", name);
  return existsSync(bundled) ? bundled : join(import.meta.dirname, "..", "..", "host-core", "target", "debug", name);
}
