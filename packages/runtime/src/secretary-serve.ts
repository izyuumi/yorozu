/** Production entry: legacy transport/storage, additive Rust secretary admission. */
import * as runtime from "./serve.js";
import type { ServeOptions, Sidecar } from "./serve.js";
import { stateDir } from "./memory.js";
import type { NativeAgentRunner } from "./native.js";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { constants } from "node:os";
import { secretaryCoordinator, type SecretaryCoordinatorHost } from "./secretary-coordinator.js";

function requireProductionRuntime(): void {
  if (!("secretaryRunnerDecorator" in runtime) || runtime.secretaryRunnerDecorator !== true) {
    throw new Error("The production runtime is missing its secretary decorator patch");
  }
}

export function serveSecretary(options: ServeOptions = {}): Sidecar {
  requireProductionRuntime();
  const dir = options.stateDir ?? stateDir();
  let decorated = false;
  let unavailable: string | undefined;
  let coordinator: ReturnType<typeof secretaryCoordinator>;
  // A local variable also type-checks against the unpatched development ServeOptions.
  const decoratedOptions = { ...options, stateDir: dir,
    secretaryUnavailable: () => unavailable,
    secretaryCoordinator: true,
    secretaryOwnsTask: (id: string) => coordinator?.owns(id) ?? false,
    secretaryTask: (id: string) => coordinator?.task(id),
    secretaryObserve: (event: Parameters<ReturnType<typeof secretaryCoordinator>["observe"]>[0]) => coordinator?.observe(event),
    decorateNativeRunners: (runners: Record<string, NativeAgentRunner>, host: SecretaryCoordinatorHost) => {
      if (!runners.codex) throw new Error("The secretary requires the Codex adapter");
      coordinator = secretaryCoordinator(dir, runners.codex, (reason) => {
        unavailable = reason;
        (options.log ?? ((line: string) => process.stdout.write(`${line}\n`)))(`STATE secretary-unavailable ${reason}`);
      });
      coordinator.bind(host);
      decorated = true;
      return { ...runners, codex: coordinator.runner };
    },
  };
  const sidecar = runtime.serve(decoratedOptions);
  if (!decorated) {
    void sidecar.close().catch(() => {});
    throw new Error("The production runtime is missing its secretary decorator patch");
  }
  coordinator!.reconcile();
  return sidecar;
}

if (import.meta.main && process.argv.length > 2) {
  requireProductionRuntime();
  // Preserve the original CLI, including settings commands, without starting another service.
  const child = spawn(process.execPath, [fileURLToPath(new URL("./serve.js", import.meta.url)), ...process.argv.slice(2)], { stdio: "inherit" });
  process.once("SIGTERM", () => child.kill("SIGTERM"));
  process.once("SIGINT", () => child.kill("SIGINT"));
  child.once("error", () => process.exit(1));
  child.once("exit", (code, signal) => process.exit(code ?? (signal ? 128 + constants.signals[signal] : 1)));
} else if (import.meta.main) {
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
