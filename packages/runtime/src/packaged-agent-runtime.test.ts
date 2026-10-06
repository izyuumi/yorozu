/** Synthetic sealed payloads and real integrity IO; no interpreters/auth/Gateway/models. */
import { afterEach, expect, test, vi } from "vitest";
import fs from "node:fs";
import { createHash } from "node:crypto";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
import * as curated from "./curated-agent-runtime.js";
import { PersonAgentStore } from "./agent-store.js";
import { PersonAgentHost } from "./person-agent-host.js";
import { packagedPersonAgentPlatform, packagedPersonAgentPlatformFromEntry, verifyPackagedHermesArtifact } from "./packaged-agent-runtime.js";

const roots: string[] = [], owners: PersonAgentHost[] = [];
afterEach(async () => { for (const owner of owners.splice(0)) await owner.close(); vi.restoreAllMocks(); vi.unstubAllEnvs(); for (const root of roots.splice(0)) fs.rmSync(root, { recursive: true, force: true }); });
const digest = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");

test("only the fixed packaged entry with its explicit build marker activates person screens without auth", () => {
  const root = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), "yorozu-packaged-entry-"))); roots.push(root);
  const resources = join(root, "Resources"); fs.mkdirSync(resources);
  const entry = pathToFileURL(join(resources, "runtime/dist/secretary-serve.js"));
  expect(packagedPersonAgentPlatformFromEntry(pathToFileURL(join(root, "packages/runtime/dist/secretary-serve.js")))).toBeUndefined();
  expect(packagedPersonAgentPlatformFromEntry(entry)).toBeUndefined();
  fs.writeFileSync(join(resources, "internal-source.json"), JSON.stringify({ schemaVersion: 1, runtimeEntry: "runtime/dist/secretary-serve.js", harnessProtocolVersion: 1 }));
  expect(packagedPersonAgentPlatformFromEntry(entry)).toBeUndefined();
  const marker = { schemaVersion: 1, runtimeEntry: "runtime/dist/secretary-serve.js", harnessProtocolVersion: 1,
    personAgentPlatform: { kind: "packaged-hermes-v1", productionReady: false } };
  fs.writeFileSync(join(resources, "internal-source.json"), JSON.stringify(marker));
  const platform = packagedPersonAgentPlatformFromEntry(entry)!;
  expect(platform.initialAgent?.id).toBe("yorozu"); expect(platform.secretaryAgentId).toBe("yorozu"); expect(platform.workerMemory).toBe(true);
  marker.personAgentPlatform.productionReady = true;
  fs.writeFileSync(join(resources, "internal-source.json"), JSON.stringify(marker));
  expect(() => packagedPersonAgentPlatformFromEntry(entry)).toThrow(curated.CuratedRuntimeUnavailable);
});
function fixture() {
  const root = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), "yorozu-packaged-runtime-"))); roots.push(root);
  const resources = join(root, "Resources"), runtime = join(resources, "agent-runtimes/hermes"); fs.mkdirSync(runtime, { recursive: true });
  const files = ["plugin/adapter.mjs", "plugin/bootstrap.py", "plugin/manifest.json", "plugin/platform/__init__.py", "plugin/platform/plugin.yaml",
    "python/bin/python3.13", "python/lib/python3.13/site-packages/certifi/cacert.pem", "python/share/resource.txt", "source/.git/HEAD", "source/.git/index", "source/pyproject.toml", "source/uv.lock"];
  for (const name of files) { const path = join(runtime, name); fs.mkdirSync(dirname(path), { recursive: true }); fs.writeFileSync(path, `Synthetic sealed ${name}`, { mode: name === "python/bin/python3.13" ? 0o755 : 0o644 }); }
  fs.symlinkSync("python3.13", join(runtime, "python/bin/python3")); fs.writeFileSync(join(resources, "node"), "Synthetic owned Node");
  const inventory: any[] = [...files.map(path => ({ mode: path === "python/bin/python3.13" ? 493 : 420, path, sha256: digest(fs.readFileSync(join(runtime, path))) })), { link: "python3.13", path: "python/bin/python3" }].sort((a, b) => Buffer.compare(Buffer.from(a.path), Buffer.from(b.path)));
  const manifest: any = { schemaVersion: 1, kind: "yorozu-hermes-runtime", productionReady: false, hashStage: "assembled-before-signing", adapterSourceSha: "a".repeat(40),
    paths: { python: "python/bin/python3.13", source: "source", adapter: "plugin/adapter.mjs" }, files: inventory, inventorySha256: digest(JSON.stringify(inventory)),
    upstream: { schemaVersion: 1, hermesVersion: "0.21.5", sourceSha: "f97608f178d1ffeca59860195ab7da295f7c8e5f", sourceTree: "5849eacde63aaea608ca418821cc84771fce3bec",
      uvLockSha256: "5b3798f326209475abca8ef7cbf7c9406f12e687c28c0b540dfe597466f48590", pythonVersion: "3.13.16", platform: "darwin-arm64",
      pythonTreeSha256: "9666d8c2f6e7adad510d58a11cf25a2e9e5f0d1aeb2cf0a7fc044ea897419599", pythonBinarySha256: "b898474cdfda938c1dd25af22d1b066d4808ba8b7e2d14e20033781d7787f87f",
      dependencies: [{ name: "hermes-agent", version: "0.21.5", inputRecordSha256: "b".repeat(64), verifiedRecordFiles: 1 }],
      dependencyEvidence: "installed versions match uv.lock and installed RECORD bytes; original wheel archive hashes are not reverified",
      pythonEvidence: "prepared local CPython snapshot hashes; original download archive receipt is not present" },
    derivation: { upstreamSourceModified: false, pythonSitePackagesReplaced: true, editableAndStartupHooksRemoved: true, consoleScriptsExcluded: true, dependencyRecordsRewritten: true,
      sourceGitMetadata: "new one-commit objects/index; no remotes, hooks, alternates or original config", nativeLoadCommandTransformations: [] },
    runtimeRequirements: { lazyInstalls: "trusted adapter must disable; helper never installs", ambientPython: false, ambientProfiles: false, subscriptionProof: false },
    inertImportProbe: { version: "3.13.16", system: "Darwin", machine: "arm64", certifi: "python/lib/python3.13/site-packages/certifi/cacert.pem", dependencyClosure: ["hermes-agent"] },
    machODependencies: [{ path: "python/bin/python3.13", architectures: ["arm64"], dependencies: [{ load: "/usr/lib/libSystem.B.dylib", resolved: "system" }] }] };
  const save = () => fs.writeFileSync(join(runtime, "runtime-artifact.json"), JSON.stringify(manifest)); save();
  const reseal = () => { manifest.inventorySha256 = digest(JSON.stringify(manifest.files.map((row: any) => "link" in row ? { link: row.link, path: row.path } : { mode: row.mode, path: row.path, sha256: row.sha256 }))); save(); };
  return { root, resources, runtime, manifest, save, reseal };
}

test("trusted platform startup publishes a private fresh secretary even with no usable runtime/auth; uniform worker selection", async () => {
  const f = fixture(); fs.rmSync(join(f.resources, "agent-runtimes"), { recursive: true });
  const selectBroker = vi.fn(() => undefined), platform = packagedPersonAgentPlatform(f.resources, { selectBroker });
  const host = new PersonAgentHost(join(f.root, "state"), platform); owners.push(host);
  expect(host.registry()).toMatchObject({ version: 1, defaultAgentId: "yorozu", agents: [{ id: "yorozu", name: "Yorozu", pluginId: "hermes", allowedTools: ["delegation", "file", "memory"], directories: [] }] });
  expect(host.owns("yorozu-secretary-v1")).toBe(true); expect(platform.secretaryAgentId).toBe("yorozu"); expect(platform.workerMemory).toBe(true); expect(selectBroker).not.toHaveBeenCalled();
  const factory = platform.createFactory(host.store), agent = host.store.list().agents[0];
  await expect(factory(agent, host.store.resolveScope(agent.id), {} as any)).rejects.toMatchObject({ status: "unsupported", capability: "runtime" });
  expect(selectBroker).not.toHaveBeenCalled();
});

test("sealed inventory validates bytes and contained links while retaining false production/subscription claims", async () => {
  const f = fixture(), before = fs.readFileSync(join(f.runtime, "runtime-artifact.json"), "utf8");
  fs.chmodSync(join(f.runtime, "source/.git/HEAD"), 0o444);
  expect(await verifyPackagedHermesArtifact(f.resources)).toEqual({ productionReady: false, inventorySha256: f.manifest.inventorySha256, adapterSourceSha: "a".repeat(40), hashStage: "assembled-before-signing" });
  expect(fs.readFileSync(join(f.runtime, "runtime-artifact.json"), "utf8")).toBe(before);
  fs.writeFileSync(join(f.runtime, "plugin/adapter.mjs"), "Changed sealed adapter");
  await expect(verifyPackagedHermesArtifact(f.resources)).rejects.toMatchObject({ capability: "runtime", status: "unsupported" });
});

test("factory delegates only fixed packaged paths after validation and ignores environment locations", async () => {
  const f = fixture(), store = new PersonAgentStore(join(f.root, "state")), selectBroker = vi.fn(() => undefined);
  vi.stubEnv("YOROZU_HERMES_SOURCE", "/ambient/source"); vi.stubEnv("PYTHONPATH", "/ambient/credentials"); vi.stubEnv("OPENAI_API_KEY", "AMBIENT_TOKEN_MUST_NOT_APPEAR");
  const run = vi.fn(async () => { throw new curated.CuratedRuntimeUnavailable("auth", "No host broker is selected"); });
  const make = vi.spyOn(curated, "createCuratedAgentRuntimeFactory").mockReturnValue(run);
  const platform = packagedPersonAgentPlatform(f.resources, { selectBroker }), factory = platform.createFactory(store);
  const openclawRuntime = join(f.resources, "agent-runtimes/openclaw");
  expect(make).toHaveBeenCalledExactlyOnceWith(store, { node: { executable: join(f.resources, "node"), version: "26.10.0" },
    hermes: { version: "0.21.5", sourceSha: "f97608f178d1ffeca59860195ab7da295f7c8e5f", source: join(f.runtime, "source"), sourceIntegrity: "sealed-inventory-v1", adapter: join(f.runtime, "plugin/adapter.mjs"),
      python: { executable: join(f.runtime, "python/bin/python3.13"), canonicalExecutable: join(f.runtime, "python/bin/python3.13"), version: "3.13.16", libraryRoots: [join(f.runtime, "python/lib"), join(f.runtime, "python/share")] } },
    openclaw: { version: "2026.9.8", sourceSha: "f04797ef4d24f3da0f9df74acd58ab773ab5f11e", source: join(openclawRuntime, "source"), adapter: join(openclawRuntime, "plugin/adapter.mjs"), sourceIntegrity: "sealed-inventory-v1" },
    selectBroker });
  const args = [{ pluginId: "hermes" }, {}, {}] as any;
  await expect(factory(...args)).rejects.toMatchObject({ capability: "auth" }); expect(run).toHaveBeenCalledTimes(1);
  // OpenClaw is registered for uniform memory, but without a complete sealed OpenClaw
  // inventory its preparation is unavailable before any broker/listener work.
  await expect(factory({ pluginId: "openclaw" } as any, {} as any, {} as any)).rejects.toMatchObject({ capability: "runtime", message: "The packaged OpenClaw development runtime is unavailable or its sealed inventory is invalid." });
  expect(run).toHaveBeenCalledTimes(1);
  expect(platform.catalog!().harnesses).toEqual(expect.arrayContaining([expect.objectContaining({ id: "openclaw", available: false, modes: [], capabilities: [] })]));
  fs.writeFileSync(join(f.runtime, "plugin/bootstrap.py"), "Changed after first preparation");
  await expect(factory(...args)).rejects.toMatchObject({ capability: "runtime" }); expect(run).toHaveBeenCalledTimes(1);
});

test("manifest identity, fixed paths, no-fallback claims, provenance limits and inventory digest are strict", async () => {
  const f = fixture(), original = structuredClone(f.manifest);
  const corruptions = [(m: any) => { m.productionReady = true; }, (m: any) => { m.upstream.sourceSha = "f".repeat(40); },
    (m: any) => { m.upstream.pythonTreeSha256 = "0".repeat(64); }, (m: any) => { m.paths.python = "../../private/python"; },
    (m: any) => { m.runtimeRequirements.ambientProfiles = true; }, (m: any) => { m.runtimeRequirements.subscriptionProof = true; },
    (m: any) => { m.extraAuth = "sensitive-token"; }, (m: any) => { m.inventorySha256 = "0".repeat(64); },
    (m: any) => { m.derivation.upstreamSourceModified = true; }, (m: any) => { m.inertImportProbe.certifi = "/outside/cert.pem"; },
    (m: any) => { m.derivation.nativeLoadCommandTransformations = [{ operation: "arbitrary native rewrite" }]; },
    (m: any) => { m.machODependencies[0].dependencies[0].resolved = "/usr/lib/../../private/credential"; }];
  for (const corrupt of corruptions) { Object.assign(f.manifest, structuredClone(original)); corrupt(f.manifest); f.save();
    await expect(verifyPackagedHermesArtifact(f.resources)).rejects.toMatchObject({ status: "unsupported", capability: "runtime", message: "The packaged Hermes runtime is unavailable or its sealed inventory is invalid." }); }
});

test("absolute/traversing/duplicate/overlapping inventory rows and escaping link chains are refused", async () => {
  const f = fixture(), original = structuredClone(f.manifest.files);
  for (const name of ["/private/credential", "../outside", "source/../outside", "source//file", "source\\file"]) {
    f.manifest.files = [...structuredClone(original), { path: name, sha256: "a".repeat(64), mode: 420 }]; f.reseal();
    await expect(verifyPackagedHermesArtifact(f.resources)).rejects.toMatchObject({ capability: "runtime" });
  }
  for (const extra of [original[0], { path: "source", sha256: "a".repeat(64), mode: 420 }, { path: "plugin/borrow", link: "../../../private" }]) {
    f.manifest.files = [...structuredClone(original), extra]; f.reseal(); await expect(verifyPackagedHermesArtifact(f.resources)).rejects.toThrow();
  }
  f.manifest.files = original; f.reseal();
  fs.unlinkSync(join(f.runtime, "python/bin/python3")); fs.symlinkSync("../../../outside", join(f.runtime, "python/bin/python3"));
  await expect(verifyPackagedHermesArtifact(f.resources)).rejects.toThrow();
});

test("unlisted/missing files, modes, hard links and symlinked manifest/root are refused", async () => {
  const f = fixture(), path = join(f.runtime, "plugin/adapter.mjs");
  fs.writeFileSync(join(f.runtime, "unsealed.txt"), "Extra"); await expect(verifyPackagedHermesArtifact(f.resources)).rejects.toThrow(); fs.unlinkSync(join(f.runtime, "unsealed.txt"));
  fs.chmodSync(path, 0o755); await expect(verifyPackagedHermesArtifact(f.resources)).rejects.toThrow(); fs.chmodSync(path, 0o644);
  fs.linkSync(path, join(f.root, "hard-linked-code")); await expect(verifyPackagedHermesArtifact(f.resources)).rejects.toThrow(); fs.unlinkSync(join(f.root, "hard-linked-code"));
  const manifest = join(f.runtime, "runtime-artifact.json"); fs.renameSync(manifest, join(f.root, "manifest")); fs.symlinkSync(join(f.root, "manifest"), manifest);
  await expect(verifyPackagedHermesArtifact(f.resources)).rejects.toThrow(); fs.unlinkSync(manifest); fs.renameSync(join(f.root, "manifest"), manifest);
  const source = join(f.runtime, "source"); fs.renameSync(source, join(f.root, "moved-source")); fs.symlinkSync(join(f.root, "moved-source"), source);
  await expect(verifyPackagedHermesArtifact(f.resources)).rejects.toThrow(); fs.unlinkSync(source); fs.renameSync(join(f.root, "moved-source"), source);
  fs.unlinkSync(path); await expect(verifyPackagedHermesArtifact(f.resources)).rejects.toThrow();
  const alias = join(f.root, "Resources-alias"); fs.symlinkSync(f.resources, alias); await expect(verifyPackagedHermesArtifact(alias)).rejects.toThrow();
});

test("oversized/corrupt manifests and unsupported caller fields produce generic errors without tokens or paths", async () => {
  const f = fixture();
  for (const contents of ["private-token: invalid JSON", " ".repeat(8 * 1024 * 1024 + 1)]) {
    fs.writeFileSync(join(f.runtime, "runtime-artifact.json"), contents);
    try { await verifyPackagedHermesArtifact(f.resources); throw new Error("Expected refusal"); }
    catch (e) { expect(e).toBeInstanceOf(curated.CuratedRuntimeUnavailable); expect(String(e)).not.toContain("private-token"); expect(String(e)).not.toContain(f.root); }
  }
  for (const root of ["relative/Resources", f.resources + "/../Resources", f.resources + "\n"]) expect(() => packagedPersonAgentPlatform(root, { selectBroker: () => undefined })).toThrow();
  expect(() => packagedPersonAgentPlatform(f.resources, { selectBroker: () => undefined, python: "/caller/python" } as any)).toThrow();
  expect(() => packagedPersonAgentPlatform(f.resources, {} as any)).toThrow();
});

test("underlying factory errors preserve unsupported category and redact records, tokens and paths", async () => {
  const f = fixture(), store = new PersonAgentStore(join(f.root, "state"));
  const run = vi.fn(async () => { throw new Error(`private-token credential record ${f.root}`); });
  vi.spyOn(curated, "createCuratedAgentRuntimeFactory").mockReturnValue(run);
  const factory = packagedPersonAgentPlatform(f.resources, { selectBroker: () => undefined }).createFactory(store);
  for (const error of [new Error(`private-token credential record ${f.root}`), new curated.CuratedRuntimeUnavailable("auth", "private-token credential record")]) {
    run.mockImplementation(async () => { throw error; });
    try { await factory({ pluginId: "hermes" } as any, {} as any, {} as any); throw new Error("Expected refusal"); }
    catch (e) { expect(e).toBeInstanceOf(curated.CuratedRuntimeUnavailable); expect(String(e)).not.toContain("private-token"); expect(String(e)).not.toContain(f.root);
      expect((e as curated.CuratedRuntimeUnavailable).capability).toBe(error instanceof curated.CuratedRuntimeUnavailable ? "auth" : "runtime"); }
  }
});
