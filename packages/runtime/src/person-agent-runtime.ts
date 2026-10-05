/** Persistent agents keep their native sessions; the host only supervises and transports. */
import { randomUUID } from "node:crypto";
import { closeSync, constants, existsSync, fstatSync, fsyncSync, mkdirSync, openSync, readFileSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { HarnessOrigin, ThreadSummary, YorozuEvent } from "@yorozu/shared";
import { HarnessPlatformStore } from "./harness-platform-store.js";
import type { NativeTurnResult } from "./native.js";
import { PersonAgentStore, type PersonAgent, type PersonAgentPatch, type AgentRegistry } from "./agent-store.js";
import { pathWithin, safeAgentPath, validAgentId, type EffectiveAgentScope } from "./agent-scope.js";
import { releaseHostListener, validateHostListeners } from "./agent-listener.js";
import { isolatedAgentLaunch, type AgentIsolationRuntime } from "./agent-isolation.js";
import { HarnessProcess, type SupervisedHarnessConfiguration } from "./harness-process.js";
import { harnessDigest } from "./harness-ledger.js";
import type { HarnessConfiguration } from "./harness-contract.js";
import { SecretaryHarness, type HarnessServices, type HarnessHandoffResult } from "./harness-runner.js";
import { appendThreadEvent, createThread, listThreads } from "./threads.js";
import { retainSharedSyncHost } from "./rust-sync.js";

export interface PersonAgentExecution {
  kind: "ordinary" | "handoff"; id: string; scratchRoot: string; workspace: string; memoryDir: string;
}
/** Trusted host code supplies pinned interpreters/adapters and exact broker ports.
 * This factory is never invoked with model-selected code, environment, or profile paths.
 */
export type PersonAgentRuntimeFactory = (agent: PersonAgent, scope: EffectiveAgentScope, execution: PersonAgentExecution) =>
  Promise<{ configuration: HarnessConfiguration; runtime: AgentIsolationRuntime; release?(): void | Promise<void> }> | { configuration: HarnessConfiguration; runtime: AgentIsolationRuntime; release?(): void | Promise<void> };
interface Binding { agentId: string; title: string; epochs: string[]; legacyMetadataDigest?: string }
interface Instance { agentId: string; chain: string[]; conversationId: string; epoch: string; state: "preparing" | "running" | "completed" | "failed" | "unknown"; result?: HarnessHandoffResult }
interface Manifest { version: 1; bindings: Record<string, Binding>; taskOwners: Record<string, string>; holds: Record<string, string>; instances: Record<string, Instance>;
  canonical?: Record<string, string>; profiles?: Record<string, Record<string, string>> }
interface Actor { agent: PersonAgent; scope: EffectiveAgentScope; signature: string; execution: PersonAgentExecution; configuration: SupervisedHarnessConfiguration; process: HarnessProcess; owners: Set<string>; activate?(): void; release?(): void | Promise<void> }
interface Owner { harness: SecretaryHarness; actor: Actor; epoch: string; transient: boolean }
const owned = new Set<string>();
const MAX_OWNERS = 64, MAX_MANIFEST_BYTES = 2 * 1024 * 1024;
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
  if (!record(s) || Object.keys(s).some(k => !["version", "bindings", "taskOwners", "holds", "instances", "canonical", "profiles"].includes(k)) || s.version !== 1
    || !record(s.bindings) || !record(s.taskOwners) || !record(s.holds) || !record(s.instances)
    || Object.keys(s.bindings).length > 512 || Object.keys(s.taskOwners).length > 2048 || Object.keys(s.instances).length > 512) throw new Error("Damaged agent runtime journal");
  for (const [id, b] of Object.entries(s.bindings) as [string, Binding][]) if (!threadId(id) || !record(b) || !validAgentId(b.agentId)
    || typeof b.title !== "string" || b.title.length > 200 || !Array.isArray(b.epochs) || b.epochs.length > 64 || b.epochs.some(e => !hash(e))
    || b.legacyMetadataDigest !== undefined && (!hash(b.legacyMetadataDigest) || id !== "yorozu-secretary-v1")
    || Object.keys(b).some(k => !["agentId", "title", "epochs", "legacyMetadataDigest"].includes(k))) throw new Error("Damaged conversation ownership");
  for (const [task, owner] of Object.entries(s.taskOwners)) if (!threadId(task) || !threadId(owner) || !s.bindings[owner]) throw new Error("Damaged task ownership");
  for (const [id, reason] of Object.entries(s.holds)) if (!validAgentId(id) || typeof reason !== "string" || reason.length > 2000) throw new Error("Damaged agent hold");
  for (const [id, v] of Object.entries(s.instances) as [string, Instance][]) if (!hash(id) || !record(v) || !validAgentId(v.agentId) || !threadId(v.conversationId) || !hash(v.epoch)
    || !Array.isArray(v.chain) || !v.chain.length || v.chain.length > 8 || v.chain.some(a => !validAgentId(a)) || v.chain.at(-1) !== v.agentId
    || !["preparing", "running", "completed", "failed", "unknown"].includes(v.state)
    || v.result !== undefined && (!record(v.result) || !["completed", "failed", "unknown", "rejected"].includes(v.result.status)
      || v.result.text !== undefined && (typeof v.result.text !== "string" || v.result.text.length > 32_768))) throw new Error("Damaged handoff ownership");
  if (s.canonical !== undefined && (!record(s.canonical) || Object.entries(s.canonical).some(([id, conversation]) => !validAgentId(id)
    || !threadId(conversation) || s.bindings[conversation]?.agentId !== id))) throw new Error("Damaged canonical conversation ownership");
  if (s.profiles !== undefined && (!record(s.profiles) || Object.entries(s.profiles).some(([id, profiles]) => !validAgentId(id)
    || !record(profiles) || Object.entries(profiles).some(([key, epoch]) => !hash(key) || !hash(epoch))))) throw new Error("Damaged native profile ownership");
  for (const key of ["bindings", "taskOwners", "holds", "instances"]) s[key] = Object.assign(Object.create(null), s[key]);
  s.canonical = Object.assign(Object.create(null), s.canonical ?? {});
  s.profiles = Object.assign(Object.create(null), s.profiles ?? {});
  for (const id of Object.keys(s.profiles)) s.profiles[id] = Object.assign(Object.create(null), s.profiles[id]);
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
  readonly platformStore: HarnessPlatformStore;
  private services?: HarnessServices;
  private actors = new Map<string, Actor>();
  private owners = new Map<string, Owner>();
  private operations: Promise<unknown> = Promise.resolve();
  private pendingOperations = 0;
  private closing = false;
  private delivering = new Set<string>();
  private inboxRetries = new Map<string, ReturnType<typeof setTimeout>>();
  constructor(readonly dir: string, readonly store: PersonAgentStore, readonly factory: PersonAgentRuntimeFactory,
    private readonly supportsPeerInbox?: (agent: PersonAgent) => boolean) {
    this.root = safeAgentPath(join(dir, "person-agent-runtime-v1")); mkdirSync(this.root, { recursive: true, mode: 0o700 });
    if (owned.has(this.root)) throw new Error("Person agent runtime already owned");
    this.release = retainSharedSyncHost(join(this.root, "lease")); owned.add(this.root); this.file = join(this.root, "manifest.json");
    try {
      this.manifest = validateManifest(readObject(this.file, MAX_MANIFEST_BYTES) ?? empty());
      this.platformStore = new HarnessPlatformStore(dir);
      for (const v of Object.values(this.manifest.instances)) if (["preparing", "running", "unknown"].includes(v.state)) {
        v.state = "unknown"; this.hold(v.chain, "Prior delegated execution is unconfirmed; no automatic replay");
      }
      for (const [id, b] of Object.entries(this.manifest.bindings)) if (b.epochs.some(e => unsettled(this.ledgerFile(id, e))))
        this.hold([b.agentId], "Prior agent execution or result delivery is unconfirmed");
      this.save();
    } catch (e) { owned.delete(this.root); this.release(); throw e; }
  }
  bind(services: HarnessServices): void {
    this.services = services; this.platformStore.bind(services.emit, services.changed);
    for (const [id, o] of this.owners) this.bindOwner(id, o);
    for (const agent of this.store.list().agents) void this.deliverPending(agent.id);
  }
  private save(): void { writeObject(this.file, this.manifest); }
  private hold(ids: string[], reason: string): void { for (const id of ids) this.manifest.holds[id] = reason.slice(0, 2000); }
  held(agentId: string): string | undefined { this.refresh(); return this.manifest.holds[agentId]; }
  /** Configuration cannot change an execution chain while its outcome is unsettled. */
  assertControlsIdle(): void {
    this.refresh();
    if (this.closing || this.pendingOperations || this.platformStore.hasUnconfirmedActions() || Object.keys(this.manifest.holds).length
      || [...this.owners.values()].some(owner => !owner.harness.idleConfirmed))
      throw new Error("Agent settings require confirmed idle execution");
  }
  bindingForThread(id: string): { agentId: string; name: string; workspace: string } | undefined {
    const conversation = this.manifest.taskOwners[id] ?? id;
    const binding = this.manifest.bindings[conversation];
    if (!binding) return;
    const agent = this.agent(binding.agentId);
    return { agentId: agent.id, name: agent.name, workspace: agent.workspace };
  }
  isTaskThread(id: string): boolean { return Object.hasOwn(this.manifest.taskOwners, id); }
  /** Persist host identity without opening a vendor session or resolving account access. */
  bindConversation(id: string, agentId: string, title = "Conversation"): void {
    if (this.closing || !threadId(id) || typeof title !== "string" || title.length > 200 || this.manifest.taskOwners[id])
      throw new Error("Invalid owned conversation");
    this.agent(agentId);
    const previous = this.manifest.bindings[id];
    if (previous && previous.agentId !== agentId) throw new Error("Conversation agent identity is immutable");
    if (previous) return;
    if (Object.keys(this.manifest.bindings).length >= 512) throw new Error("Conversation binding budget exceeded");
    this.manifest.bindings[id] = { agentId, title, epochs: [] }; this.save();
  }
  /** One continuing conversation per person. Older topic bindings remain readable history. */
  canonicalConversation(agentId: string): string {
    const agent = this.agent(agentId), canonical = this.manifest.canonical ??= {};
    if (canonical[agentId]) return canonical[agentId];
    const transient = new Set(Object.values(this.manifest.instances).map(i => i.conversationId));
    const existing = Object.entries(this.manifest.bindings).filter(([id, b]) => b.agentId === agentId && !transient.has(id));
    const id = existing.find(([id]) => id === "yorozu-secretary-v1")?.[0] ?? existing[0]?.[0]
      ?? `agent-conversation-${harnessDigest(agentId).slice(0, 48)}`;
    this.bindConversation(id, agentId, agent.name);
    createThread(agent.name, this.dir, id, { agent: "harness", cwd: agent.workspace });
    canonical[agentId] = id; this.save(); return id;
  }
  /** Trusted opt-in only. History/backend sessions remain intact and grant no file access. */
  bindSecretary(agentId: string): void {
    this.assertControlsIdle(); this.agent(agentId);
    const id = "yorozu-secretary-v1", previous = this.manifest.bindings[id];
    if (previous) {
      if (previous.agentId !== agentId) throw new Error("The secretary person identity is immutable");
      return;
    }
    const existing = listThreads(this.dir).find(t => t.id === id);
    if (existing?.nativeTurn || unsettled(join(this.dir, "harness-v1", "binding.json")))
      throw new Error("Legacy secretary execution must be confirmed idle before migration");
    const queue = readObject(join(this.dir, "native-turn-queue.json"), MAX_MANIFEST_BYTES);
    if (queue && (!Array.isArray(queue) || queue.length)) throw new Error("Legacy queued work must settle before migration");
    for (const path of [join(this.dir, "secretary-tasks-v1"), join(this.dir, "secretary-v1", "runs")]) {
      if (existsSync(path) && readdirSync(safeAgentPath(path, true)).length)
        throw new Error("Legacy worker records require explicit reconciliation before secretary migration");
    }
    const legacyMetadataDigest = existing ? this.legacyMetadata(id) : undefined;
    this.manifest.bindings[id] = { agentId, title: existing?.title || "Yorozu", epochs: [],
      ...(legacyMetadataDigest ? { legacyMetadataDigest } : {}) };
    this.save();
  }
  private legacyMetadata(id: string): string {
    const existing = listThreads(this.dir).find(t => t.id === id);
    if (!existing) throw new Error("Legacy conversation record is missing");
    return harnessDigest({ agent: existing.agent, cwd: existing.cwd, nativeSessionId: existing.nativeSessionId });
  }
  private ledgerDir(id: string, epoch: string): string { return join(this.root, "ledgers", harnessDigest(id), epoch); }
  private ledgerFile(id: string, epoch: string): string { return join(this.ledgerDir(id, epoch), "harness-v1", "binding.json"); }
  private signature(agent: PersonAgent, scope: EffectiveAgentScope): string {
    return harnessDigest({ agent, allowedTools: scope.allowedTools, directories: scope.directories });
  }
  /** Permission/settings epochs do not fork the harness's learned native state. */
  private profileEpoch(agent: PersonAgent): string {
    const key = harnessDigest([agent.pluginId, agent.runtime?.mode ?? "managed", agent.runtime?.mode === "connected" ? agent.runtime.connectionId : null]);
    const profiles = (this.manifest.profiles ??= Object.create(null))[agent.id] ??= Object.create(null);
    if (profiles[key]) return profiles[key];
    // Adopt only this host's already owned profile and matching plugin ledger.
    for (const [id, b] of Object.entries(this.manifest.bindings).reverse()) if (b.agentId === agent.id) {
      for (const epoch of [...b.epochs].reverse()) {
        const ledger = readObject(this.ledgerFile(id, epoch), 16 * 1024 * 1024);
        const marker = readObject(join(this.root, "scratch", agent.id, epoch, "owner.json"), 4096);
        if (ledger?.pluginId === agent.pluginId && marker?.agentId === agent.id && marker.kind === "ordinary" && marker.id === epoch
          && (agent.runtime?.mode ?? "managed") === "managed") { profiles[key] = epoch; this.save(); return epoch; }
      }
    }
    profiles[key] = harnessDigest(["native-profile-v1", agent.id, key]); this.save(); return profiles[key];
  }
  private serialized<T>(fn: () => Promise<T>): Promise<T> {
    this.pendingOperations++;
    const p = this.operations.then(fn).finally(() => { this.pendingOperations--; });
    this.operations = p.catch(() => {}); return p;
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
    if (this.platformStore.hasUnconfirmedActions(actor.agent.id, false)) throw new Error("A harness answer outcome is unconfirmed; new work is held");
    if (actor.scope.chain.some(id => this.manifest.holds[id])) throw new Error("Agent execution remains held until its unknown outcome is resolved");
    const current = this.store.resolveScope(actor.agent.id);
    if (this.signature(this.agent(actor.agent.id), current) !== actor.signature)
      throw new Error("Agent settings changed; a confirmed idle switch is required");
  }
  private agent(id: string): PersonAgent {
    const agent = this.store.list().agents.find(a => a.id === id); if (!agent) throw new Error("Unknown persistent agent"); return agent;
  }
  private idle(agentId: string): boolean {
    return !this.manifest.holds[agentId] && !this.platformStore.hasUnconfirmedActions(agentId)
      && ![...this.owners.values()].some(o => o.actor.scope.chain.includes(agentId) && !o.harness.idleConfirmed);
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
      action: (action, respond, current) => this.platformStore.openAction(action, async answer => {
        if (answer.uiTargetId !== undefined) {
          if (!current()) return { status: "rejected", reason: "The original harness request is no longer current." };
          return await this.services?.openUI?.(action.origin, answer.uiTargetId)
            ? { status: "requested", reason: "The harness interface was opened. Complete this request there." }
            : { status: "rejected", reason: "This harness interface target is unavailable on the host." };
        }
        return respond(answer);
      }, current),
      cancelAction: (origin, requestId) => this.platformStore.cancelAction(origin, requestId),
      agentMessage: (origin, input) => this.acceptPeerMessage(owner, origin, input),
      agentMessageStatus: (origin, messageId) => this.platformStore.senderReceiptUnknown(origin, messageId) });
  }
  private async acceptPeerMessage(owner: Owner, origin: HarnessOrigin, input: { messageId: string; toAgentId: string; text: string; exchangeId?: string }): Promise<{ status: "accepted" | "rejected" | "unknown"; exchangeId?: string; reason?: string }> {
    try {
      this.admission(owner.actor);
      const sender = this.agent(origin.agentId), recipient = this.agent(input.toAgentId);
      if (sender.id !== owner.actor.agent.id || origin.conversationId !== owner.harness.conversationId || sender.id === recipient.id
        || !sender.teamIds.some(team => recipient.teamIds.includes(team)))
        return { status: "rejected", reason: "The recipient is not an explicitly configured teammate." };
      const message = this.platformStore.acceptMessage(origin, input.messageId, recipient.id, input.text, input.exchangeId);
      void this.deliverPending(recipient.id);
      return { status: "accepted", exchangeId: message.exchangeId };
    } catch (error) { return { status: this.platformStore.unconfirmed ? "unknown" : "rejected", reason: error instanceof Error ? error.message.slice(0, 512) : "Agent message was not admitted." }; }
  }
  private async deliverPending(agentId: string): Promise<void> {
    if (this.delivering.has(agentId) || this.closing) return;
    this.delivering.add(agentId);
    try {
      if (!this.platformStore.pendingFor(agentId).length) return;
      if (this.supportsPeerInbox && !this.supportsPeerInbox(this.agent(agentId))) {
        for (const message of this.platformStore.pendingFor(agentId)) {
          const attempt = this.platformStore.beginDelivery(message.messageId);
          this.platformStore.settleDelivery(message.messageId, attempt, "rejected", "The selected harness has no declared native peer inbox.", true);
        }
        return;
      }
      const recipient = await this.conversation(this.canonicalConversation(agentId), agentId);
      // Session/bootstrap failures precede the message attempt, so retained data can wait.
      if (!await recipient.prepareMessageDelivery()) {
        for (const message of this.platformStore.pendingFor(agentId)) {
          const attempt = this.platformStore.beginDelivery(message.messageId);
          this.platformStore.settleDelivery(message.messageId, attempt, "rejected", "The selected harness has no native peer inbox.", true);
        }
        return;
      }
      const seen = new Set<string>();
      while (!this.closing) {
        const message = this.platformStore.pendingFor(agentId).find(message => !seen.has(message.messageId));
        if (!message) break;
        seen.add(message.messageId);
        if (this.closing) return;
        const attempt = this.platformStore.beginDelivery(message.messageId);
        try {
          const receipt = await recipient.deliverMessage(message, attempt);
          if (receipt.status === "accepted") this.platformStore.settleDelivery(message.messageId, attempt, "delivered");
          else if (["busy", "rejected", "unsupported"].includes(receipt.status) && receipt.handoff === "not-submitted") {
            this.platformStore.settleDelivery(message.messageId, attempt, receipt.status === "busy" ? "accepted" : "rejected", receipt.reason, true);
            if (receipt.status === "busy" && !this.closing && !this.inboxRetries.has(agentId)) {
              const timer = setTimeout(() => { this.inboxRetries.delete(agentId); void this.deliverPending(agentId); }, 1000);
              timer.unref(); this.inboxRetries.set(agentId, timer);
            }
          }
          else this.platformStore.settleDelivery(message.messageId, attempt, "unknown", receipt.reason);
        } catch { this.platformStore.settleDelivery(message.messageId, attempt, "unknown", "The native inbox admission receipt was lost; no automatic resend."); }
      }
    } catch { /* No message attempt: keep durable accepted data for an available recipient. */ }
    finally { this.delivering.delete(agentId); }
  }
  answerAction(event: YorozuEvent): Promise<void> { return this.platformStore.answer(event); }
  private async room(): Promise<void> {
    if (this.owners.size < MAX_OWNERS) return;
    // Never detach a live actor's platform listener merely to reclaim an owner.
    // At the bounded limit refuse new admission; existing daemons remain observed.
    throw new Error("Conversation owner budget exceeded; no execution was admitted");
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
    // Bootstrap/account validation uses separate configuration scratch. Only after
    // successful preparation and quiescent retirement may it touch native state.
    const nativeEpoch = kind === "ordinary" ? this.profileEpoch(agent) : id;
    const nativeScratch = safeAgentPath(join(this.root, "scratch", agent.id, nativeEpoch));
    mkdirSync(nativeScratch, { recursive: true, mode: 0o700 });
    const nativeMarker = join(nativeScratch, "owner.json"), nativeOwner = { version: 1, agentId: agent.id, kind, id: nativeEpoch };
    const previousNativeOwner = readObject(nativeMarker, 4096);
    if (previousNativeOwner && JSON.stringify(previousNativeOwner) !== JSON.stringify(nativeOwner)) throw new Error("Native profile has another owner");
    if (!previousNativeOwner) {
      if (existsSync(join(nativeScratch, "profile"))) throw new Error("Refusing to adopt an unowned native profile");
      writeObject(nativeMarker, nativeOwner);
    }
    const nativeProfile = safeAgentPath(join(nativeScratch, "profile")); mkdirSync(nativeProfile, { recursive: true, mode: 0o700 });
    const execution: PersonAgentExecution = { kind, id, scratchRoot, workspace: kind === "ordinary" ? agent.workspace : join(scratchRoot, "profile", "scratch"),
      memoryDir: kind === "ordinary" ? agent.memoryDir : join(scratchRoot, "profile", "memory") };
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
        if (sibling !== scratchRoot && sibling !== nativeScratch) siblingScratch.push(sibling);
      }
      const deniedRoots = [...new Set([...scope.deniedRoots, ...siblingScratch, join(this.root, "ledgers"), this.file, join(this.root, "lease"),
        join(this.dir, "threads"), join(this.dir, "threads.json"), join(this.dir, "person-agent-controls-v1"), this.platformStore.root])];
      const osScope = { ...scope, deniedRoots, directories: [...scope.directories, { path: nativeProfile, access: "write" as const }] };
      const launch = isolatedAgentLaunch(osScope, built.runtime);
      let activate: (() => void) | undefined;
      if (typeof initialize.providerConfigPath === "string") {
        const provider = readObject(initialize.providerConfigPath, 4096);
        if (!provider) throw new Error("Prepared provider bootstrap is missing");
        const selectedPath = join(nativeProfile, "proof-provider.json");
        initialize.providerConfigPath = selectedPath;
        activate = () => writeObject(selectedPath, provider);
      }
      const scoped = { allowedTools: tools, directories: scope.directories.map(g => ({ ...g })),
        workspace: agent.pluginId === "openclaw" ? agent.workspace : execution.workspace,
        memoryDir: agent.pluginId === "openclaw" ? agent.memoryDir : execution.memoryDir,
        ...(agent.pluginId === "openclaw" ? { deniedRoots } : {}) };
      const configuration: SupervisedHarnessConfiguration = { ...built.configuration, command: launch.command, args: launch.args, runtime: agent.runtime,
        inheritedListeners: built.runtime.inheritedListeners,
        initialize: { ...initialize, agentId: agent.id, workspace: execution.workspace, model: agent.model,
          scope: scoped, isolation: launch.isolation, platform: { team: agent.teamIds.length > 0, computer: false,
            peers: this.store.list().agents.filter(peer => peer.id !== agent.id && peer.teamIds.some(team => agent.teamIds.includes(team)))
              .map(peer => ({ agentId: peer.id, name: peer.name, pluginId: peer.pluginId })) },
          ...(agent.runtime ? { lifecycle: agent.runtime } : {}),
          ...(agent.pluginId === "hermes" ? { profileRoot: nativeProfile } : { profileDir: nativeProfile }) } };
      return { agent, scope, signature: this.signature(agent, scope), execution, configuration, process: new HarnessProcess(configuration), owners: new Set(), activate, release: built.release };
    } catch (error) {
      let held = [] as ReturnType<typeof validateHostListeners>;
      try { held = validateHostListeners(built?.runtime?.inheritedListeners ?? [], agent.id); } catch { /* Unowned handles stay with their original host. */ }
      await Promise.all(held.map(releaseHostListener)); await built.release?.(); throw error;
    }
  }
  /** Bind a new ordinary chat, or reopen its immutable agent binding. */
  conversation(id: string, agentId?: string, title = "Conversation"): Promise<SecretaryHarness> {
    return this.serialized(async () => {
      if (this.closing || !threadId(id) || typeof title !== "string" || title.length > 200) throw new Error("Invalid owned conversation");
      const previous = this.manifest.bindings[id]; const selected = agentId ?? previous?.agentId ?? this.store.list().defaultAgentId;
      if (!selected || previous && previous.agentId !== selected || this.manifest.taskOwners[id]) throw new Error("Conversation agent identity is immutable");
      if (previous?.legacyMetadataDigest && previous.legacyMetadataDigest !== this.legacyMetadata(id))
        throw new Error("Legacy backend metadata changed; the agent binding requires inspection");
      const agent = this.agent(selected), scope = this.store.resolveScope(selected), signature = this.signature(agent, scope), epoch = this.profileEpoch(agent);
      this.refresh(); if (this.manifest.holds[selected]) throw new Error(this.manifest.holds[selected]);
      const existing = this.owners.get(id);
      if (existing && existing.actor.signature === signature) { this.admission(existing.actor); return existing.harness; }
      let actor = this.actors.get(selected);
      if (actor && actor.signature !== signature) {
        if (!this.idle(selected)) throw new Error("Agent settings switch requires all owned execution to be confirmed idle");
        const candidate = await this.prepare(agent, scope, "ordinary", signature);
        for (const ownerId of [...actor.owners]) { await this.owners.get(ownerId)?.harness.close(); this.owners.delete(ownerId); actor.owners.delete(ownerId); }
        await this.closeActor(actor); this.actors.delete(selected);
        try { candidate.activate?.(); } catch (error) { await this.closeActor(candidate); this.hold([selected], "Native profile activation is unconfirmed; inspect before switching again"); this.save(); throw error; }
        actor = candidate; this.actors.set(selected, actor);
      }
      if (actor?.process.unavailable) throw new Error("Agent daemon exited; no implicit respawn");
      if (!actor) {
        actor = await this.prepare(agent, scope, "ordinary", signature);
        try { actor.activate?.(); } catch (error) { await this.closeActor(actor); this.hold([selected], "Native profile activation is unconfirmed; inspect before switching again"); this.save(); throw error; }
        this.actors.set(selected, actor);
      }
      await this.room();
      const binding = previous ?? { agentId: selected, title, epochs: [] };
      if (Object.keys(this.manifest.bindings).length >= 512 && !previous || binding.epochs.length >= 64 && !binding.epochs.includes(epoch)) throw new Error("Conversation binding budget exceeded");
      this.manifest.bindings[id] = binding; if (!binding.epochs.includes(epoch)) binding.epochs.push(epoch); this.save();
      const harness = new SecretaryHarness(this.dir, actor.configuration, { conversationId: id, workspace: agent.workspace,
        title: binding.title, ledgerDir: this.ledgerDir(id, epoch), sharedProcess: actor.process,
        ...(binding.legacyMetadataDigest ? { preserveLegacyMetadata: true as const } : {}), beforeAdmission: () => this.admission(actor!) });
      const owner = { harness, actor, epoch, transient: false }; this.owners.set(id, owner); actor.owners.add(id); this.bindOwner(id, owner);
      queueMicrotask(() => { void this.deliverPending(selected); });
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
    const exchange = this.platformStore.exchangeSummary(id);
    if (exchange) return { personAgentExchange: exchange, canRewind: false, canResume: false };
    const conversation = this.manifest.taskOwners[id] ?? id; return this.owners.get(conversation)?.harness.summary(id);
  }
  async taskStop(event: YorozuEvent): Promise<boolean> { return await (await this.owner(event.threadId))?.taskStop(event) ?? false; }
  /** Trusted settings operation. History and prior binding evidence remain in place. */
  configure(id: string, patch: PersonAgentPatch, expectedRevision: number): Promise<AgentRegistry> {
    return this.serialized(async () => {
      this.refresh(); if (this.closing || !this.idle(id)) throw new Error("Agent configuration requires confirmed idle execution; unknown work cannot be escaped by switching");
      // CAS/validation failure must leave the healthy selected runtime intact.
      const updated = this.store.update(id, patch, expectedRevision);
      const actor = this.actors.get(id);
      if (actor) {
        for (const ownerId of [...actor.owners]) { await this.owners.get(ownerId)?.harness.close(); this.owners.delete(ownerId); actor.owners.delete(ownerId); }
        await this.closeActor(actor); this.actors.delete(id);
      }
      return updated;
    });
  }
  async close(): Promise<void> {
    if (this.closing) return; this.closing = true;
    for (const timer of this.inboxRetries.values()) clearTimeout(timer); this.inboxRetries.clear();
    try {
      await Promise.allSettled([...this.owners.values()].filter(o => o.actor.agent.runtime?.mode !== "connected").map(o => o.harness.stop(`manager-close-${randomUUID()}`)));
      for (const actor of new Set([...this.actors.values(), ...[...this.owners.values()].map(o => o.actor)])) await this.closeActor(actor);
      for (const owner of [...this.owners.values()]) await owner.harness.close();
      this.refresh(); this.save(); this.owners.clear(); this.actors.clear();
    } finally { this.release(); owned.delete(this.root); }
  }
  private async closeActor(actor: Actor): Promise<void> {
    const release = actor.release; actor.release = undefined;
    try { await actor.process.close(); } finally { await release?.(); }
  }
  /** Host-only account retirement. Fence inference synchronously outside this manager,
   * then retire the exact actors. Active work retains uncertainty and cannot respawn. */
  retireAccount(binding: string): Promise<void> {
    const affected = [...new Set([...this.actors.values(), ...[...this.owners.values()].map(owner => owner.actor)])]
      .filter(actor => actor.agent.accountBindingId === binding);
    for (const actor of affected) if (!this.idle(actor.agent.id)) this.hold(actor.scope.chain, "Account access was retired during unconfirmed execution");
    this.save();
    return this.serialized(async () => {
      for (const actor of affected) {
        for (const ownerId of [...actor.owners]) {
          const owner = this.owners.get(ownerId); if (owner?.actor !== actor) { actor.owners.delete(ownerId); continue; }
          try { if (actor.agent.runtime?.mode !== "connected") await owner.harness.stop(`account-retire-${randomUUID()}`); } finally {
            try { await owner.harness.close(); } finally { this.owners.delete(ownerId); actor.owners.delete(ownerId); }
          }
        }
        // Keep an ordinary retired actor as a tombstone: another chat must not
        // silently respawn the same execution. An explicit idle settings revision
        // selects a fresh execution identity through the existing switch path.
        await this.closeActor(actor);
      }
      this.refresh(); this.save(); this.services?.changed();
    });
  }
}
