/** Existing transport/history with host-owned person routing; no planner above a harness. */
import { type PersonAgentRegistry, type ThreadSummary, type YorozuEvent } from "@yorozu/shared";
import { PersonAgentStore, type PersonAgentInput } from "./agent-store.js";
import type { DirectoryGrant } from "./agent-scope.js";
import { PersonAgentRuntime, type PersonAgentRuntimeFactory } from "./person-agent-runtime.js";
import { PersonAgentControls } from "./person-agent-controls.js";
import { harnessDigest } from "./harness-ledger.js";
import type { HarnessServices } from "./harness-runner.js";
import type { NativeAgentRunner } from "./native.js";
import { createThread, listThreads } from "./threads.js";
import { join } from "node:path";
import { WorkerMemory } from "./worker-memory.js";

export interface PersonAgentPlatform {
  /** Trusted composition only; devices cannot switch persistence or execution code. */
  workerMemory?: true;
  /** Trusted startup hold; controls persist a typed rejection without applying a mutation. */
  assertControlsAllowed?(): void;
  createFactory(store: PersonAgentStore): PersonAgentRuntimeFactory;
  /** Previously selected resources, supplied only by trusted host configuration. */
  resourceRoots?: DirectoryGrant[];
  /** Trusted host credential/helper/lock roots excluded from every minted scope. */
  protectedRoots?: readonly string[];
  /** A fresh installation may explicitly provision its default person. */
  initialAgent?: PersonAgentInput;
  /** Explicit execution overlay; legacy backend metadata/history are retained for rollback. */
  secretaryAgentId?: string;
  /** Trusted discovery descriptors only; endpoints and credentials remain host-private. */
  catalog?(): Pick<PersonAgentRegistry, "harnesses" | "defaultHarnessId" | "connections">;
  openHarnessUI?(agentId: string, targetId: string): Promise<boolean>;
}

export class PersonAgentHost {
  readonly store: PersonAgentStore;
  readonly runtime: PersonAgentRuntime;
  readonly controls: PersonAgentControls;
  readonly runner: NativeAgentRunner;
  private readonly memory?: WorkerMemory;
  private closingRegistry?: PersonAgentRegistry;
  constructor(readonly dir: string, private readonly platform: PersonAgentPlatform) {
    this.store = new PersonAgentStore(dir, { resourceRoots: platform.resourceRoots,
      protectedRoots: [...(platform.protectedRoots ?? []), join(dir, "harness-platform-v1"), join(dir, "worker-memory-v1")] });
    this.memory = platform.workerMemory ? new WorkerMemory(join(dir, "worker-memory-v1"),
      id => this.store.list().agents.some(agent => agent.id === id)) : undefined;
    try {
      this.runtime = new PersonAgentRuntime(dir, this.store, platform.createFactory(this.store),
        agent => platform.catalog?.().harnesses?.some(h => h.id === agent.pluginId && h.available && h.capabilities.includes("agent-messaging-v1")) === true,
        this.memory);
    } catch (error) { this.memory?.close(); throw error; }
    let controls: PersonAgentControls | undefined;
    try {
      this.controls = controls = new PersonAgentControls(dir, this.store, this.runtime, { assertIdle: () => { platform.assertControlsAllowed?.(); this.runtime.assertControlsIdle(); } });
      if (platform.initialAgent && !this.store.list().agents.length) this.store.create(platform.initialAgent, 0);
      if (platform.secretaryAgentId) this.runtime.bindSecretary(platform.secretaryAgentId);
    } catch (error) { void controls?.close(); void this.runtime.close().finally(() => this.memory?.close()); throw error; }
    this.runner = { descriptor: { id: "harness", label: "Yorozu", description: "Selected person agent", needsFolder: true },
      run: async turn => {
        let owner;
        try {
          const binding = this.runtime.bindingForThread(turn.threadId);
          if (binding && !this.runtime.isTaskThread(turn.threadId) && turn.threadId !== this.runtime.canonicalConversation(binding.agentId))
            return { text: "This previous conversation is retained in History. Continue in the agent's ongoing conversation.", failed: true, cessation: "not-submitted" };
          owner = await this.runtime.owner(turn.threadId);
        } catch {
          return { text: "This agent is unavailable. Its prior work will not be restarted automatically.", failed: true, cessation: "not-submitted" };
        }
        if (!owner) return { text: "This conversation has no selected person agent.", failed: true, cessation: "not-submitted" };
        try { return await owner.runner.run({ ...turn, cwd: owner.workspace, bypass: false, sessionId: undefined, model: undefined, effort: undefined }); }
        catch { return { text: "The agent outcome is unconfirmed. This input will not be sent again automatically.", unconfirmed: true }; }
      } };
  }
  bind(services: HarnessServices): void { this.runtime.bind({ ...services,
    ...(this.platform.openHarnessUI ? { openUI: (origin, targetId) => this.platform.openHarnessUI!(origin.agentId, targetId) } : {}) }); }
  registry(): PersonAgentRegistry {
    if (this.closingRegistry) return structuredClone(this.closingRegistry);
    const registry = this.controls.registry();
    return { ...registry, ...this.platform.catalog?.(), agents: registry.agents.map(agent => ({ ...agent,
      conversationId: this.runtime.canonicalConversation(agent.id) })) };
  }
  owns(id: string): boolean { return !!this.runtime.bindingForThread(id); }
  ownsTask(id: string): boolean { return this.runtime.isTaskThread(id); }
  workspace(id: string): string | undefined { return this.runtime.bindingForThread(id)?.workspace; }
  summary(id: string): Partial<ThreadSummary> | undefined {
    const person = this.runtime.bindingForThread(id); if (!person) return this.runtime.summary(id);
    return { ...this.runtime.summary(id), personAgentId: person.agentId, personAgentName: person.name,
      agent: "harness", bypass: false, canRewind: false, canResume: false };
  }
  /** Called before generic logging. Settings controls never enter conversational history. */
  async control(event: YorozuEvent): Promise<void> {
    if (event.kind !== "person_agent_control") throw new Error("Invalid person-agent settings event");
    await this.controls.control(event.id, event.data);
  }
  action(event: YorozuEvent): Promise<void> { return this.runtime.answerAction(event); }
  /** A create binds only a published identity, never a caller cwd/model/account or grants. */
  async create(event: YorozuEvent): Promise<void> {
    if (event.kind !== "thread_create" || typeof event.id !== "string" || !event.id || event.id.length > 128 || /[\0\r\n]/.test(event.id)
      || typeof event.threadId !== "string" || !/^[\w.-]{1,128}$/.test(event.threadId)
      || Object.keys(event.data).some(k => !["personAgentId", "title"].includes(k))
      || typeof event.data.personAgentId !== "string" || event.data.title !== undefined &&
        (typeof event.data.title !== "string" || event.data.title.length > 200)) throw new Error("Invalid person-agent conversation");
    const agent = this.store.list().agents.find(a => a.id === event.data.personAgentId);
    if (!agent) throw new Error("Unknown person agent");
    const creation = { eventId: event.id, identity: harnessDigest([event.threadId, agent.id, event.data.title ?? null]) };
    const threads = listThreads(this.dir);
    const accepted = threads.find(t => t.creation?.eventId === event.id);
    if (accepted && (accepted.id !== event.threadId || accepted.creation?.identity !== creation.identity))
      throw new Error("Conflicting conversation creation identity");
    const existing = threads.find(t => t.id === event.threadId);
    if (!existing && event.threadId !== this.runtime.canonicalConversation(agent.id))
      throw new Error("Each agent has one ongoing conversation; new topic chats are not created");
    if (existing && (existing.creation?.eventId !== creation.eventId || existing.creation.identity !== creation.identity
      || existing.cwd !== agent.workspace || existing.agent !== "harness")) throw new Error("Conflicting person-agent conversation");
    const bound = this.runtime.bindingForThread(event.threadId);
    if (bound && bound.agentId !== agent.id) throw new Error("Conversation identity is immutable");
    if (!existing) createThread(event.data.title ?? agent.name, this.dir, event.threadId,
      { agent: "harness", cwd: agent.workspace, creation });
    this.runtime.bindConversation(event.threadId, agent.id, event.data.title ?? agent.name);
  }
  async close(): Promise<void> {
    try { await this.controls.close(); }
    finally {
      try { this.closingRegistry ??= this.registry(); }
      finally { try { await this.runtime.close(); } finally { this.memory?.close(); } }
    }
  }
}
