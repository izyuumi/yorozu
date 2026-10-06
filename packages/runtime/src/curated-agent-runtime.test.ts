/** Actual pinned source/interpreter reads, synthetic broker records; no inference/network/Gateway. */
import { afterEach, expect, test as defineTest, vi } from "vitest";
import { cpSync, chmodSync, existsSync, mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import * as listenerApi from "./agent-listener.js";
import { fileURLToPath } from "node:url";
import { createHash, randomBytes } from "node:crypto";
import { PersonAgentStore } from "./agent-store.js";
import { createCuratedAgentRuntimeFactory, HERMES_RUNTIME_PIN, OPENCLAW_RUNTIME_PIN, type CuratedAgentRuntimeConfiguration, type SelectedAgentBroker } from "./curated-agent-runtime.js";
import type { PersonAgentExecution } from "./person-agent-runtime.js";

const TASK = "/Users/yumi/Documents/Codex/2026-10-04/task-5";
const NODE = join(TASK, "tools/mise/installs/node/26.10.0/bin/node");
const SOURCE = join(TASK, "upstream-hermes"), PYTHON = join(SOURCE, ".venv/bin/python");
const ADAPTER = fileURLToPath(new URL("../../harness-plugins/hermes/adapter.mjs", import.meta.url));
// These integration fixtures inspect the real pinned source/interpreters. CI
// without the explicitly prepared public runtime reports a skip, never a proof.
const test = defineTest.skipIf(!existsSync(NODE) || !existsSync(PYTHON) || !existsSync(SOURCE));
vi.setConfig({ testTimeout: 30_000 });
const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); vi.unstubAllEnvs(); vi.restoreAllMocks(); });
function fixture(allowedTools: string[] = ["file", "delegation", "team", "memory"]) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-curated-runtime-"))); roots.push(root);
  const state = join(root, "state"), shared = join(root, "shared"); mkdirSync(shared);
  const store = new PersonAgentStore(state, { resourceRoots: [{ path: shared, access: "write" }] });
  let r = store.create({ id: "alice", name: "Alice", role: "ROLE_IS_REFERENCE_ONLY", pluginId: "hermes", model: "proof-model", accountBindingId: "explicit-host-binding", allowedTools, directories: [{ path: shared, access: "write" }] }, 0);
  r = store.create({ id: "bob", name: "Bob", role: "Worker", pluginId: "hermes", model: "proof-model", accountBindingId: "explicit-bob-binding", allowedTools, directories: [{ path: shared, access: "read" }] }, r.revision);
  store.createTeam({ id: "team", name: "Office", agentIds: ["alice", "bob"] }, r.revision);
  const agent = store.list().agents[0], scope = store.resolveScope(agent.id), id = "a".repeat(64), scratchRoot = join(root, "scratch", id); mkdirSync(scratchRoot, { recursive: true, mode: 0o700 });
  const execution: PersonAgentExecution = { kind: "ordinary", id, scratchRoot, workspace: agent.workspace, memoryDir: agent.memoryDir };
  const selected: SelectedAgentBroker = { kind: "host-inference-broker-v1", agentId: agent.id, executionId: id, accountBindingId: agent.accountBindingId,
    host: "127.0.0.1", port: 53717, model: "proof-model", bearer: randomBytes(32).toString("hex") };
  const config: CuratedAgentRuntimeConfiguration = { node: { executable: NODE, version: "26.10.0" },
    hermes: { ...HERMES_RUNTIME_PIN, source: SOURCE, adapter: ADAPTER, python: { executable: PYTHON, canonicalExecutable: realpathSync(PYTHON), version: "3.13.16",
      venvRoot: join(SOURCE, ".venv"), libraryRoots: [join(TASK, "tools/mise/installs/python/3.13.16/lib")] } },
    selectBroker: () => selected, terminalBinaries: ["/bin/cat"] };
  return { root, shared, store, agent, scope, execution, selected, config };
}

test("explicit pinned Hermes uses private bearer bootstrap and exact broker authority without ambient credentials", async () => {
  const f = fixture(); vi.stubEnv("OPENAI_API_KEY", "AMBIENT_TOKEN_MUST_NOT_APPEAR"); vi.stubEnv("CODEX_HOME", "/ambient/forbidden");
  const originalIndex = readFileSync(join(SOURCE, ".git/index"));
  const factory = createCuratedAgentRuntimeFactory(f.store, f.config), result = await factory(f.agent, f.scope, f.execution);
  expect(createHash("sha256").update(readFileSync(join(SOURCE, ".git/index"))).digest("hex"))
    .toBe(createHash("sha256").update(originalIndex).digest("hex"));
  expect(result.configuration).toMatchObject({ pluginId: "hermes", command: NODE, args: [ADAPTER], upstreamVersion: "0.21.5", initialize: { python: PYTHON, sourcePath: SOURCE, model: "proof-model", provider: "custom:yorozu-local-proof" } });
  expect(result.runtime.brokerPorts).toEqual([53717]); expect(result.runtime.inheritedListeners).toBeUndefined(); expect((result.runtime as any).listenerPorts).toBeUndefined();
  expect(result.runtime.readPaths).toContain(SOURCE); expect(result.runtime.readPaths).toContain(realpathSync(PYTHON)); expect(result.runtime.readPaths).not.toContain("/bin/cat");
  const provider = result.configuration.initialize.providerConfigPath as string;
  expect(provider).toBe(join(f.execution.scratchRoot, "profile/proof-provider.json")); expect(statSync(provider).mode & 0o077).toBe(0);
  expect(JSON.parse(readFileSync(provider, "utf8"))).toEqual({ baseUrl: "http://127.0.0.1:53717/v1", model: "proof-model", bearer: f.selected.bearer, apiMode: "codex_responses" });
  expect(JSON.stringify(result)).not.toContain(f.selected.bearer); expect(JSON.stringify(result)).not.toMatch(/AMBIENT_TOKEN|ambient\/forbidden/);
});

test("restricted handoff preserves minted origin intersection and stores no teammate private history or memory", async () => {
  const f = fixture(), bob = f.store.list().agents[1];
  const delegated = f.store.delegateScope(f.scope, { allowedTools: ["file", "delegation", "team"], directories: [{ path: f.shared, access: "write" }] }, bob.id);
  const id = "b".repeat(64), scratchRoot = join(f.root, "handoff", id), workspace = join(scratchRoot, "profile/scratch"), memoryDir = join(scratchRoot, "profile/memory");
  mkdirSync(workspace, { recursive: true, mode: 0o700 }); mkdirSync(memoryDir, { mode: 0o700 });
  const execution: PersonAgentExecution = { kind: "handoff", id, scratchRoot, workspace, memoryDir };
  f.config.selectBroker = () => ({ ...f.selected, agentId: bob.id, executionId: id, accountBindingId: bob.accountBindingId, bearer: randomBytes(32).toString("hex") });
  const result = await createCuratedAgentRuntimeFactory(f.store, f.config)(bob, delegated, execution);
  expect(delegated.chain).toEqual(["alice", "bob"]); expect(delegated.directories).toEqual([{ path: f.shared, access: "read" }]);
  expect(result.runtime.readPaths).not.toContain(bob.workspace); expect(result.runtime.readPaths).not.toContain(bob.memoryDir);
  expect(result.configuration.initialize.providerConfigPath).toBe(join(scratchRoot, "profile/proof-provider.json"));
  expect(result.configuration.initialize).not.toHaveProperty("scope"); // Manager remains the authority stamper.
  const forged = structuredClone(delegated);
  await expect(createCuratedAgentRuntimeFactory(f.store, f.config)(bob, forged, execution)).rejects.toThrow("Forged or stale");
});

test("no selected broker remains auth unavailable without reading environment or installed profiles", async () => {
  const f = fixture(); f.config.selectBroker = () => undefined;
  vi.stubEnv("OPENAI_API_KEY", "must-not-enable");
  await expect(createCuratedAgentRuntimeFactory(f.store, f.config)(f.agent, f.scope, f.execution)).rejects.toMatchObject({ status: "unsupported", capability: "auth" });
});

test("wrong agent/execution/account/model/address and injected fields are refused without printing a bearer", async () => {
  const f = fixture();
  for (const patch of [{ agentId: "bob" }, { executionId: "b".repeat(64) }, { accountBindingId: "unknown-binding" }, { model: "paid-fallback" },
    { host: "localhost" }, { port: 443 }, { bearer: "weak" }, { baseUrl: "https://remote.invalid" }]) {
    f.config.selectBroker = () => ({ ...f.selected, ...patch } as SelectedAgentBroker);
    const error = await createCuratedAgentRuntimeFactory(f.store, f.config)(f.agent, f.scope, f.execution).catch(e => e);
    expect(error).toBeInstanceOf(Error); expect(error.message).not.toContain(f.selected.bearer);
  }
});

test("the same bearer cannot authenticate a second execution or persistent identity", async () => {
  const f = fixture(), factory = createCuratedAgentRuntimeFactory(f.store, f.config); await factory(f.agent, f.scope, f.execution);
  const bob = f.store.list().agents[1], scope = f.store.resolveScope(bob.id), scratchRoot = join(f.root, "bob-scratch"), id = "b".repeat(64); mkdirSync(scratchRoot, { mode: 0o700 });
  f.selected.agentId = bob.id; f.selected.executionId = id; f.selected.accountBindingId = bob.accountBindingId;
  await expect(factory(bob, scope, { kind: "ordinary", id, scratchRoot, workspace: bob.workspace, memoryDir: bob.memoryDir })).rejects.toThrow("fresh and unique");
});

test("pins, canonical code roots, Python venv ownership and unsupported tools fail closed", async () => {
  const f = fixture();
  expect(() => createCuratedAgentRuntimeFactory(f.store, { ...f.config, hermes: { ...f.config.hermes, sourceSha: "wrong" } })).toThrow("pin");
  f.config.node.version = "26.10.0"; f.config.hermes.python.version = "3.12.1";
  await expect(createCuratedAgentRuntimeFactory(f.store, f.config)(f.agent, f.scope, f.execution)).rejects.toThrow("Python version");
  f.config.hermes.python.version = "3.13.16";
  const link = join(f.root, "adapter-link.mjs"); symlinkSync(ADAPTER, link); f.config.hermes.adapter = link;
  await expect(createCuratedAgentRuntimeFactory(f.store, f.config)(f.agent, f.scope, f.execution)).rejects.toThrow("canonical");
  const w = fixture(["web"]);
  await expect(createCuratedAgentRuntimeFactory(w.store, w.config)(w.agent, w.scope, w.execution)).rejects.toThrow("separately verified host broker");
});

test("code grants cannot include agent state, writable resources, or old unowned provider bootstraps", async () => {
  const f = fixture(); f.config.node.libraryRoots = [f.agent.memoryDir];
  await expect(createCuratedAgentRuntimeFactory(f.store, f.config)(f.agent, f.scope, f.execution)).rejects.toThrow("private state");
  f.config.node.libraryRoots = [f.shared];
  await expect(createCuratedAgentRuntimeFactory(f.store, f.config)(f.agent, f.scope, f.execution)).rejects.toThrow("writable resources");
  f.config.node.libraryRoots = [];
  mkdirSync(join(f.execution.scratchRoot, "profile"), { mode: 0o700 }); writeFileSync(join(f.execution.scratchRoot, "profile/proof-provider.json"), "{}", { mode: 0o600 });
  await expect(createCuratedAgentRuntimeFactory(f.store, f.config)(f.agent, f.scope, f.execution)).rejects.toThrow("cannot be adopted");
});


test("terminal code roots are explicit and included only for a granted native terminal tool", async () => {
  const f = fixture(["terminal"]);
  const result = await createCuratedAgentRuntimeFactory(f.store, f.config)(f.agent, f.scope, f.execution);
  expect(result.runtime.readPaths).toContain("/bin/cat"); expect(result.runtime.brokerPorts).toEqual([f.selected.port]);
  expect(result.configuration.initialize).not.toHaveProperty("environment"); expect(result.configuration.initialize).not.toHaveProperty("fallback");
});

test("OpenClaw rejects unsupported scopes and wrong curated source before acquiring any listener", async () => {
  const f = fixture([]), acquire = vi.spyOn(listenerApi, "acquireHostListener").mockRejectedValue(new Error("must never bind"));
  f.store.update("alice", { pluginId: "openclaw" }, f.store.list().revision);
  const agent = f.store.list().agents[0], scope = f.store.resolveScope(agent.id);
  f.config.openclaw = { version: "2026.9.8", sourceSha: OPENCLAW_RUNTIME_PIN.sourceSha, source: SOURCE,
    adapter: fileURLToPath(new URL("../../harness-plugins/openclaw/adapter.mjs", import.meta.url)) };
  await expect(createCuratedAgentRuntimeFactory(f.store, f.config)(agent, scope, { ...f.execution, workspace: agent.workspace, memoryDir: agent.memoryDir })).rejects.toThrow("approved commit");
  expect(acquire).not.toHaveBeenCalled();
  expect(() => createCuratedAgentRuntimeFactory(f.store, { ...f.config, openclaw: { ...f.config.openclaw!, sourceSha: "9bbdbaec153dd28fb452e6652c3dcacd829cb00f" as any } })).toThrow("Unsupported curated runtime pin");
  expect(() => createCuratedAgentRuntimeFactory(f.store, { ...f.config, openclaw: { ...f.config.openclaw!, sourceIntegrity: "trust-me" as any } })).toThrow("source integrity");
  f.store.update("alice", { allowedTools: ["file"] }, f.store.list().revision);
  const withTools = f.store.list().agents[0];
  await expect(createCuratedAgentRuntimeFactory(f.store, f.config)(withTools, f.store.resolveScope("alice"), f.execution)).rejects.toThrow("chat and uniform memory only");
  expect(acquire).not.toHaveBeenCalled();
  // Uniform memory is the one accepted OpenClaw resource tool; the pinned-source check
  // still runs before any broker selection or listener acquisition.
  f.store.update("alice", { allowedTools: ["memory"] }, f.store.list().revision);
  const withMemory = f.store.list().agents[0];
  await expect(createCuratedAgentRuntimeFactory(f.store, f.config)(withMemory, f.store.resolveScope("alice"), f.execution)).rejects.toThrow("approved commit");
  expect(acquire).not.toHaveBeenCalled();
});


test("broker-selector failures cannot expose a secret or select a fallback provider", async () => {
  const f = fixture(); f.config.selectBroker = () => { throw new Error(f.selected.bearer); };
  const error = await createCuratedAgentRuntimeFactory(f.store, f.config)(f.agent, f.scope, f.execution).catch(e => e);
  expect(error).toMatchObject({ status: "unsupported", capability: "auth" }); expect(error.message).not.toContain(f.selected.bearer);
});

defineTest("host sealed source rejects fabricated commit metadata and source/.git symlinks without invoking Git", async () => {
  const { verifySealedHermesSource } = await import("./curated-agent-runtime.js");
  const root = realpathSync(mkdtempSync(join(tmpdir(), "sealed-host-negative-"))); roots.push(root);
  const source = join(root, "source"); mkdirSync(join(source, ".git"), { recursive: true });
  writeFileSync(join(source, ".git/HEAD"), HERMES_RUNTIME_PIN.sourceSha + "\n");
  writeFileSync(join(source, "pyproject.toml"), 'version = "0.21.5"\n');
  await expect(verifySealedHermesSource(source)).rejects.toThrow("integrity");
  symlinkSync(source, join(root, "alias"));
  await expect(verifySealedHermesSource(join(root, "alias"))).rejects.toThrow("integrity");
  rmSync(join(source, ".git"), { recursive: true }); symlinkSync(root, join(source, ".git"));
  await expect(verifySealedHermesSource(source)).rejects.toThrow("integrity");
});

defineTest.skipIf(!process.env.YOROZU_HERMES_SEALED_TEST_SOURCE)("host independently verifies the assembled sealed export and binds the same root as the child", async () => {
  const { verifySealedHermesSource, SEALED_HERMES_SOURCE_SHA256 } = await import("./curated-agent-runtime.js");
  const adapter = readFileSync(ADAPTER, "utf8");
  expect(adapter).toContain(`export const SEALED_HERMES_SOURCE_SHA256 = "${SEALED_HERMES_SOURCE_SHA256}"`);
  const root = realpathSync(mkdtempSync(join(tmpdir(), "sealed-host-tamper-"))); roots.push(root);
  const source = join(root, "source"); cpSync(process.env.YOROZU_HERMES_SEALED_TEST_SOURCE!, source, { recursive: true });
  await verifySealedHermesSource(source);
  for (const name of ["pyproject.toml", ".git/HEAD", ".git/index"]) {
    const path = join(source, name), original = readFileSync(path);
    writeFileSync(path, Buffer.concat([original, Buffer.from("tamper")]));
    await expect(verifySealedHermesSource(source)).rejects.toThrow("integrity"); writeFileSync(path, original);
  }
  writeFileSync(join(source, "unsealed.py"), "malicious=True");
  await expect(verifySealedHermesSource(source)).rejects.toThrow("integrity"); rmSync(join(source, "unsealed.py"));
  chmodSync(join(source, "pyproject.toml"), 0o666);
  await expect(verifySealedHermesSource(source)).rejects.toThrow("integrity"); chmodSync(join(source, "pyproject.toml"), 0o644);
  await verifySealedHermesSource(source);
});
