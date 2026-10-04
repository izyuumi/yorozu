/** Persistent people own ordinary sessions; restricted handoffs own fresh execution instances. */
import { randomUUID } from "node:crypto";
import { closeSync, constants, existsSync, fstatSync, fsyncSync, mkdirSync, openSync, readFileSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ThreadSummary, YorozuEvent } from "@yorozu/shared";
import type { NativeTurnResult } from "./native.js";
import { PersonAgentStore, type PersonAgent, type PersonAgentInput, type AgentRegistry } from "./agent-store.js";
import { normalizeDirectoryGrants, pathWithin, safeAgentPath, validAgentId, validateKnowledgeIds, validateTools, type EffectiveAgentScope, type ScopeSelection } from "./agent-scope.js";
import { releaseHostListener, validateHostListeners } from "./agent-listener.js";
import { isolatedAgentLaunch, type AgentIsolationRuntime } from "./agent-isolation.js";
import { HarnessProcess, type SupervisedHarnessConfiguration } from "./harness-process.js";
import { harnessDigest } from "./harness-ledger.js";
import type { HarnessConfiguration } from "./harness-contract.js";
import { SecretaryHarness, type HarnessServices, type HarnessHandoffIdentity, type HarnessHandoffInput, type HarnessHandoffResult } from "./harness-runner.js";
import { appendThreadEvent, readThreadEvents, setNativeTurn } from "./threads.js";
import { retainSharedSyncHost } from "./rust-sync.js";

export interface PersonAgentExecution {
  kind: "ordinary" | "handoff"; id: string; scratchRoot: string; workspace: string; memoryDir: string;
}
/** Trusted host code supplies pinned interpreters/adapters and exact broker ports.
 * This factory is never invoked with model-selected code, environment, or profile paths.
 */
export type PersonAgentRuntimeFactory = (agent: PersonAgent, scope: EffectiveAgentScope, execution: PersonAgentExecution) =>
  Promise<{ configuration: HarnessConfiguration; runtime: AgentIsolationRuntime }> | { configuration: HarnessConfiguration; runtime: AgentIsolationRuntime };
interface Binding { agentId: string; title: string; epochs: string[] }
interface Instance { agentId: string; chain: string[]; conversationId: string; epoch: string; state: "preparing" | "running" | "completed" | "failed" | "unknown"; result?: HarnessHandoffResult }
interface Manifest { version: 1; bindings: Record<string, Binding>; taskOwners: Record<string, string>; holds: Record<string, string>; instances: Record<string, Instance> }
interface Actor { agent: PersonAgent; scope: EffectiveAgentScope; signature: string; execution: PersonAgentExecution; configuration: SupervisedHarnessConfiguration; process: HarnessProcess; owners: Set<string> }
interface Owner { harness: SecretaryHarness; actor: Actor; epoch: string; transient: boolean }
const owned = new Set<string>();
const MAX_OWNERS = 4, MAX_HANDOFFS = 2, MAX_MANIFEST_BYTES = 2 * 1024 * 1024;
const empty = (): Manifest => ({ version: 1, bindings: {}, taskOwners: {}, holds: {}, instances: {} });
const record = (v: unknown): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v);
const threadId = (v: unknown): v is string => typeof v === "string" && /^[\w.-]{1,128}$/.test(v);
const hash = (v: unknown): v is string => typeof v === "string" && /^[a-f0-9]{64}$/.test(v);
function readObject(path: string, limit: number): any | undefined {
  safeAgentPath(path);
  let fd: number;
  try { fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
  catch (e) { if ((e as NodeJS.ErrnoException).code === "ENOENT") return; throw e; }
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.nlink !== 1 || stat.size > limit) throw new Error("Invalid agent runtime journal");
    return JSON.parse(readFileSync(fd, "utf8"));
  } finally { closeSync(fd); }
}
function writeObject(path: string, value: unknown): void {
  safeAgentPath(path); const encoded = JSON.stringify(value) + "\n";
  if (Buffer.byteLength(encoded) > MAX_MANIFEST_BYTES) throw new Error("Agent runtime journal budget exceeded");
  const tmp = path + "." + randomUUID();
  const fd = openSync(tmp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try { writeFileSync(fd, encoded); fsyncSync(fd); } finally { closeSync(fd); }
  renameSync(tmp, path);
  const parent = openSync(join(path, ".."), constants.O_RDONLY | constants.O_NOFOLLOW);
  try { fsyncSync(parent); } finally { closeSync(parent); }
}
function unsettled(path: string): boolean {
  const s = readObject(path, 16 * 1024 * 1024);
  if (!s) return false;
  if (s.version !== 1 || !record(s.runs) || !record(s.tasks) || !record(s.controls) || !record(s.autonomous) || !record(s.pendingResults))
    throw new Error("Damaged prior agent execution; refusing a new binding");
  for (const [values, states] of [[s.runs, ["sending", "running", "completed", "failed", "stopped", "unknown"]],
    [s.tasks, ["running", "waiting", "stopping", "completed", "failed", "stopped", "unknown"]],
    [s.controls, ["sending", "queued", "requested", "rejected", "unsupported", "unknown"]],
    [s.autonomous, ["running", "completed", "failed", "stopped", "unknown"]]] as const)
    if (Object.values(values).some(v => !record(v) || !states.includes(v.state))) throw new Error("Damaged prior agent execution state");
  return Object.values(s.runs).some((v: any) => ["sending", "running", "unknown"].includes(v.state))
    || Object.values(s.tasks).some((v: any) => ["running", "waiting", "stopping", "unknown"].includes(v.state))
    || Object.values(s.controls).some((v: any) => ["sending", "unknown"].includes(v.state))
    || Object.values(s.autonomous).some((v: any) => ["running", "unknown"].includes(v.state)) || Object.keys(s.pendingResults).length > 0;
}
function validateManifest(s: any): Manifest {
  if (!record(s) || Object.keys(s).some(k => !["version", "bindings", "taskOwners", "holds", "instances"].includes(k)) || s.version !== 1
    || !record(s.bindings) || !record(s.taskOwners) || !record(s.holds) || !record(s.instances)
    || Object.keys(s.bindings).length > 512 || Object.keys(s.taskOwners).length > 2048 || Object.keys(s.instances).length > 512) throw new Error("Damaged agent runtime journal");
  for (const [id, b] of Object.entries(s.bindings) as [string, Binding][]) if (!threadId(id) || !record(b) || !validAgentId(b.agentId)
    || typeof b.title !== "string" || b.title.length > 200 || !Array.isArray(b.epochs) || b.epochs.length > 64 || b.epochs.some(e => !hash(e))
    || Object.keys(b).some(k => !["agentId", "title", "epochs"].includes(k))) throw new Error("Damaged conversation ownership");
  for (const [task, owner] of Object.entries(s.taskOwners)) if (!threadId(task) || !threadId(owner) || !s.bindings[owner]) throw new Error("Damaged task ownership");
  for (const [id, reason] of Object.entries(s.holds)) if (!validAgentId(id) || typeof reason !== "string" || reason.length > 2000) throw new Error("Damaged agent hold");
  for (const [id, v] of Object.entries(s.instances) as [string, Instance][]) if (!hash(id) || !record(v) || !validAgentId(v.agentId) || !threadId(v.conversationId) || !hash(v.epoch)
    || !Array.isArray(v.chain) || !v.chain.length || v.chain.length > 8 || v.chain.some(a => !validAgentId(a)) || v.chain.at(-1) !== v.agentId
    || !["preparing", "running", "completed", "failed", "unknown"].includes(v.state)
    || v.result !== undefined && (!record(v.result) || !["completed", "failed", "unknown", "rejected"].includes(v.result.status)
      || v.result.text !== undefined && (typeof v.result.text !== "string" || v.result.text.length > 32_768))) throw new Error("Damaged handoff ownership");
  return s as unknown as Manifest;
}

/** Host-owned manager. All admission and handoff authority comes from PersonAgentStore.
 * No daemon respawn, crash replay, profile adoption, or switch around unknown work.
 */
export class PersonAgentRuntime {
  readonly root: string;
  private readonly file: string;
  private readonly release: () => void;
  private readonly manifest: Manifest;
  private services?: HarnessServices;
  private actors = new Map<string, Actor>();
  private owners = new Map<string, Owner>();
  private operations: Promise<unknown> = Promise.resolve();
  private activeHandoffs = new Set<string>();
  private handoffPromises = new Map<string, Promise<HarnessHandoffResult>>();
  private closing = false;
  constructor(readonly dir: string, readonly store: PersonAgentStore, readonly factory: PersonAgentRuntimeFactory) {
    this.root = safeAgentPath(join(dir, "person-agent-runtime-v1")); mkdirSync(this.root, { recursive: true, mode: 0o700 });
    if (owned.has(this.root)) throw new Error("Person agent runtime already owned");
    this.release = retainSharedSyncHost(join(this.root, "lease")); owned.add(this.root); this.file = join(this.root, "manifest.json");
    try {
      this.manifest = validateManifest(readObject(this.file, MAX_MANIFEST_BYTES) ?? empty());
      for (const v of Object.values(this.manifest.instances)) if (["preparing", "running", "unknown"].includes(v.state)) {
        v.state = "unknown"; this.hold(v.chain, "Prior delegated execution is unconfirmed; no automatic replay");
      }
      for (const [id, b] of Object.entries(this.manifest.bindings)) if (b.epochs.some(e => unsettled(this.ledgerFile(id, e))))
        this.hold([b.agentId], "Prior agent execution or result delivery is unconfirmed");
      this.save();
    } catch (e) { owned.delete(this.root); this.release(); throw e; }
  }
  bind(services: HarnessServices): void { this.services = services; for (const [id, o] of this.owners) this.bindOwner(id, o); }
  private save(): void { writeObject(this.file, this.manifest); }
  private hold(ids: string[], reason: string): void { for (const id of ids) this.manifest.holds[id] = reason.slice(0, 2000); }
  held(agentId: string): string | undefined { this.refresh(); return this.manifest.holds[agentId]; }
  private ledgerDir(id: string, epoch: string): string { return join(this.root, "ledgers", harnessDigest(id), epoch); }
  private ledgerFile(id: string, epoch: string): string { return join(this.ledgerDir(id, epoch), "harness-v1", "binding.json"); }
  private signature(agent: PersonAgent, scope: EffectiveAgentScope): string { return harnessDigest({ agent, scope }); }
  private serialized<T>(fn: () => Promise<T>): Promise<T> {
    const p = this.operations.then(fn); this.operations = p.catch(() => {}); return p;
  }
  private refresh(): void {
    let changed = false;
    for (const o of this.owners.values()) if (o.harness.hasUnconfirmedExecution) {
      for (const id of o.actor.scope.chain) if (!this.manifest.holds[id]) { this.hold([id], "An owned execution or control has an unconfirmed outcome"); changed = true; }
    }
    if (changed) this.save();
  }
  private admission(actor: Actor): void {
    this.refresh();
    if (this.closing || actor.process.unavailable) throw new Error("Owned process unavailable; no implicit restart");
    if (actor.scope.chain.some(id => this.manifest.holds[id])) throw new Error("Agent execution remains held until its unknown outcome is resolved");
    const current = this.store.resolveScope(actor.agent.id);
    if (current.revision !== actor.scope.revision || harnessDigest(this.agent(actor.agent.id)) !== harnessDigest(actor.agent))
      throw new Error("Agent settings changed; a confirmed idle switch is required");
  }
  private agent(id: string): PersonAgent {
    const agent = this.store.list().agents.find(a => a.id === id); if (!agent) throw new Error("Unknown persistent agent"); return agent;
  }
  private idle(agentId: string): boolean {
    return !this.manifest.holds[agentId] && ![...this.owners.values()].some(o => o.actor.scope.chain.includes(agentId) && !o.harness.idleConfirmed)
      && ![...this.activeHandoffs].some(id => this.manifest.instances[id].chain.includes(agentId));
  }
  private bindOwner(id: string, owner: Owner): void {
    owner.harness.bind({ emit: event => {
      if (event.threadId !== id) {
        if (!owner.harness.owns(event.threadId)) throw new Error("Unowned task projection");
        if (Object.keys(this.manifest.taskOwners).length >= 2048 && !this.manifest.taskOwners[event.threadId]) throw new Error("Task ownership budget exceeded");
        this.manifest.taskOwners[event.threadId] = id; this.save();
      }
      if (this.services) this.services.emit(event); else appendThreadEvent(event, this.dir);
    }, changed: () => { this.refresh(); this.services?.changed(); },
    preferences: () => {
      const knowledge = this.store.knowledgeFor(owner.actor.agent.id, owner.actor.scope).filter(e => !owner.transient || e.kind === "shared-knowledge");
      return { revision: String(this.store.journal().revision), text: JSON.stringify({ role: owner.actor.agent.role, reference: knowledge.map(e => ({ kind: e.kind, text: e.text })) }) };
    }, handoff: (identity, input, signal) => this.handoff(owner, identity, input, signal) });
  }
  private async room(): Promise<void> {
    if (this.owners.size < MAX_OWNERS) return;
    const retired = [...this.owners].find(([, o]) => !o.transient && o.harness.idleConfirmed);
    if (!retired) throw new Error("Active conversation owner budget exceeded; no execution was admitted");
    await retired[1].harness.close(); this.owners.delete(retired[0]); retired[1].actor.owners.delete(retired[0]);
  }
  private async prepare(agent: PersonAgent, scope: EffectiveAgentScope, kind: "ordinary" | "handoff", id: string): Promise<Actor> {
    const scratchRoot = safeAgentPath(join(this.root, "scratch", agent.id, id)); mkdirSync(scratchRoot, { recursive: true, mode: 0o700 });
    const markerPath = join(scratchRoot, "owner.json"), expected = { version: 1, agentId: agent.id, kind, id };
    const prior = readObject(markerPath, 4096);
    if (prior && JSON.stringify(prior) !== JSON.stringify(expected)) throw new Error("Vendor scratch has another owner");
    if (!prior) {
      // The host allocates this directory. No caller supplies an existing profile.
      if (existsSync(join(scratchRoot, "profile"))) throw new Error("Refusing to adopt an unowned vendor profile");
      writeObject(markerPath, expected);
    }
    const execution: PersonAgentExecution = { kind, id, scratchRoot, workspace: kind === "ordinary" ? agent.workspace : join(scratchRoot, "workspace"),
      memoryDir: kind === "ordinary" ? agent.memoryDir : join(scratchRoot, "memory") };
    for (const path of [execution.workspace, execution.memoryDir]) { safeAgentPath(path); mkdirSync(path, { recursive: true, mode: 0o700 }); }
    const scratchBase = join(this.root, "scratch");
    const overlaps = (a: string, b: string): boolean => pathWithin(a, b) || pathWithin(b, a);
    // Runtime profiles are private state, including another instance of the same
    // person. Shared resources must never turn vendor scratch into task authority.
    if (scope.directories.some(g => overlaps(g.path, scratchBase))) throw new Error("Resource scope enters private vendor scratch");
    const built = await this.factory(structuredClone(agent), scope, Object.freeze(execution));
    try {
      if (built.runtime.readPaths.some(p => overlaps(safeAgentPath(p, true), scratchBase))) throw new Error("Code roots enter private vendor scratch");
      if (built.configuration.pluginId !== agent.pluginId || built.runtime.runtimeDir !== scratchRoot) throw new Error("Factory returned another agent's plugin or scratch");
      const initialize = { ...built.configuration.initialize };
      if (initialize.gatewayListener !== undefined) throw new Error("Factory may supply a live lease, never raw Gateway descriptors");
      if (initialize.providerConfigPath !== undefined && (typeof initialize.providerConfigPath !== "string" || !pathWithin(scratchRoot, safeAgentPath(initialize.providerConfigPath, true))))
        throw new Error("Provider bootstrap must be explicitly prepared in fresh owned scratch");
      // Built-in vendor memory is forbidden in restricted teammate instances. Selected
      // shared knowledge may be projected by the host, without granting a private file root.
      const tools = scope.allowedTools.filter(t => kind === "ordinary" || t !== "memory");
      const siblingScratch = this.store.list().agents.filter(a => a.id !== agent.id).map(a => join(scratchBase, a.id));
      for (const name of readdirSync(join(scratchBase, agent.id))) {
        const sibling = safeAgentPath(join(scratchBase, agent.id, name), true);
        if (sibling !== scratchRoot) siblingScratch.push(sibling);
      }
      const deniedRoots = [...new Set([...scope.deniedRoots, ...siblingScratch, join(this.root, "ledgers"), this.file, join(this.root, "lease"),
        join(this.dir, "threads"), join(this.dir, "threads.json")])];
      const osScope = { ...scope, deniedRoots };
      const launch = isolatedAgentLaunch(osScope, built.runtime);
      const scoped = { allowedTools: tools, directories: scope.directories.map(g => ({ ...g })), workspace: execution.workspace, memoryDir: execution.memoryDir,
        ...(agent.pluginId === "openclaw" ? { deniedRoots } : {}) };
      const configuration: SupervisedHarnessConfiguration = { ...built.configuration, command: launch.command, args: launch.args, inheritedListeners: built.runtime.inheritedListeners,
        initialize: { ...initialize, agentId: agent.id, workspace: execution.workspace, model: agent.model,
          scope: scoped, isolation: launch.isolation, platform: { team: tools.includes("team"), computer: false },
          ...(agent.pluginId === "hermes" ? { profileRoot: join(scratchRoot, "profile") } : { profileDir: join(scratchRoot, "profile") }) } };
      return { agent, scope, signature: this.signature(agent, scope), execution, configuration, process: new HarnessProcess(configuration), owners: new Set() };
    } catch (error) {
      let held = [] as ReturnType<typeof validateHostListeners>;
      try { held = validateHostListeners(built?.runtime?.inheritedListeners ?? [], agent.id); } catch { /* Unowned handles stay with their original host. */ }
      await Promise.all(held.map(releaseHostListener)); throw error;
    }
  }
  /** Bind a new ordinary chat, or reopen its immutable agent binding. */
  conversation(id: string, agentId?: string, title = "Conversation"): Promise<SecretaryHarness> {
    return this.serialized(async () => {
      if (this.closing || !threadId(id) || typeof title !== "string" || title.length > 200) throw new Error("Invalid owned conversation");
      const previous = this.manifest.bindings[id]; const selected = agentId ?? previous?.agentId ?? this.store.list().defaultAgentId;
      if (!selected || previous && previous.agentId !== selected || this.manifest.taskOwners[id]) throw new Error("Conversation agent identity is immutable");
      const agent = this.agent(selected), scope = this.store.resolveScope(selected), signature = this.signature(agent, scope);
      this.refresh(); if (this.manifest.holds[selected]) throw new Error(this.manifest.holds[selected]);
      const existing = this.owners.get(id);
      if (existing && existing.actor.signature === signature) { this.admission(existing.actor); return existing.harness; }
      let actor = this.actors.get(selected);
      if (actor && actor.signature !== signature) {
        if (!this.idle(selected)) throw new Error("Agent settings switch requires all owned execution to be confirmed idle");
        // Validate the candidate before disturbing the selected idle owner.
        const candidate = await this.prepare(agent, scope, "ordinary", signature);
        for (const ownerId of [...actor.owners]) { await this.owners.get(ownerId)!.harness.close(); this.owners.delete(ownerId); }
        await actor.process.close(); this.actors.set(selected, candidate); actor = candidate;
      }
      if (actor?.process.unavailable) throw new Error("Agent daemon exited; no implicit respawn");
      if (!actor) { actor = await this.prepare(agent, scope, "ordinary", signature); this.actors.set(selected, actor); }
      await this.room();
      const binding = previous ?? { agentId: selected, title, epochs: [] };
      if (Object.keys(this.manifest.bindings).length >= 512 && !previous || binding.epochs.length >= 64 && !binding.epochs.includes(signature)) throw new Error("Conversation binding budget exceeded");
      this.manifest.bindings[id] = binding; if (!binding.epochs.includes(signature)) binding.epochs.push(signature); this.save();
      const harness = new SecretaryHarness(this.dir, actor.configuration, { conversationId: id, workspace: agent.workspace,
        title: binding.title, ledgerDir: this.ledgerDir(id, signature), sharedProcess: actor.process, beforeAdmission: () => this.admission(actor!) });
      const owner = { harness, actor, epoch: signature, transient: false }; this.owners.set(id, owner); actor.owners.add(id); this.bindOwner(id, owner);
      return harness;
    });
  }
  /** UI/task routing is ownership based, never a "latest run" lookup. */
  async owner(id: string): Promise<SecretaryHarness | undefined> {
    const conversation = this.manifest.taskOwners[id] ?? id;
    if (!this.manifest.bindings[conversation]) return;
    if (this.manifest.instances[Object.keys(this.manifest.instances).find(k => this.manifest.instances[k].conversationId === conversation) ?? ""])
      return this.owners.get(conversation)?.harness.owns(id) ? this.owners.get(conversation)!.harness : undefined;
    const harness = await this.conversation(conversation); return harness.owns(id) ? harness : undefined;
  }
  summary(id: string): Partial<ThreadSummary> | undefined {
    const conversation = this.manifest.taskOwners[id] ?? id; return this.owners.get(conversation)?.harness.summary(id);
  }
  async taskStop(event: YorozuEvent): Promise<boolean> { return await (await this.owner(event.threadId))?.taskStop(event) ?? false; }
  /** Trusted settings operation. History and prior binding evidence remain in place. */
  configure(id: string, patch: Partial<Omit<PersonAgentInput, "id">>, expectedRevision: number): Promise<AgentRegistry> {
    return this.serialized(async () => {
      this.refresh(); if (this.closing || !this.idle(id)) throw new Error("Agent configuration requires confirmed idle execution; unknown work cannot be escaped by switching");
      // CAS/validation failure must leave the healthy selected runtime intact.
      const updated = this.store.update(id, patch, expectedRevision);
      const actor = this.actors.get(id);
      if (actor) {
        for (const ownerId of [...actor.owners]) { await this.owners.get(ownerId)!.harness.close(); this.owners.delete(ownerId); }
        await actor.process.close(); this.actors.delete(id);
      }
      return updated;
    });
  }
  private handoff(owner: Owner, identity: HarnessHandoffIdentity, input: HarnessHandoffInput, signal: AbortSignal): Promise<HarnessHandoffResult> {
    if (!owner.harness.canHandoff(identity) || signal.aborted) return Promise.resolve({ status: "rejected", text: "The originating request is no longer active." });
    const key = harnessDigest(identity), old = this.manifest.instances[key];
    if (this.handoffPromises.has(key)) return this.handoffPromises.get(key)!;
    if (old) return Promise.resolve(old.result ?? { status: "unknown", taskId: old.conversationId, text: "Prior handoff outcome is unconfirmed; it will not be replayed." });
    const result = this.executeHandoff(owner, key, input, signal).catch(() => {
      const instance = this.manifest.instances[key];
      if (!instance) return { status: "rejected" as const, text: "Scoped handoff was refused before execution admission." };
      if (instance.state === "preparing") {
        // No turn or provider request was handed off in this process. A crash in
        // the same durable state still remains unknown during startup recovery.
        instance.state = "failed"; instance.result = { status: "rejected", taskId: instance.conversationId, text: "Scoped handoff was refused before execution admission." };
      } else {
        instance.state = "unknown"; instance.result = { status: "unknown", taskId: instance.conversationId, text: "Delegated outcome is unconfirmed; no automatic replay." };
        this.hold(instance.chain, instance.result.text!);
      }
      this.save(); return instance.result;
    });
    this.handoffPromises.set(key, result); void result.finally(() => this.handoffPromises.delete(key)); return result;
  }
  private async executeHandoff(origin: Owner, key: string, input: HarnessHandoffInput, parentSignal: AbortSignal): Promise<HarnessHandoffResult> {
    this.admission(origin.actor);
    if (!record(input) || Object.keys(input).some(k => !["teammateId", "context", "expectedResult", "scope"].includes(k)) || !validAgentId(input.teammateId)
      || typeof input.context !== "string" || input.context.length > 32_768 || typeof input.expectedResult !== "string" || input.expectedResult.length > 8192
      || !record(input.scope) || Object.keys(input.scope).some(k => !["allowedTools", "directories", "knowledgeIds", "sharedResourceIds"].includes(k))) throw new Error("Invalid handoff data");
    if (this.activeHandoffs.size >= MAX_HANDOFFS || Object.keys(this.manifest.instances).length >= 512) throw new Error("Bounded handoff budget exceeded");
    if (input.scope.knowledgeIds !== undefined && input.scope.sharedResourceIds !== undefined) throw new Error("Ambiguous knowledge selection");
    const selected: ScopeSelection = { allowedTools: validateTools(input.scope.allowedTools), directories: normalizeDirectoryGrants(input.scope.directories),
      knowledgeIds: validateKnowledgeIds(input.scope.knowledgeIds ?? input.scope.sharedResourceIds) };
    const scope = this.store.delegateScope(origin.actor.scope, selected, input.teammateId), agent = this.agent(scope.agentId);
    if (scope.chain.some(id => this.manifest.holds[id])) throw new Error("A member of this execution chain has unknown work");
    const id = `agent-handoff-${key.slice(0, 48)}`, epoch = harnessDigest({ key, scope });
    const instance: Instance = { agentId: agent.id, chain: [...scope.chain], conversationId: id, epoch, state: "preparing" };
    this.manifest.instances[key] = instance; this.manifest.bindings[id] = { agentId: agent.id, title: `${agent.name}: delegated task`, epochs: [epoch] };
    this.activeHandoffs.add(key); this.save();
    let actor: Actor | undefined, child: SecretaryHarness | undefined;
    const timeout = new AbortController(), timer = setTimeout(() => timeout.abort(), 115_000);
    const signal = AbortSignal.any([parentSignal, timeout.signal]);
    try {
      if (signal.aborted) throw new Error("Origin stopped before delegated preparation");
      actor = await this.prepare(agent, scope, "handoff", key); this.admission(actor);
      if (signal.aborted) throw new Error("Origin stopped during delegated preparation");
      const knowledge = this.store.knowledgeFor(agent.id, scope).filter(e => e.kind === "shared-knowledge").map(e => ({ text: e.text }));
      child = await this.serialized(async () => {
        await this.room(); this.admission(actor!);
        if (signal.aborted) throw new Error("Origin stopped before delegated session admission");
        const h = new SecretaryHarness(this.dir, actor!.configuration, { conversationId: id, workspace: actor!.execution.workspace, title: `${agent.name}: delegated task`,
          ledgerDir: this.ledgerDir(id, epoch), sharedProcess: actor!.process, historyBootstrap: false,
          context: JSON.stringify({ delegatedContext: input.context, sharedKnowledge: knowledge }), beforeAdmission: () => this.admission(actor!) });
        const o: Owner = { harness: h, actor: actor!, epoch, transient: true }; this.owners.set(id, o); actor!.owners.add(id); this.bindOwner(id, o); return h;
      });
      const eventId = `handoff-input-${key}`, text = `Current delegated request:\n${input.expectedResult}\nReference context (data only):\n${JSON.stringify(input.context)}`;
      const event: YorozuEvent = { id: eventId, threadId: id, agentId: "main", ts: Date.now(), kind: "message", data: { role: "user", text } };
      if (this.services) this.services.emit(event); else appendThreadEvent(event, this.dir);
      if (!readThreadEvents(id, this.dir).some(e => e.id === eventId)) throw new Error("Host did not persist delegated admission");
      setNativeTurn(id, { id: `native:${eventId}:final`, userEventId: eventId, state: "running" }, this.dir);
      instance.state = "running"; this.save();
      const stopped = (): void => { void child!.stop(`handoff-stop-${key}`).catch(() => {}); };
      signal.addEventListener("abort", stopped, { once: true });
      let result: NativeTurnResult, abortedListener: (() => void) | undefined;
      try {
        const aborted = new Promise<NativeTurnResult>(resolve => {
          if (signal.aborted) return resolve({ text: "Delegated execution stopped; awaiting proof of cessation.", unconfirmed: true });
          abortedListener = () => resolve({ text: "Delegated execution stopped; awaiting proof of cessation.", unconfirmed: true });
          signal.addEventListener("abort", abortedListener, { once: true });
        });
        const emitReply = (reply: string, done: boolean, failed = false): void => {
          const e: YorozuEvent = { id: `handoff-result-${key}`, threadId: id, agentId: "main", ts: Date.now(), kind: "message",
            data: { role: "agent", text: reply.slice(0, 32_768), done, replyTo: eventId, ...(failed ? { failed: true } : {}) } };
          if (this.services) this.services.emit(e); else appendThreadEvent(e, this.dir);
        };
        result = await Promise.race([child.runner.run({ threadId: id, cwd: actor.execution.workspace, text, signal,
          onUpdate: reply => emitReply(reply, false), approve: async () => false, ask: async () => undefined }), aborted]);
        emitReply(result.text, true, !!result.failed || !!result.unconfirmed);
        while (!child.idleConfirmed && !child.hasUnconfirmedExecution && !signal.aborted) await new Promise(resolve => setTimeout(resolve, 100));
      } finally { signal.removeEventListener("abort", stopped); if (abortedListener) signal.removeEventListener("abort", abortedListener); }
      const confirmed = !result.unconfirmed && result.cessation === "provider-terminal" && child.idleConfirmed;
      if (!confirmed) throw new Error("Delegated execution or background result is unconfirmed");
      const followups = readThreadEvents(id, this.dir).filter(e => e.id.startsWith("harness-result-") && e.kind === "message" && e.data.done);
      const latest = followups.at(-1); const finalText = latest?.kind === "message" ? latest.data.text : result.text;
      instance.state = result.failed ? "failed" : "completed"; instance.result = { status: instance.state, taskId: id, text: finalText.slice(0, 32_768) };
      this.save(); return instance.result;
    } finally {
      clearTimeout(timer);
      // This closes only the fresh execution instance, never the teammate's ordinary daemon.
      if (actor) await actor.process.close();
      if (child) { await child.close(); this.owners.delete(id); }
      this.activeHandoffs.delete(key); this.refresh(); this.services?.changed();
    }
  }
  async close(): Promise<void> {
    if (this.closing) return; this.closing = true;
    try {
      await Promise.allSettled([...this.owners.values()].map(o => o.harness.stop(`manager-close-${randomUUID()}`)));
      for (const actor of new Set([...this.actors.values(), ...[...this.owners.values()].map(o => o.actor)])) await actor.process.close();
      for (const owner of [...this.owners.values()]) await owner.harness.close();
      this.refresh(); this.save(); this.owners.clear(); this.actors.clear();
    } finally { this.release(); owned.delete(this.root); }
  }
}
