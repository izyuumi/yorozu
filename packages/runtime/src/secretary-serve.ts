/** Production entry: legacy transport/storage, additive Rust secretary admission. */
import * as runtime from "./serve.js";
import type { ServeOptions, Sidecar } from "./serve.js";
import { stateDir } from "./memory.js";
import type { NativeAgentRunner, NativeTurn } from "./native.js";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { constants } from "node:os";
import { secretaryCoordinator, type SecretaryCoordinatorHost } from "./secretary-coordinator.js";
import { harnessConfiguration, SecretaryHarness } from "./harness-runner.js";
import { PersonAgentHost, type PersonAgentPlatform } from "./person-agent-host.js";
import { packagedResourcesFromEntry } from "./packaged-agent-runtime.js";
import { createNativeAccountHost, type NativeAccountSender } from "./native-account-host.js";
import { createMinimalWorkerPlatform, type MinimalWorkerSelection } from "./worker-platform.js";

export interface SecretaryServeOptions extends ServeOptions {
  /** Explicit trusted host selection; never sourced from relay/device settings or ambient env. */
  minimalWorkers?: MinimalWorkerSelection;
  personAgentPlatform?: PersonAgentPlatform;
  nativeAccountHost?: ReturnType<typeof createNativeAccountHost>;
}

function requireProductionRuntime(): void {
  if (!("secretaryRunnerDecorator" in runtime) || runtime.secretaryRunnerDecorator !== true) {
    throw new Error("The production runtime is missing its secretary decorator patch");
  }
}

export function serveSecretary(options: SecretaryServeOptions = {}): Sidecar {
  requireProductionRuntime();
  const dir = options.stateDir ?? stateDir();
  let decorated = false;
  let unavailable: string | undefined;
  let coordinator: ReturnType<typeof secretaryCoordinator>;
  let harness: SecretaryHarness | undefined;
  let harnessHost: SecretaryCoordinatorHost | undefined;
  const accounts = options.nativeAccountHost;
  if (options.minimalWorkers && (accounts || options.personAgentPlatform)) throw new Error("Select one worker platform owner");
  const platform = options.minimalWorkers ? createMinimalWorkerPlatform(options.minimalWorkers) : accounts?.platform ?? options.personAgentPlatform;
  if (accounts && options.personAgentPlatform && options.personAgentPlatform !== accounts.platform) throw new Error("Native account platform owner mismatch");
  const people = platform ? new PersonAgentHost(dir, platform) : undefined;
  if (people && accounts) accounts.bindPeople(people);
  const configuration = people?.owns("yorozu-secretary-v1") || packagedResourcesFromEntry(new URL(import.meta.url)) ? undefined : harnessConfiguration(dir);
  const legacySecretary = !configuration && !people?.owns("yorozu-secretary-v1");
  // A local variable also type-checks against the unpatched development ServeOptions.
  const decoratedOptions = { ...options, stateDir: dir,
    secretaryUnavailable: (id?: string) => id && people?.owns(id) ? undefined : unavailable,
    secretaryCoordinator: legacySecretary,
    secretaryHarness: !!configuration || !!people,
    secretaryHarnessOwns: people ? (id: string) => people.owns(id) || !!configuration && (id === "yorozu-secretary-v1" || !!harness?.owns(id)) : undefined,
    secretaryOwnsConversation: (id: string) => people?.owns(id) ?? false,
    secretaryOwnsTask: (id: string) => people?.ownsTask(id) || (configuration ? id !== "yorozu-secretary-v1" && (harness?.owns(id) ?? false) : coordinator?.owns(id) ?? false),
    secretaryTask: (id: string) => coordinator?.task(id),
    secretaryThreadSummary: (id: string) => people?.summary(id) ?? harness?.summary(id),
    secretaryThreadWorkspace: (id: string) => people?.workspace(id),
    secretaryTaskStop: (event: Parameters<SecretaryHarness["taskStop"]>[0]) => people?.ownsTask(event.threadId)
      ? people.runtime.taskStop(event) : harness?.taskStop(event) ?? Promise.resolve(false),
    personAgentRegistry: people ? () => people.registry() : undefined,
    personAgentControl: people ? (event: Parameters<PersonAgentHost["control"]>[0]) => people.control(event) : undefined,
    personAgentCreate: people ? (event: Parameters<PersonAgentHost["create"]>[0]) => people.create(event) : undefined,
    harnessAction: people ? (event: Parameters<PersonAgentHost["action"]>[0]) => people.action(event) : undefined,
    siwcAccountStatus: accounts?.provisioned ? () => accounts.status() : undefined,
    siwcAccountControl: accounts?.provisioned ? (event: Parameters<NonNullable<typeof accounts>["control"]>[0], sender: NativeAccountSender) => accounts.control(event, sender) : undefined,
    secretaryObserve: (event: Parameters<ReturnType<typeof secretaryCoordinator>["observe"]>[0]) => coordinator?.observe(event),
    decorateNativeRunners: (runners: Record<string, NativeAgentRunner>, host: SecretaryCoordinatorHost) => {
      if (configuration) {
        try { harness = new SecretaryHarness(dir, configuration); }
        catch (error) { unavailable = `Harness unavailable: ${error instanceof Error ? error.message : String(error)}`; }
      }
      if (people) {
        if (legacySecretary) {
          if (!runners.codex) throw new Error("The existing secretary requires the Codex adapter");
          coordinator = secretaryCoordinator(dir, runners.codex, reason => { unavailable = reason; });
          coordinator.bind(host);
        }
        harnessHost = host; decorated = true;
        return { ...runners, harness: people.runner, codex: { ...runners.codex,
          run: (turn: NativeTurn) => people.owns(turn.threadId) ? people.runner.run(turn)
            : configuration && (turn.threadId === "yorozu-secretary-v1" || harness?.owns(turn.threadId))
              ? harness?.runner.run(turn) ?? Promise.resolve({ text: unavailable ?? "Harness unavailable", failed: true })
            : (legacySecretary && (turn.threadId === "yorozu-secretary-v1" || coordinator?.owns(turn.threadId))
              ? coordinator?.runner : runners.codex)?.run(turn) ?? Promise.resolve({ text: "Codex unavailable", failed: true }) } };
      }
      if (configuration) {
        harnessHost = host;
        decorated = true;
        const selected: NativeAgentRunner = harness?.runner ?? {
          descriptor: { id: "harness", label: "Yorozu", description: "Selected agent harness", needsFolder: true },
          run: async () => ({ text: unavailable ?? "Harness unavailable", failed: true }),
        };
        // Old main history keeps its immutable agent/session metadata. Only its execution
        // route changes; ordinary Codex conversations keep their existing runner.
        return { ...runners, harness: selected, codex: { ...runners.codex, run: (turn: NativeTurn) =>
          turn.threadId === "yorozu-secretary-v1" || harness?.owns(turn.threadId)
            ? selected.run(turn) : runners.codex?.run(turn) ?? Promise.resolve({ text: "Codex unavailable", failed: true }) } };
      }
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
  if (people && harnessHost) {
    const host = harnessHost;
    people.bind({ emit: host.emit, changed: () => host.publishThreads?.() });
    accounts?.bindChanged(() => host.publishThreads?.());
  }
  if (harness && harnessHost) {
    const host = harnessHost;
    harness.bind({ emit: host.emit, changed: () => host.publishThreads?.() });
  }
  if (legacySecretary) coordinator!.reconcile();
  return { ...sidecar, async close() {
    try { await accounts?.close(); await people?.close(); await harness?.close(); } finally { await sidecar.close(); }
  } };
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
  const resources = packagedResourcesFromEntry(new URL(import.meta.url)), dir = stateDir();
  const accounts = resources ? createNativeAccountHost(resources, dir) : undefined;
  const sidecar = serveSecretary({ stateDir: dir, nativeAccountHost: accounts });
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
