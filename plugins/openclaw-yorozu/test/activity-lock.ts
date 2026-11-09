import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { randomUUID } from "node:crypto";
import { open, readFile, unlink } from "node:fs/promises";

// Only a test double: stale-owner recovery is exercised with the SDK in integration tests.
export async function testFileLock(file: string, _options: unknown) {
  const lockPath = `${file}.lock`;
  const bytes = JSON.stringify({ pid: process.pid, starttime: 1, instance: randomUUID() });
  let handle;
  try { handle = await open(lockPath, "wx", 0o600); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") {
      throw Object.assign(new Error("test lock contended"), { code: "file_lock_timeout" });
    }
    throw error;
  }
  try { await handle.writeFile(bytes); } finally { await handle.close(); }
  return { async release() {
    try { if (await readFile(lockPath, "utf8") === bytes) await unlink(lockPath); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
  } };
}

registerHooks({ resolve(specifier, context, next) {
  if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
    const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
    if (existsSync(ts)) return next(ts.href, context);
  }
  return next(specifier, context);
} });
