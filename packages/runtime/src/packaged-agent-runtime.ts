/** Trusted app-bundle loader. No environment, profile, account, or client path discovery. */
import { createHash } from "node:crypto";
import { constants, promises as fs, openSync, fstatSync, readFileSync, closeSync, existsSync } from "node:fs";
import { basename, dirname, isAbsolute, join, posix, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { pathWithin, safeAgentPath } from "./agent-scope.js";
import { createCuratedAgentRuntimeFactory, CuratedRuntimeUnavailable, HERMES_RUNTIME_PIN, type CuratedAgentRuntimeConfiguration } from "./curated-agent-runtime.js";
import type { PersonAgentPlatform } from "./person-agent-host.js";

const PIN = Object.freeze({ sourceTree: "5849eacde63aaea608ca418821cc84771fce3bec", uvLockSha256: "5b3798f326209475abca8ef7cbf7c9406f12e687c28c0b540dfe597466f48590",
  pythonVersion: "3.13.16", pythonTreeSha256: "9666d8c2f6e7adad510d58a11cf25a2e9e5f0d1aeb2cf0a7fc044ea897419599",
  pythonBinarySha256: "b898474cdfda938c1dd25af22d1b066d4808ba8b7e2d14e20033781d7787f87f" });
const PATHS = Object.freeze({ python: "python/bin/python3.13", source: "source", adapter: "plugin/adapter.mjs" });
const JPEG = Object.freeze({ path: "python/lib/python3.13/site-packages/PIL/.dylibs/libjpeg.62.4.0.dylib",
  inputSha256: "cf7c4e5c2d2c007fc51afcb95b649415cfe0bc4d7137ace897a6eff6550fa967",
  outputSha256: "56a3a10ac81f12a0e6ae7cc5a023924067f4e7c2defd8308b9ed806064ab560d",
  removeRpath: "/Users/runner/work/Pillow/Pillow/build/deps/darwin/lib" });
const MAX_MANIFEST_BYTES = 8 * 1024 * 1024, MAX_FILES = 32768, MAX_FILE_BYTES = 256 * 1024 * 1024, MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024;
const BAD = "The packaged Hermes runtime is unavailable or its sealed inventory is invalid.";
interface FileRow { path: string; sha256: string; mode: 420 | 493 }
interface LinkRow { path: string; link: string }
type Row = FileRow | LinkRow;
interface Artifact { files: Row[]; inventorySha256: string; adapterSourceSha: string; hashStage: string }
export interface PackagedRuntimeServices {
  selectBroker: CuratedAgentRuntimeConfiguration["selectBroker"];
  releaseBroker?(agentId: string, executionId: string): Promise<void>;
  protectedRoots?: readonly string[];
  bindStore?(store: import("./agent-store.js").PersonAgentStore): void;
}
export interface VerifiedPackagedHermesRuntime {
  readonly productionReady: false; readonly inventorySha256: string; readonly adapterSourceSha: string;
  readonly hashStage: "assembled-before-signing" | "after-nested-signing-before-outer-bundle-signing";
}
const sha256 = (text: string): string => createHash("sha256").update(text).digest("hex");
const object = (v: unknown): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v);
function fields(v: unknown, names: string[]): asserts v is Record<string, any> {
  if (!object(v) || Object.keys(v).length !== names.length || names.some(k => !Object.hasOwn(v, k))) throw new Error(BAD);
}
function text(v: unknown, max = 1024): v is string { return typeof v === "string" && !!v && v.length <= max && !/[\0-\x1f\x7f]/.test(v); }
function relative(v: unknown): v is string {
  return text(v) && !isAbsolute(v) && !v.includes("\\") && !v.split("/").some(p => !p || p === "." || p === "..")
    && !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(v);
}
const hash = (v: unknown): v is string => typeof v === "string" && /^[a-f0-9]{64}$/.test(v);
function rows(value: unknown): Row[] {
  if (!Array.isArray(value) || !value.length || value.length > MAX_FILES) throw new Error(BAD);
  const seen = new Set<string>(), result: Row[] = [];
  for (const row of value) {
    if (!object(row) || !relative(row.path) || row.path === "runtime-artifact.json" || seen.has(row.path)) throw new Error(BAD);
    // Canonical Python JSON uses sorted object keys, UTF-8, compact separators.
    if (Object.hasOwn(row, "link")) {
      fields(row, ["path", "link"]);
      if (!text(row.link) || isAbsolute(row.link) || row.link.includes("\\")) throw new Error(BAD);
      const target = posix.normalize(posix.join(posix.dirname(row.path), row.link));
      if (target === ".." || target.startsWith("../") || posix.isAbsolute(target)) throw new Error(BAD);
      result.push({ link: row.link, path: row.path });
    } else {
      fields(row, ["path", "sha256", "mode"]);
      if (!hash(row.sha256) || row.mode !== 420 && row.mode !== 493) throw new Error(BAD);
      result.push({ mode: row.mode, path: row.path, sha256: row.sha256 });
    }
    seen.add(row.path);
  }
  for (const row of result) {
    let parent = posix.dirname(row.path);
    while (parent !== ".") { if (seen.has(parent)) throw new Error(BAD); parent = posix.dirname(parent); }
  }
  return result;
}
function validate(value: unknown): Artifact {
  fields(value, ["schemaVersion", "kind", "productionReady", "hashStage", "upstream", "adapterSourceSha", "paths", "derivation", "runtimeRequirements", "inertImportProbe", "machODependencies", "files", "inventorySha256"]);
  if (value.schemaVersion !== 1 || value.kind !== "yorozu-hermes-runtime" || value.productionReady !== false
    || !["assembled-before-signing", "after-nested-signing-before-outer-bundle-signing"].includes(value.hashStage)
    || typeof value.adapterSourceSha !== "string" || !/^[a-f0-9]{40}$/.test(value.adapterSourceSha) || !hash(value.inventorySha256)) throw new Error(BAD);
  fields(value.paths, ["python", "source", "adapter"]);
  if (Object.entries(PATHS).some(([key, path]) => value.paths[key] !== path)) throw new Error(BAD);
  const u = value.upstream;
  fields(u, ["schemaVersion", "hermesVersion", "sourceSha", "sourceTree", "uvLockSha256", "pythonVersion", "platform", "pythonTreeSha256", "pythonBinarySha256", "dependencies", "dependencyEvidence", "pythonEvidence"]);
  if (u.schemaVersion !== 1 || u.hermesVersion !== HERMES_RUNTIME_PIN.version || u.sourceSha !== HERMES_RUNTIME_PIN.sourceSha
    || u.platform !== "darwin-arm64" || Object.entries(PIN).some(([key, expected]) => u[key] !== expected)
    || u.dependencyEvidence !== "installed versions match uv.lock and installed RECORD bytes; original wheel archive hashes are not reverified"
    || u.pythonEvidence !== "prepared local CPython snapshot hashes; original download archive receipt is not present"
    || !Array.isArray(u.dependencies) || !u.dependencies.length || u.dependencies.length > 512) throw new Error(BAD);
  const dependencies = new Set<string>();
  for (const d of u.dependencies) {
    fields(d, ["name", "version", "inputRecordSha256", "verifiedRecordFiles"]);
    if (!text(d.name, 128) || !/^[a-z0-9][a-z0-9_.-]*$/.test(d.name) || dependencies.has(d.name) || !text(d.version, 128)
      || !hash(d.inputRecordSha256) || !Number.isSafeInteger(d.verifiedRecordFiles) || d.verifiedRecordFiles < 0 || d.verifiedRecordFiles > 100000) throw new Error(BAD);
    dependencies.add(d.name);
  }
  fields(value.derivation, ["upstreamSourceModified", "pythonSitePackagesReplaced", "editableAndStartupHooksRemoved", "consoleScriptsExcluded", "dependencyRecordsRewritten", "sourceGitMetadata", "nativeLoadCommandTransformations"]);
  if (value.derivation.upstreamSourceModified !== false || ["pythonSitePackagesReplaced", "editableAndStartupHooksRemoved", "consoleScriptsExcluded", "dependencyRecordsRewritten"].some(k => value.derivation[k] !== true)
    || value.derivation.sourceGitMetadata !== "new one-commit objects/index; no remotes, hooks, alternates or original config") throw new Error(BAD);
  fields(value.runtimeRequirements, ["lazyInstalls", "ambientPython", "ambientProfiles", "subscriptionProof"]);
  if (value.runtimeRequirements.lazyInstalls !== "trusted adapter must disable; helper never installs" || value.runtimeRequirements.ambientPython !== false
    || value.runtimeRequirements.ambientProfiles !== false || value.runtimeRequirements.subscriptionProof !== false) throw new Error(BAD);
  const p = value.inertImportProbe;
  fields(p, ["version", "system", "machine", "certifi", "dependencyClosure"]);
  if (p.version !== PIN.pythonVersion || p.system !== "Darwin" || p.machine !== "arm64" || p.certifi !== "python/lib/python3.13/site-packages/certifi/cacert.pem"
    || !Array.isArray(p.dependencyClosure) || !p.dependencyClosure.length || p.dependencyClosure.length > 512
    || p.dependencyClosure.some((name: unknown) => !text(name, 128) || !/^[A-Za-z0-9_.-]+$/.test(name as string)) || new Set(p.dependencyClosure).size !== p.dependencyClosure.length) throw new Error(BAD);
  const inventory = rows(value.files), entries = new Map(inventory.map(row => [row.path, row]));
  const transformations = value.derivation.nativeLoadCommandTransformations, jpeg = entries.get(JPEG.path);
  if (!Array.isArray(transformations) || transformations.length !== (jpeg ? 2 : 0)) throw new Error(BAD);
  if (jpeg) {
    const [edit, signature] = transformations;
    fields(edit, ["path", "inputSha256", "operation", "removeRpath", "outputSha256"]);
    if (Object.entries(JPEG).some(([k, v]) => edit[k] !== v) || edit.operation !== "install_name_tool -delete_rpath") throw new Error(BAD);
    fields(signature, ["path", "operation", "inputSha256", "outputSha256", "identity", "distributionSigning"]);
    if (signature.path !== JPEG.path || signature.operation !== "codesign --force --sign -" || signature.inputSha256 !== JPEG.outputSha256
      || !hash(signature.outputSha256) || signature.identity !== "ad-hoc" || signature.distributionSigning !== false || !("sha256" in jpeg)
      || value.hashStage === "assembled-before-signing" && signature.outputSha256 !== jpeg.sha256) throw new Error(BAD);
  }
  for (const required of [PATHS.python, PATHS.adapter, "source/pyproject.toml", "source/uv.lock", "source/.git/HEAD", "source/.git/index", "plugin/manifest.json", "plugin/bootstrap.py", "plugin/platform/__init__.py", "plugin/platform/plugin.yaml", p.certifi])
    if (!entries.has(required) || !("sha256" in entries.get(required)!)) throw new Error(BAD);
  if (!Array.isArray(value.machODependencies) || !value.machODependencies.length || value.machODependencies.length > 512) throw new Error(BAD);
  const native = new Set<string>();
  for (const m of value.machODependencies) {
    fields(m, ["path", "architectures", "dependencies"]);
    if (!relative(m.path) || native.has(m.path) || !entries.has(m.path) || !("sha256" in entries.get(m.path)!)
      || !Array.isArray(m.architectures) || !m.architectures.includes("arm64") || m.architectures.length > 4 || new Set(m.architectures).size !== m.architectures.length || m.architectures.some((a: unknown) => !["arm64", "x86_64", "arm64e"].includes(a as string))
      || !Array.isArray(m.dependencies) || m.dependencies.length > 256) throw new Error(BAD);
    for (const dependency of m.dependencies) {
      fields(dependency, ["load", "resolved"]);
      if (!text(dependency.load) || !text(dependency.resolved) || (dependency.resolved === "system"
        ? resolve(dependency.load) !== dependency.load || !dependency.load.startsWith("/usr/lib/") && !dependency.load.startsWith("/System/Library/")
        : !relative(dependency.resolved) || !entries.has(dependency.resolved))) throw new Error(BAD);
    }
    native.add(m.path);
  }
  if (!native.has(PATHS.python) || sha256(JSON.stringify(inventory)) !== value.inventorySha256) throw new Error(BAD);
  return { files: inventory, inventorySha256: value.inventorySha256, adapterSourceSha: value.adapterSourceSha, hashStage: value.hashStage };
}
async function regular(path: string, limit: number): Promise<fs.FileHandle> {
  safeAgentPath(path, true); const file = await fs.open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try { const s = await file.stat(); if (!s.isFile() || s.nlink !== 1 || s.size > limit) throw new Error(BAD); return file; }
  catch (error) { await file.close(); throw error; }
}
/** Deferred, asynchronous integrity check of the sealed bundle payload. Its origin is
 * the trusted app Resources root/outer signature, not this self-described digest.
 * This does not establish production readiness, archive provenance, or subscription access.
 */
export async function verifyPackagedHermesArtifact(resourcesRoot: string): Promise<VerifiedPackagedHermesRuntime> {
  try {
    const resources = safeAgentPath(resourcesRoot, true), root = safeAgentPath(join(resources, "agent-runtimes", "hermes"), true);
    if (!(await fs.lstat(resources)).isDirectory() || !(await fs.lstat(root)).isDirectory()) throw new Error(BAD);
    const manifestFile = await regular(join(root, "runtime-artifact.json"), MAX_MANIFEST_BYTES);
    let artifact: Artifact;
    try { artifact = validate(JSON.parse(await manifestFile.readFile("utf8"))); } finally { await manifestFile.close(); }
    const expected = new Map(artifact.files.map(row => [row.path, row])), found = new Set<string>(); let bytes = 0, visited = 0;
    const pending: string[] = [];
    async function walk(directory: string): Promise<void> {
      const iterator = await fs.opendir(directory);
      for await (const entry of iterator) {
        if (++visited > MAX_FILES * 2) throw new Error(BAD);
        const path = join(directory, entry.name), name = path.slice(root.length + 1);
        if (name === "runtime-artifact.json") continue;
        const s = await fs.lstat(path);
        if (s.isDirectory()) { safeAgentPath(path, true); await walk(path); continue; }
        const row = expected.get(name); if (!row || found.has(name)) throw new Error(BAD); found.add(name);
        if ("link" in row) {
          if (!s.isSymbolicLink() || await fs.readlink(path) !== row.link || !pathWithin(root, await fs.realpath(path))) throw new Error(BAD);
        } else {
          if (!s.isFile() || s.nlink !== 1 || s.mode & 0o022 || (s.mode & 0o111 ? 493 : 420) !== row.mode || s.size > MAX_FILE_BYTES || (bytes += s.size) > MAX_TOTAL_BYTES) throw new Error(BAD);
          pending.push(name);
        }
      }
    }
    await walk(root); if (found.size !== expected.size) throw new Error(BAD);
    let index = 0, cancelled = false;
    await Promise.all(Array.from({ length: Math.min(4, pending.length) }, async () => {
      while (index < pending.length && !cancelled) {
        const name = pending[index++], row = expected.get(name) as FileRow, file = await regular(join(root, name), MAX_FILE_BYTES);
        try {
          const digest = createHash("sha256"), stream = file.createReadStream({ autoClose: false });
          let read = 0;
          for await (const chunk of stream) { if (cancelled || (read += chunk.length) > MAX_FILE_BYTES) throw new Error(BAD); digest.update(chunk); }
          if (digest.digest("hex") !== row.sha256) throw new Error(BAD);
        } catch (error) { cancelled = true; throw error; } finally { await file.close(); }
      }
    }));
    return Object.freeze({ productionReady: false, inventorySha256: artifact.inventorySha256, adapterSourceSha: artifact.adapterSourceSha,
      hashStage: artifact.hashStage as VerifiedPackagedHermesRuntime["hashStage"] });
  } catch { throw new CuratedRuntimeUnavailable("runtime", BAD); }
}

/** Only trusted application startup calls this. Runtime validation is deferred to
 * preparation, so registry/screens remain available without usable code or account.
 * No automatic secretary migration and no client/environment path overrides exist.
 */
export function packagedPersonAgentPlatform(resourcesRoot: string, services: PackagedRuntimeServices): PersonAgentPlatform {
  if (typeof resourcesRoot !== "string" || resourcesRoot.length > 4096 || !isAbsolute(resourcesRoot) || resolve(resourcesRoot) !== resourcesRoot || /[\0\r\n]/.test(resourcesRoot)
    || !object(services) || Object.keys(services).some(k => !["selectBroker", "releaseBroker", "protectedRoots", "bindStore"].includes(k)) || typeof services.selectBroker !== "function"
    || services.releaseBroker !== undefined && typeof services.releaseBroker !== "function"
    || services.bindStore !== undefined && typeof services.bindStore !== "function")
    throw new CuratedRuntimeUnavailable("runtime", "Explicit trusted packaged resources and broker selector are required.");
  const selected = services.selectBroker, root = join(resourcesRoot, "agent-runtimes", "hermes");
  return { initialAgent: { id: "yorozu", name: "Yorozu", role: "Secretary", pluginId: "hermes", allowedTools: ["file", "memory", "delegation"], directories: [] },
    catalog: () => ({ ...(existsSync(root) ? { defaultHarnessId: "hermes" as const } : {}), harnesses: [
      { id: "hermes", label: "Hermes", available: existsSync(root), modes: ["managed"], capabilities: ["agent-messaging-v1"],
        ...(!existsSync(root) ? { unavailableReason: "The packaged Hermes runtime is unavailable." } : {}) },
      { id: "openclaw", label: "OpenClaw", available: false, modes: [], capabilities: [], unavailableReason: "No verified packaged runtime or selected host connection is available." },
    ], connections: [] }),
    protectedRoots: services.protectedRoots,
    createFactory: store => {
      services.bindStore?.(store);
      const factory = createCuratedAgentRuntimeFactory(store, { node: { executable: join(resourcesRoot, "node"), version: "26.10.0" },
        hermes: { ...HERMES_RUNTIME_PIN, source: join(root, PATHS.source), adapter: join(root, PATHS.adapter),
          python: { executable: join(root, PATHS.python), canonicalExecutable: join(root, PATHS.python), version: PIN.pythonVersion, libraryRoots: [join(root, "python", "lib"), join(root, "python", "share")] } }, selectBroker: selected });
      return async (agent, scope, execution) => {
        if (agent.pluginId !== "hermes") throw new CuratedRuntimeUnavailable("runtime", "The selected plugin has no packaged runtime.");
        // Deliberately no cached success: changed payload bytes must fail the next preparation.
        await verifyPackagedHermesArtifact(resourcesRoot);
        try {
          const built = await factory(agent, scope, execution);
          let released = false;
          return { ...built, release: async () => {
            if (released) return; released = true;
            await services.releaseBroker?.(agent.id, execution.id);
          } };
        }
        catch (error) {
          await services.releaseBroker?.(agent.id, execution.id);
          const capability = error instanceof CuratedRuntimeUnavailable ? error.capability : "runtime";
          throw new CuratedRuntimeUnavailable(capability, capability === "auth" ? "A supported trusted account broker is unavailable for this agent."
            : capability === "scope" ? "The selected agent execution scope is unavailable." : BAD);
        }
      };
    } };
}

/** Fixed shipping entry and signed build marker only. Developer CLI invocations and
 * older bundles retain their existing execution route. Account onboarding is not
 * implemented here; preparation reports unavailable instead of discovering auth.
 */
export function packagedResourcesFromEntry(entry: URL): string | undefined {
  const path = fileURLToPath(entry), dist = dirname(path), runtime = dirname(dist), resources = dirname(runtime);
  if (basename(path) !== "secretary-serve.js" || basename(dist) !== "dist" || basename(runtime) !== "runtime" || basename(resources) !== "Resources") return;
  let fd: number;
  try { fd = openSync(join(resources, "internal-source.json"), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw new CuratedRuntimeUnavailable("runtime", BAD); }
  try {
    const s = fstatSync(fd); if (!s.isFile() || s.nlink !== 1 || s.size > 8 * 1024 * 1024) throw new Error(BAD);
    const marker = JSON.parse(readFileSync(fd, "utf8"));
    if (!object(marker) || marker.personAgentPlatform === undefined) return;
    fields(marker.personAgentPlatform, ["kind", "productionReady"]);
    if (marker.schemaVersion !== 1 || marker.runtimeEntry !== "runtime/dist/secretary-serve.js" || marker.harnessProtocolVersion !== 1
      || marker.personAgentPlatform.kind !== "packaged-hermes-v1" || marker.personAgentPlatform.productionReady !== false) throw new Error(BAD);
    return safeAgentPath(resources, true);
  } catch { throw new CuratedRuntimeUnavailable("runtime", BAD); } finally { closeSync(fd); }
}

/** Compatibility read-only entry helper; production supplies its explicit account owner. */
export function packagedPersonAgentPlatformFromEntry(entry: URL): PersonAgentPlatform | undefined {
  const resources = packagedResourcesFromEntry(entry);
  return resources ? packagedPersonAgentPlatform(resources, { selectBroker: () => undefined }) : undefined;
}
