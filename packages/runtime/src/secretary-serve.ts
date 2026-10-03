/** Production entry: legacy transport/storage, additive Rust secretary admission. */
import { serve, type ServeOptions, type Sidecar } from "./serve.js";
import { stateDir } from "./memory.js";
import { claudeCodeRunner } from "./native.js";
import { codexNativeRunner } from "./codex-native.js";
import { secretaryRunner } from "./secretary-runner.js";

export function serveSecretary(options: ServeOptions = {}): Sidecar {
  const dir = options.stateDir ?? stateDir();
  const runners = options.nativeRunners ?? { "claude-code": claudeCodeRunner(), codex: codexNativeRunner() };
  if (!runners.codex) throw new Error("The secretary requires the Codex adapter");
  return serve({ ...options, stateDir: dir, nativeRunners: { ...runners, codex: secretaryRunner(dir, runners.codex) } });
}

if (import.meta.main) {
  const sidecar = serveSecretary();
  process.once("SIGTERM", () => {
    const deadline = setTimeout(() => process.exit(143), 15000);
    deadline.unref();
    void sidecar.close().then(() => { clearTimeout(deadline); process.exit(0); }, () => process.exit(143));
  });
  if (!process.stdin.isTTY) {
    process.stdin.on("data", (chunk) => { if (chunk.toString().includes("MINT")) sidecar.mint(); });
    process.stdin.on("error", () => {});
  }
}
