/** Host-only pinned code + fresh broker bootstrap. No auth discovery, install, or fallback. */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { promises as sealedFs, constants as sealedConstants, closeSync, constants, existsSync, fstatSync, fsyncSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve, isAbsolute } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { PersonAgentStore, type PersonAgent } from "./agent-store.js";
import { pathWithin, safeAgentPath, validAgentId, type EffectiveAgentScope } from "./agent-scope.js";
import { acquireHostListener, releaseHostListener, type HostListenerLease } from "./agent-listener.js";
import type { PersonAgentExecution, PersonAgentRuntimeFactory } from "./person-agent-runtime.js";

/** Independent content pin for the reviewed f97608f source export, including its
 * sealed .git metadata. Not a manifest-supplied digest or an integrity bypass.
 * Rows use package-hermes-runtime.py fields, sorted by full UTF-8 path
 * (not Python Path component ordering), with mode/path/sha256 key order.
 * Source is immutable code under the host-selected signed bundle, never writable
 * agent state. Both host and child rehash it; no Git/toolchain is invoked here.
 */
export const SEALED_HERMES_SOURCE_SHA256 = "bfee32553ccf2291cbd300b1fceed350487578f414a548b3bb7c5138cd4d0145";
export async function verifySealedHermesSource(source: string): Promise<void> {
  const bad = () => new Error("Sealed Hermes source integrity check failed");
  if (!isAbsolute(source) || resolve(source) !== source || await sealedFs.realpath(source) !== source) throw bad();
  const rows: { mode: number; path: string; sha256: string }[] = [];
  let bytes = 0, visited = 0;
  async function walk(directory: string): Promise<void> {
    const stat = await sealedFs.lstat(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.mode & 0o022) throw bad();
    for (const name of await sealedFs.readdir(directory)) {
      if (++visited > 65536) throw bad();
      const path = join(directory, name), s = await sealedFs.lstat(path);
      if (s.isDirectory()) { await walk(path); continue; }
      // This sealed export contains no links, including anywhere in .git.
      if (!s.isFile() || s.isSymbolicLink() || s.nlink !== 1 || s.mode & 0o022 || s.size > 256 * 1024 * 1024 || (bytes += s.size) > 2 * 1024 * 1024 * 1024) throw bad();
      const file = await sealedFs.open(path, sealedConstants.O_RDONLY | sealedConstants.O_NOFOLLOW | sealedConstants.O_NONBLOCK);
      try {
        const opened = await file.stat();
        if (!opened.isFile() || opened.nlink !== 1 || opened.dev !== s.dev || opened.ino !== s.ino || opened.size !== s.size || opened.mode !== s.mode) throw bad();
        const digest = createHash("sha256"); let read = 0;
        for await (const chunk of file.createReadStream({ autoClose: false })) {
          if ((read += chunk.length) > s.size) throw bad();
          digest.update(chunk);
        }
        if (read !== s.size) throw bad();
        rows.push({ mode: s.mode & 0o111 ? 493 : 420, path: "source/" + path.slice(source.length + 1), sha256: digest.digest("hex") });
      } finally { await file.close(); }
    }
  }
  await walk(source);
  rows.sort((a, b) => Buffer.compare(Buffer.from(a.path), Buffer.from(b.path)));
  if (createHash("sha256").update(JSON.stringify(rows)).digest("hex") !== SEALED_HERMES_SOURCE_SHA256) throw bad();
}

export const HERMES_RUNTIME_PIN = Object.freeze({ version: "0.21.5", sourceSha: "f97608f178d1ffeca59860195ab7da295f7c8e5f" });
/** Independently reviewed corrected native candidate (DEVELOPMENT): exact derived
 * commit and the full official-upstream-to-candidate binary diff digest. Repinned
 * coherently with the adapter manifest/literal-migration pins and the sealed loader. */
export const OPENCLAW_RUNTIME_PIN = Object.freeze({ version: "2026.9.8", sourceSha: "f04797ef4d24f3da0f9df74acd58ab773ab5f11e",
  upstreamSha: "fc23bc864e4553c2d215e479eeec47b67a0bf943", patchSha256: "601c2eea193de989977a122a98bda8653910848092f7c4937195e40bf63ebc4e" });
/** The only OpenClaw resource scopes with an integrated native proof: chat only, or
 * uniform host-owned memory. Native file/terminal/web/browser tools stay disabled. */
export const OPENCLAW_SUPPORTED_TOOLS: readonly string[] = Object.freeze(["memory"]);
export interface CuratedNodeRuntime { executable: string; version: "26.10.0"; libraryRoots?: string[] }
export interface CuratedPythonRuntime {
  /** May be the final interpreter link in the explicitly selected virtual environment. */
  executable: string; canonicalExecutable: string; version: string; libraryRoots: string[]; venvRoot?: string;
}
/** sealed-inventory-v1 selects another mandatory verifier, never skips integrity. */
export interface CuratedHermesRuntime { version: "0.21.5"; sourceSha: typeof HERMES_RUNTIME_PIN.sourceSha; source: string; adapter: string; sourceIntegrity?: "sealed-inventory-v1"; python: CuratedPythonRuntime }
/** sealed-inventory-v1 marks a sealed-loader-verified input; the ordinary Git
 * identity/full-diff checks still run against its minimal detached metadata. */
export interface CuratedOpenClawRuntime {
  version: "2026.9.8"; sourceSha: typeof OPENCLAW_RUNTIME_PIN.sourceSha; source: string; adapter: string; sourceIntegrity?: "sealed-inventory-v1";
}
/** Minted/selected by trusted host code, never a catalog, environment or client record.
 * The broker must bind numeric loopback, authenticate this fresh bearer, and enforce
 * its own per-execution authority/budget. This record alone does not prove that service.
 */
export interface SelectedAgentBroker {
  kind: "host-inference-broker-v1"; agentId: string; executionId: string; accountBindingId?: string;
  host: "127.0.0.1"; port: number; model: string; bearer: string;
}
export interface CuratedAgentRuntimeConfiguration {
  node: CuratedNodeRuntime; hermes: CuratedHermesRuntime; openclaw?: CuratedOpenClawRuntime;
  selectBroker(agent: Readonly<PersonAgent>, execution: Readonly<PersonAgentExecution>, scope: EffectiveAgentScope): SelectedAgentBroker | undefined | Promise<SelectedAgentBroker | undefined>;
  /** Curated tool executables, granted as code reads only when terminal is selected.
   * The OS compiler currently does not implement a command allowlist.
   */
  terminalBinaries?: string[];
}
export class CuratedRuntimeUnavailable extends Error {
  readonly status = "unsupported";
  constructor(readonly capability: "auth" | "runtime" | "scope", message: string) { super(message); this.name = "CuratedRuntimeUnavailable"; }
}
const overlaps = (a: string, b: string): boolean => pathWithin(a, b) || pathWithin(b, a);
function fields(value: unknown, allowed: string[]): asserts value is Record<string, any> {
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).some(k => !allowed.includes(k)))
    throw new CuratedRuntimeUnavailable("runtime", "Unsupported trusted runtime fields");
}
function canonical(path: string, directory = false): string {
  try {
    const out = safeAgentPath(path, true), s = lstatSync(out);
    if (directory ? !s.isDirectory() : !s.isFile() || s.nlink !== 1) throw new Error();
    return out;
  } catch { throw new CuratedRuntimeUnavailable("runtime", "A selected code path is not an intact canonical file or directory"); }
}
const runInspection = promisify(execFile);
async function inspect(command: string, args: string[], limit = 4096, privateIndex?: string): Promise<string> {
  try {
    return (await runInspection(command, args, { env: { PATH: "/usr/bin:/bin", GIT_OPTIONAL_LOCKS: "0", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null", NODE_DISABLE_COMPILE_CACHE: "1",
      ...(privateIndex ? { GIT_INDEX_FILE: privateIndex } : {}) },
      timeout: 10_000, maxBuffer: limit, encoding: "utf8" })).stdout.trim();
  } catch { throw new CuratedRuntimeUnavailable("runtime", "Selected pinned code or interpreter validation failed; no repair or fallback was attempted"); }
}
async function pinnedSource(source: string, sha: string, scratch: string): Promise<string[]> {
  try { safeAgentPath(join(source, ".git"), true); } catch { throw new CuratedRuntimeUnavailable("runtime", "Selected Git metadata must not be a symlink"); }
  if (await inspect("/usr/bin/git", ["-C", source, "rev-parse", "HEAD"]) !== sha) throw new CuratedRuntimeUnavailable("runtime", "Selected source does not match its approved commit");
  const verification = mkdtempSync(join(scratch, ".source-verification-")), index = join(verification, "index");
  try {
    // Git may refresh an index even with optional locks disabled. Build a fresh
    // private index from the pinned tree, without inherited assume-unchanged flags.
    const prefix = ["-C", source, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"];
    await inspect("/usr/bin/git", [...prefix, "read-tree", sha], 4096, index);
    await inspect("/usr/bin/git", [...prefix, "diff", "--no-ext-diff", "--no-textconv", "--quiet", "HEAD", "--"], 4096, index);
  } finally { rmSync(verification, { recursive: true, force: true }); }
  const metadata = canonical(await inspect("/usr/bin/git", ["-C", source, "rev-parse", "--path-format=absolute", "--git-common-dir"]), true);
  return [source, ...(pathWithin(source, metadata) ? [] : [metadata])];
}
function roots(values: unknown): string[] {
  if (!Array.isArray(values) || values.length > 16) throw new CuratedRuntimeUnavailable("runtime", "Curated code roots exceed their budget");
  return [...new Set(values.map(v => {
    if (typeof v !== "string" || ["/", "/Users", "/private", "/tmp", "/var"].includes(v)) throw new CuratedRuntimeUnavailable("runtime", "Broad code roots are unsupported");
    try { const path = safeAgentPath(v, true); return lstatSync(path).isDirectory() ? canonical(path, true) : canonical(path); }
    catch { throw new CuratedRuntimeUnavailable("runtime", "A curated code root is unavailable"); }
  }))];
}
function readJson(path: string, limit = 4096, privateFile = true): any | undefined {
  safeAgentPath(path); let fd: number;
  try { fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw new CuratedRuntimeUnavailable("runtime", "Private bootstrap is unavailable"); }
  try {
    const stat = fstatSync(fd); if (!stat.isFile() || stat.nlink !== 1 || stat.size > limit || privateFile && stat.mode & 0o077) throw new Error();
    return JSON.parse(readFileSync(fd, "utf8"));
  } catch { throw new CuratedRuntimeUnavailable("runtime", "Private bootstrap is invalid; no profile was adopted"); }
  finally { closeSync(fd); }
}
function privateJson(path: string, data: unknown): void {
  safeAgentPath(path); const encoded = JSON.stringify(data) + "\n";
  if (Buffer.byteLength(encoded) > 4096) throw new CuratedRuntimeUnavailable("runtime", "Private broker bootstrap exceeds its budget");
  if (existsSync(path)) { const s = lstatSync(path); if (!s.isFile() || s.isSymbolicLink() || s.nlink !== 1 || s.mode & 0o077) throw new CuratedRuntimeUnavailable("runtime", "Unsafe private bootstrap destination"); }
  const temp = path + "." + randomUUID(), fd = openSync(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try { writeFileSync(fd, encoded); fsyncSync(fd); } finally { closeSync(fd); }
  renameSync(temp, path); const dir = openSync(dirname(path), constants.O_RDONLY | constants.O_NOFOLLOW);
  try { fsyncSync(dir); } finally { closeSync(dir); }
}

/** Returns only the interface PersonAgentRuntime can call. No environment resolver exists. */
export function createCuratedAgentRuntimeFactory(store: PersonAgentStore, supplied: CuratedAgentRuntimeConfiguration): PersonAgentRuntimeFactory {
  fields(supplied, ["node", "hermes", "openclaw", "selectBroker", "terminalBinaries"]);
  fields(supplied.node, ["executable", "version", "libraryRoots"]);
  fields(supplied.hermes, ["version", "sourceSha", "source", "adapter", "python", "sourceIntegrity"]);
  fields(supplied.hermes.python, ["executable", "canonicalExecutable", "version", "libraryRoots", "venvRoot"]);
  if (supplied.openclaw) fields(supplied.openclaw, ["version", "sourceSha", "source", "adapter", "sourceIntegrity"]);
  if (supplied.node.version !== "26.10.0" || supplied.hermes.version !== HERMES_RUNTIME_PIN.version || supplied.hermes.sourceSha !== HERMES_RUNTIME_PIN.sourceSha
    || supplied.openclaw && (supplied.openclaw.version !== OPENCLAW_RUNTIME_PIN.version || supplied.openclaw.sourceSha !== OPENCLAW_RUNTIME_PIN.sourceSha)
    || typeof supplied.selectBroker !== "function") throw new CuratedRuntimeUnavailable("runtime", "Unsupported curated runtime pin or broker selector");
  if (supplied.hermes.sourceIntegrity !== undefined && supplied.hermes.sourceIntegrity !== "sealed-inventory-v1") throw new CuratedRuntimeUnavailable("runtime", "Unsupported source integrity contract");
  if (supplied.openclaw?.sourceIntegrity !== undefined && supplied.openclaw.sourceIntegrity !== "sealed-inventory-v1") throw new CuratedRuntimeUnavailable("runtime", "Unsupported source integrity contract");
  const selector = supplied.selectBroker;
  // Freeze configuration values independently of the caller. Do not retain bearer records.
  const config = structuredClone({ node: supplied.node, hermes: supplied.hermes, openclaw: supplied.openclaw, terminalBinaries: supplied.terminalBinaries ?? [] });
  const usedBearers = new Map<string, string>();
  return async (agent, scope, execution) => {
    if (agent.runtime?.mode === "connected") throw new CuratedRuntimeUnavailable("runtime", "Connected agents require a separately selected host connection; managed launch was not attempted");
    const registry = store.list(), registered = registry.agents.find(a => a.id === agent.id);
    if (!registered || JSON.stringify(registered) !== JSON.stringify(agent) || scope.agentId !== agent.id || scope.chain.at(-1) !== agent.id || scope.revision !== registry.revision)
      throw new CuratedRuntimeUnavailable("scope", "Persistent agent identity or scope is stale");
    store.knowledgeFor(agent.id, scope); // Validates the original host-minted scope even with memory disabled.
    if (!validAgentId(agent.id) || scope.allowedTools.includes("computer") || scope.allowedTools.some(t => ["web", "browser"].includes(t)))
      throw new CuratedRuntimeUnavailable("scope", "Selected tools require a separately verified host broker");
    fields(execution, ["kind", "id", "scratchRoot", "workspace", "memoryDir"]);
    const scratch = canonical(execution.scratchRoot, true);
    if (!["ordinary", "handoff"].includes(execution.kind) || !/^[a-f0-9]{64}$/.test(execution.id) || overlaps(scratch, store.root))
      throw new CuratedRuntimeUnavailable("scope", "Execution scratch is not a separate host-owned instance");
    const workspace = canonical(execution.workspace, true), memoryDir = safeAgentPath(execution.memoryDir);
    if (execution.kind === "ordinary" ? workspace !== agent.workspace || memoryDir !== agent.memoryDir
      : !pathWithin(join(scratch, "profile"), workspace) || !pathWithin(join(scratch, "profile"), memoryDir)) throw new CuratedRuntimeUnavailable("scope", "Execution paths exceed their immutable owner");
    // Uniform host-owned memory is the only proved OpenClaw resource tool; it is a host
    // capability behind the adapter's private pipe, never a native file or memory grant.
    if (agent.pluginId === "openclaw" && scope.allowedTools.some(tool => !OPENCLAW_SUPPORTED_TOOLS.includes(tool)))
      throw new CuratedRuntimeUnavailable("scope", "The curated OpenClaw candidate supports chat and uniform memory only; native tools are disabled");
    let selected: SelectedAgentBroker | undefined, timer: NodeJS.Timeout | undefined;
    try {
      selected = await Promise.race([
        Promise.resolve().then(() => selector(Object.freeze(structuredClone(agent)), Object.freeze({ ...execution }), scope)),
        new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error()), 10_000); }),
      ]);
    } catch { throw new CuratedRuntimeUnavailable("auth", "Host broker selection is unavailable; no fallback was attempted"); }
    finally { if (timer) clearTimeout(timer); }
    store.knowledgeFor(agent.id, scope); // A broker lookup may not race a scope revision.
    const broker = selected ? structuredClone(selected) : undefined;
    if (!broker) throw new CuratedRuntimeUnavailable("auth", "No exact host broker is selected; subscription/account authentication remains unavailable");
    fields(broker, ["kind", "agentId", "executionId", "accountBindingId", "host", "port", "model", "bearer"]);
    if (broker.kind !== "host-inference-broker-v1" || broker.agentId !== agent.id || broker.executionId !== execution.id || broker.accountBindingId !== agent.accountBindingId
      || broker.host !== "127.0.0.1" || !Number.isInteger(broker.port) || broker.port < 1024 || broker.port > 65535
      || typeof broker.model !== "string" || !/^[A-Za-z0-9_.:-]{1,128}$/.test(broker.model) || agent.model !== undefined && agent.model !== broker.model
      || typeof broker.bearer !== "string" || !/^[A-Za-z0-9._~-]{32,256}$/.test(broker.bearer)) throw new CuratedRuntimeUnavailable("auth", "The exact selected broker identity, model, address or bearer is invalid");
    const bearerOwner = `${agent.id}:${execution.id}`;
    const bearerDigest = createHash("sha256").update(broker.bearer).digest("hex");
    if (usedBearers.size >= 1024 && !usedBearers.has(bearerDigest)) throw new CuratedRuntimeUnavailable("auth", "Broker execution identity budget exhausted");
    if (usedBearers.has(bearerDigest) && usedBearers.get(bearerDigest) !== bearerOwner) throw new CuratedRuntimeUnavailable("auth", "Broker bearers must be fresh and unique to an execution instance");
    const node = canonical(config.node.executable);
    if (await inspect(node, ["-p", "process.versions.node"]) !== config.node.version) throw new CuratedRuntimeUnavailable("runtime", "Selected Node version differs from the explicit Node26 pin");
    const sourceConfig = agent.pluginId === "hermes" ? config.hermes : config.openclaw;
    if (!sourceConfig) throw new CuratedRuntimeUnavailable("runtime", "The selected plugin has no curated runtime configuration");
    const source = canonical(sourceConfig.source, true), adapter = canonical(sourceConfig.adapter);
    const manifest = readJson(join(dirname(adapter), "manifest.json"), 16 * 1024, false);
    if (basename(adapter) !== "adapter.mjs" || manifest?.schemaVersion !== 1 || manifest?.protocolVersion !== 1 || manifest?.entry !== "adapter.mjs"
      || manifest?.pluginId !== agent.pluginId || manifest?.upstream?.version !== sourceConfig.version
      || manifest?.upstream?.sourceSha !== (agent.pluginId === "hermes" ? HERMES_RUNTIME_PIN.sourceSha : OPENCLAW_RUNTIME_PIN.upstreamSha)
      || manifest?.authentication?.ambientCredentials !== false || manifest?.authentication?.billedFallback !== false
      || agent.pluginId === "openclaw" && (manifest?.curatedRuntime?.sourceSha !== OPENCLAW_RUNTIME_PIN.sourceSha || manifest?.curatedRuntime?.patchSha256 !== OPENCLAW_RUNTIME_PIN.patchSha256))
      throw new CuratedRuntimeUnavailable("runtime", "Selected adapter manifest does not match the pinned isolated plugin");
    const sealed = agent.pluginId === "hermes" && config.hermes.sourceIntegrity === "sealed-inventory-v1";
    if (sealed) { try { await verifySealedHermesSource(source); } catch { throw new CuratedRuntimeUnavailable("runtime", "Sealed Hermes source integrity check failed"); } }
    // A sealed OpenClaw input keeps minimal detached Git metadata, so the ordinary exact
    // commit/clean-tree checks still run here and the adapter verifies the full diff.
    const readPaths = [...(sealed ? [source] : await pinnedSource(source, sourceConfig.sourceSha, scratch)), node, canonical(dirname(adapter), true), ...roots(config.node.libraryRoots ?? [])];
    let python: string | undefined;
    if (agent.pluginId === "hermes") {
      const p = config.hermes.python, target = canonical(p.canonicalExecutable), parent = canonical(dirname(p.executable), true);
      if (resolve(p.executable) !== p.executable || realpathSync(p.executable) !== target) throw new CuratedRuntimeUnavailable("runtime", "Selected Python link does not resolve to its explicit canonical interpreter");
      if (p.venvRoot) {
        const venv = canonical(p.venvRoot, true);
        if (!pathWithin(source, venv) || parent !== join(venv, "bin") || !existsSync(join(venv, "pyvenv.cfg"))) throw new CuratedRuntimeUnavailable("runtime", "Python virtual environment is not explicitly owned by the pinned source");
        const venvConfig = canonical(join(venv, "pyvenv.cfg"));
        if (lstatSync(venvConfig).size > 4096) throw new CuratedRuntimeUnavailable("runtime", "Python virtual environment metadata exceeds its budget");
        const metadata = readFileSync(venvConfig, "utf8"), home = /^home\s*=\s*(.+)$/m.exec(metadata)?.[1];
        if (!home || safeAgentPath(home, true) !== dirname(target) || !/^include-system-site-packages\s*=\s*false\s*$/m.test(metadata))
          throw new CuratedRuntimeUnavailable("runtime", "Python virtual environment may not inherit installed system packages");
        readPaths.push(venv);
      } else if (p.executable !== target) throw new CuratedRuntimeUnavailable("runtime", "Python links require an explicit owned virtual environment");
      const actual = await inspect(target, ["-I", "-B", "-S", "-c", "import sys;print('.'.join(map(str,sys.version_info[:3])))"]);
      if (!/^3\.(11|12|13)\.\d+$/.test(p.version) || actual !== p.version) throw new CuratedRuntimeUnavailable("runtime", "Selected Python version differs from its compatible explicit pin");
      python = p.executable; readPaths.push(target, ...roots(p.libraryRoots));
      const metadata = readFileSync(join(source, "pyproject.toml"), "utf8");
      if (!/^version\s*=\s*"0\.21\.5"\s*$/m.test(metadata)) throw new CuratedRuntimeUnavailable("runtime", "Hermes package metadata differs from its pin");
    } else {
      // Read-only source/build checks. This code never invokes install/build/Gateway.
      const packageInfo = readJson(join(source, "package.json"), 128 * 1024, false);
      if (packageInfo?.name !== "openclaw" || packageInfo?.version !== OPENCLAW_RUNTIME_PIN.version) throw new CuratedRuntimeUnavailable("runtime", "OpenClaw package metadata differs from its pin");
      for (const file of ["dist/entry.js", "dist/yorozu-gateway-embedding.js", "dist/build-info.json"]) canonical(join(source, file));
      canonical(join(source, "node_modules"), true);
      const build = readJson(join(source, "dist/build-info.json"), 4096, false);
      if (build.commit !== OPENCLAW_RUNTIME_PIN.sourceSha || build.version !== OPENCLAW_RUNTIME_PIN.version) throw new CuratedRuntimeUnavailable("runtime", "OpenClaw build metadata differs from its curated pin");
    }
    if (scope.allowedTools.includes("terminal")) readPaths.push(...roots(config.terminalBinaries));
    const curated = [...new Set(readPaths)];
    if (curated.some(p => overlaps(p, store.root) || overlaps(p, scratch) || scope.directories.some(g => g.access === "write" && overlaps(g.path, p))))
      throw new CuratedRuntimeUnavailable("scope", "Code roots overlap private state, runtime scratch, or writable resources");
    const profile = join(scratch, "profile"); safeAgentPath(profile); mkdirSync(profile, { recursive: true, mode: 0o700 }); canonical(profile, true);
    if (lstatSync(profile).mode & 0o077) throw new CuratedRuntimeUnavailable("scope", "Broker profile is not private");
    const marker = join(scratch, ".yorozu-curated-owner.json"), owner = { version: 1, agentId: agent.id, executionId: execution.id, pluginId: agent.pluginId, sourceSha: sourceConfig.sourceSha };
    const previous = readJson(marker);
    if (previous && JSON.stringify(previous) !== JSON.stringify(owner)) throw new CuratedRuntimeUnavailable("scope", "Runtime bootstrap belongs to another owner");
    if (!previous && existsSync(join(profile, "proof-provider.json"))) throw new CuratedRuntimeUnavailable("auth", "An existing provider bootstrap cannot be adopted");
    // Reserve before any asynchronous listener acquisition, so two candidates
    // cannot share a bearer while both wait for a host socket.
    if (usedBearers.has(bearerDigest) && usedBearers.get(bearerDigest) !== bearerOwner) throw new CuratedRuntimeUnavailable("auth", "Broker bearers must be fresh and unique to an execution instance");
    usedBearers.set(bearerDigest, bearerOwner);
    let listener: HostListenerLease | undefined;
    try {
      if (agent.pluginId === "openclaw") listener = await acquireHostListener(agent.id);
      if (listener?.port === broker.port) throw new CuratedRuntimeUnavailable("runtime", "Gateway and broker ports must be distinct");
      const providerConfigPath = join(profile, "proof-provider.json");
      privateJson(marker, owner);
      privateJson(providerConfigPath, { baseUrl: `http://127.0.0.1:${broker.port}/v1`, model: broker.model, bearer: broker.bearer,
        ...(agent.pluginId === "hermes" ? { apiMode: "codex_responses" } : { api: "openai-responses" }) });
      return { configuration: { pluginId: agent.pluginId, command: node, args: [adapter], upstreamVersion: sourceConfig.version,
        initialize: { upstreamVersion: sourceConfig.version, providerConfigPath, ...(agent.pluginId === "hermes" ? { python, sourcePath: source, ...(sealed ? { sourceIntegrity: { kind: "sealed-inventory-v1", sourceSha: HERMES_RUNTIME_PIN.sourceSha, inventorySha256: SEALED_HERMES_SOURCE_SHA256 } } : {}), provider: "custom:yorozu-local-proof", model: broker.model }
          : { source, node, gatewayPort: listener!.port }) } },
      runtime: { command: node, args: [adapter], runtimeDir: scratch, readPaths: curated, brokerPorts: [broker.port], ...(listener ? { inheritedListeners: [listener] } : {}) } };
    } catch (error) { if (listener) await releaseHostListener(listener); throw error; }
  };
}
