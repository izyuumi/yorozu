import { spawn } from "node:child_process";
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, randomUUID, sign } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { GatewayClient, type DeviceIdentity, type GatewayClientHostDeps } from "@openclaw/gateway-client";
import type { EventFrame } from "@openclaw/gateway-protocol/frame-guards";
import { ATTACHMENT_MAX_BYTES, YOROZU_EFFORTS, type EventPayload, type MessageAttachment, type ModelOption, type ReasoningEffort, type YorozuEvent } from "@yorozu/shared";

const DEFAULT_GATEWAY_URL = "ws://127.0.0.1:18789";

interface StoredGatewayAuth { identity: DeviceIdentity; token?: string; scopes?: string[] }
interface SetupCode { url: string; bootstrapToken: string }
interface Gateway {
  start(): void;
  stop(): void;
  request<T = Record<string, unknown>>(method: string, params?: unknown): Promise<T>;
}
interface PendingTurn {
  threadId: string;
  sessionKey: string;
  runId?: string;
  startedAt: number;
  completionId?: string;
  userEventId?: string;
  seen: Set<string>;
  calls: Set<string>;
  /** The latest `progress_card` narrative, carried onto plan updates that arrive without it. */
  progressNote?: string;
  tasks: Map<string, string>;
  childRunIds: Set<string>;
  input: StoredTurnInput;
  signal?: AbortSignal;
  onEvent?: (event: YorozuEvent) => void;
  awaitsAnnouncement: boolean;
  text: string;
  onUpdate?: (text: string) => void;
  resolve: (text: string) => void;
  reject: (error: Error) => void;
}

export interface StoredPendingTurn {
  threadId: string;
  sessionKey: string;
  runId: string;
  startedAt: number;
  completionId: string;
  userEventId?: string;
  awaitsAnnouncement: boolean;
  taskIds: string[];
  childRunIds: string[];
  input: StoredTurnInput;
  state: "queued" | "active";
}
export interface StoredTurnInput {
  text: string;
  model?: string;
  effort?: ReasoningEffort;
  attachments: MessageAttachment[];
}
export interface OpenClawTurn {
  threadId: string;
  text: string;
  model?: string;
  effort?: ReasoningEffort;
  attachments?: MessageAttachment[];
  signal?: AbortSignal;
  onUpdate?: (text: string) => void;
  onEvent?: (event: YorozuEvent) => void;
  completionId?: string;
  userEventId?: string;
  seenEventIds?: Iterable<string>;
}

export interface OpenClawRunnerOptions {
  command?: string;
  stateDir?: string;
  spawnProcess?: typeof spawn;
  clientFactory?: (options: ConstructorParameters<typeof GatewayClient>[0]) => Gateway;
  recoveryDelayMs?: number;
  /** Fetches Gateway-hosted media; the Gateway signs the URL, so no auth header is needed. */
  fetch?: typeof fetch;
}

/** Thin Gateway bridge. OpenClaw owns sessions, tools, credentials, and policy. */
export class OpenClawRunner {
  readonly #command: string;
  readonly #stateFile: string;
  readonly #spawn: typeof spawn;
  readonly #pendingFile: string;
  readonly #clientFactory: NonNullable<OpenClawRunnerOptions["clientFactory"]>;
  readonly #recoveryDelayMs: number;
  readonly #fetch: typeof fetch;
  #httpBase = DEFAULT_GATEWAY_URL.replace(/^ws/, "http");
  readonly #pending = new Set<PendingTurn>();
  #client?: Gateway;
  #connecting?: Promise<Gateway>;

  constructor(options: OpenClawRunnerOptions = {}) {
    this.#command = options.command ?? process.env.OPENCLAW_BIN ?? "openclaw";
    this.#stateFile = join(options.stateDir ?? process.env.YOROZU_STATE_DIR ?? ".", "openclaw-gateway.json");
    this.#spawn = options.spawnProcess ?? spawn;
    this.#pendingFile = join(options.stateDir ?? process.env.YOROZU_STATE_DIR ?? ".", "openclaw-pending.json");
    this.#clientFactory = options.clientFactory ?? ((clientOptions) => new GatewayClient(clientOptions));
    this.#recoveryDelayMs = options.recoveryDelayMs ?? 250;
    this.#fetch = options.fetch ?? fetch;
  }

  /**
   * The Gateway's usable models, the way it prefers them: its default model first, so the
   * picker's "Default" row means what the Gateway will actually run; that model's provider
   * ahead of the rest; and fallbacks ahead of the merely configured within a provider.
   */
  async listModels(): Promise<ModelOption[]> {
    const result = await (await this.connect()).request<{ models?: unknown[] }>("models.list", {});
    const models = (result.models ?? []).flatMap((value) => {
      if (!value || typeof value !== "object") return [];
      const model = value as Record<string, unknown>;
      const id = typeof model.id === "string" ? model.id : "";
      const provider = typeof model.provider === "string" ? model.provider : "";
      if (!id || !provider || model.available === false) return [];
      const tags = Array.isArray(model.tags) ? model.tags.filter((tag): tag is string => typeof tag === "string") : [];
      const rank = tags.includes("default") ? 0 : tags.some((tag) => tag.startsWith("fallback")) ? 1 : 2;
      return [{
        rank,
        option: {
          id: `${provider}/${id}`,
          label: typeof model.alias === "string" && model.alias ? model.alias : id,
          providerLabel: provider,
          efforts: [...YOROZU_EFFORTS],
        },
      }];
    });
    const lead = models.find((model) => model.rank === 0)?.option.providerLabel;
    return models
      .sort((a, b) => Number(a.option.providerLabel !== lead) - Number(b.option.providerLabel !== lead) || a.rank - b.rank)
      .map((model) => model.option);
  }

  async setArchived(threadId: string, archived: boolean): Promise<void> {
    const client = await this.connect();
    const key = `agent:main:yorozu:${threadId}`.toLowerCase();
    type Description = { session: { sessionId?: string; archived?: boolean } | null };
    const { session } = await client.request<Description>("sessions.describe", { key });
    // A local thread that never ran has no Gateway session to archive. Do not create one.
    if (session === null) return;
    if (!session?.sessionId) throw new Error("OpenClaw session identity unavailable");
    try {
      await client.request("sessions.patch", { key, archived, expectedSessionId: session.sessionId });
    } catch (error) {
      // Archive cleanup can fail after committing, or its acknowledgment can be lost.
      // Read back the same generation before reporting failure; never replay the mutation.
      const current = await client.request<Description>("sessions.describe", { key }).catch(() => null);
      if (current?.session?.sessionId === session.sessionId && current.session.archived === archived) return;
      throw error;
    }
  }
  pendingTurns(requireKnown = false): StoredPendingTurn[] {
    return this.readPending(requireKnown).sort((a, b) => a.startedAt - b.startedAt);
  }

  /** Durably owns a user turn before its visible event is accepted. Replays repair either side. */
  admitUserTurn(turn: OpenClawTurn, accept: (stored?: StoredPendingTurn) => void,
    alreadyAccepted: () => boolean = () => false): StoredPendingTurn | undefined {
    if (!turn.userEventId) throw new Error("OpenClaw queued turn requires userEventId");
    const turns = this.readPending();
    let stored = turns.find((item) => item.userEventId === turn.userEventId);
    if (!stored && alreadyAccepted()) {
      accept();
      return undefined;
    }
    if (!stored) {
      const runId = randomUUID();
      stored = {
        threadId: turn.threadId,
        sessionKey: `agent:main:yorozu:${turn.threadId}`.toLowerCase(),
        runId,
        startedAt: Date.now(),
        completionId: turn.completionId ?? `openclaw:${turn.userEventId}:final`,
        userEventId: turn.userEventId,
        awaitsAnnouncement: false,
        taskIds: [], childRunIds: [], state: "queued",
        input: { text: turn.text, ...(turn.model ? { model: turn.model } : {}),
          ...(turn.effort ? { effort: turn.effort } : {}), attachments: turn.attachments ?? [] },
      };
      this.writePending([...turns, stored]);
    }
    accept(stored);
    return stored;
  }

  acknowledge(threadId: string, completionId: string): void {
    const turns = this.readPending();
    const head = turns.find((item) => item.threadId === threadId);
    if (head?.completionId !== completionId) return;
    this.writePending(turns.filter((item) => item !== head));
  }

  async run(turn: OpenClawTurn): Promise<string | undefined> {
    if (turn.signal?.aborted) return "";
    const sessionKey = `agent:main:yorozu:${turn.threadId}`.toLowerCase();
    const stored = turn.userEventId
      ? this.readPending().find((item) => item.userEventId === turn.userEventId)
      : undefined;
    const input = stored?.input ?? { text: turn.text, model: turn.model, effort: turn.effort, attachments: turn.attachments ?? [] };
    let client: Gateway | undefined;
    const { pending, completed } = this.createPending({ ...turn, ...input,
      completionId: stored?.completionId ?? turn.completionId }, () => client, sessionKey,
      stored?.runId ?? randomUUID(), stored?.startedAt ?? Date.now());
    if (!this.#pending.has(pending)) return completed;
    this.storePending(pending);
    void this.dispatch(pending, (connected) => { client = connected; });
    return completed;
  }

  /** Reattaches after process replacement; missing receipt is safely resent with same idempotency key. */
  async resume(turn: Omit<OpenClawTurn, "text">): Promise<string | undefined> {
    const stored = this.readPending().find((item) => item.threadId === turn.threadId && item.state === "active");
    if (!stored) return undefined;
    if (turn.signal?.aborted) {
      this.clearStored(stored);
      return "";
    }
    let client!: Gateway;
    while (!turn.signal?.aborted) {
      try {
        client = await this.connect();
        if (turn.signal?.aborted) {
          this.clearStored(stored);
          return "";
        }
        break;
      } catch {
        if (turn.signal?.aborted) {
          this.clearStored(stored);
          return "";
        }
        await delay(this.#recoveryDelayMs);
      }
    }
    if (turn.signal?.aborted) {
      this.clearStored(stored);
      return "";
    }
    const { pending, completed } = this.createPending({ ...turn, ...stored.input,
      completionId: stored.completionId, userEventId: stored.userEventId }, () => client,
    stored.sessionKey, stored.runId, stored.startedAt);
    pending.awaitsAnnouncement = stored.awaitsAnnouncement;
    for (const taskId of stored.taskIds) pending.tasks.set(taskId, "recovering");
    for (const runId of stored.childRunIds) pending.childRunIds.add(runId);
    await client.request("sessions.subscribe", {}).catch(() => {});
    if (turn.signal?.aborted || !this.#pending.has(pending)) return completed;
    void this.recover(pending, client, () => this.sendStored(client, pending));
    return completed;
  }

  private async dispatch(pending: PendingTurn, connected: (client: Gateway) => void): Promise<Gateway | undefined> {
    while (this.#pending.has(pending)) {
      let client: Gateway;
      try {
        client = await this.connect();
        connected(client);
        if (!this.#pending.has(pending)) return undefined;
        await this.patchStored(client, pending);
        if (!this.#pending.has(pending)) return undefined;
      } catch (error) {
        if (definitiveRejection(error)) {
          pending.resolve(failureText(error));
          return undefined;
        }
        await delay(this.#recoveryDelayMs);
        continue;
      }
      try {
        if (!this.#pending.has(pending)) return client;
        this.activity(pending, "starting", { kind: "thought", data: { text: "Starting OpenClaw…", transient: true } });
        const result = await this.sendChat(client, pending);
        if (!this.#pending.has(pending)) {
          await client.request("chat.abort", { sessionKey: pending.sessionKey, runId: result.runId ?? pending.runId }).catch(() => {});
          return client;
        }
        pending.runId = result.runId ?? pending.runId;
        this.storePending(pending);
        void this.recover(pending, client);
      } catch (error) {
        if (definitiveRejection(error)) pending.resolve(failureText(error));
        else void this.recover(pending, client, () => this.sendStored(client, pending));
      }
      return client;
    }
    return undefined;
  }

  private async recover(pending: PendingTurn, client: Gateway, resend?: () => Promise<{ runId?: string }>): Promise<void> {
    while (this.#pending.has(pending)) {
      try {
        const history = await client.request<History>("chat.history", {
          sessionKey: pending.sessionKey, limit: 1000, inputRunIds: [pending.runId],
        });
        if (!this.#pending.has(pending)) return;
        const snapshot = history.inFlightRun;
        if (snapshot && snapshot.runId === pending.runId) {
          this.restoreSnapshot(pending, snapshot);
          await delay(this.#recoveryDelayMs);
          continue;
        }
        this.restoreHistory(pending, history.messages ?? []);
        const final = correlatedFinal(history.messages ?? [], pending);
        if (final.found) { await this.finish(client, pending, final.text, history.messages); return; }
        const accepted = history.inputReceipts?.some((receipt) => receipt.runId === pending.runId);
        if (resend && !accepted) {
          const result = await resend();
          if (!this.#pending.has(pending) || pending.signal?.aborted) {
            await client.request("chat.abort", {
              sessionKey: pending.sessionKey, runId: result.runId ?? pending.runId,
            }).catch(() => {});
            return;
          }
          pending.runId = result.runId ?? pending.runId;
          this.storePending(pending);
          await delay(this.#recoveryDelayMs);
          continue;
        }
      } catch (error) {
        if (definitiveRejection(error)) {
          pending.resolve(failureText(error));
          return;
        }
        // Keep durable ownership. Same idempotency key makes resend safe.
      }
      await delay(this.#recoveryDelayMs);
    }
  }

  private async sendStored(client: Gateway, pending: PendingTurn): Promise<{ runId?: string }> {
    await this.patchStored(client, pending);
    if (!this.#pending.has(pending) || pending.signal?.aborted) return {};
    return this.sendChat(client, pending);
  }

  private async patchStored(client: Gateway, pending: PendingTurn): Promise<void> {
    if (pending.input.model || pending.input.effort) await client.request("sessions.patch", {
      key: pending.sessionKey, ...(pending.input.model ? { model: pending.input.model } : {}),
      ...(pending.input.effort ? { thinkingLevel: pending.input.effort } : {}),
    });
  }

  private sendChat(client: Gateway, pending: PendingTurn): Promise<{ runId?: string }> {
    return client.request("chat.send", {
      sessionKey: pending.sessionKey, message: pending.input.text,
      attachments: gatewayAttachments(pending.input.attachments), thinking: pending.input.effort,
      deliver: false, idempotencyKey: pending.runId,
    });
  }

  private createPending(turn: OpenClawTurn, client: () => Gateway | undefined, sessionKey: string, runId: string, startedAt: number): { pending: PendingTurn; completed: Promise<string> } {
    let pending!: PendingTurn;
    const completed = new Promise<string>((resolve, reject) => {
      pending = { threadId: turn.threadId, sessionKey, runId, startedAt, completionId: turn.completionId, userEventId: turn.userEventId, seen: new Set(turn.seenEventIds), calls: new Set(), tasks: new Map(), childRunIds: new Set(),
        input: { text: turn.text, ...(turn.model ? { model: turn.model } : {}), ...(turn.effort ? { effort: turn.effort } : {}), attachments: turn.attachments ?? [] },
        signal: turn.signal, onEvent: turn.onEvent, awaitsAnnouncement: false, text: "", onUpdate: turn.onUpdate, resolve, reject };
      this.#pending.add(pending);
      const abort = () => {
        this.#pending.delete(pending);
        this.clearPending(pending);
        void client()?.request("chat.abort", { sessionKey, runId: pending.runId });
        resolve("");
      };
      turn.signal?.addEventListener("abort", abort, { once: true });
      const finish = (fn: () => void) => {
        turn.signal?.removeEventListener("abort", abort);
        this.#pending.delete(pending);
        fn();
      };
      pending.resolve = (text) => finish(() => resolve(text));
      pending.reject = (error) => finish(() => reject(error));
      if (turn.signal?.aborted) abort();
    });
    return { pending, completed };
  }

  private connect(): Promise<Gateway> {
    if (this.#client) return Promise.resolve(this.#client);
    return this.#connecting ??= this.createClient();
  }

  private async createClient(): Promise<Gateway> {
    let stored = this.readStoredAuth();
    let setup: SetupCode | undefined;
    if (!stored?.token) {
      setup = await this.readSetupCode();
      stored ??= { identity: createIdentity() };
      this.writeStoredAuth(stored);
    }

    const ready = Promise.withResolvers<Gateway>();
    const hostDeps: GatewayClientHostDeps = {
      signDevicePayload: (pem, payload) => sign(null, Buffer.from(payload), createPrivateKey(pem)).toString("base64url"),
      publicKeyRawBase64UrlFromPem: (pem) => rawPublicKey(pem).toString("base64url"),
      loadDeviceAuthToken: () => stored?.token ? { token: stored.token, scopes: stored.scopes } : null,
      storeDeviceAuthToken: ({ token, scopes }) => {
        stored = { identity: stored!.identity, token, scopes };
        this.writeStoredAuth(stored);
      },
      clearDeviceAuthToken: () => {
        stored = { identity: stored!.identity };
        this.writeStoredAuth(stored);
      },
    };
    this.#httpBase = (setup?.url ?? DEFAULT_GATEWAY_URL).replace(/^ws/, "http");
    const client = this.#clientFactory({
      url: setup?.url ?? DEFAULT_GATEWAY_URL,
      bootstrapToken: setup?.bootstrapToken,
      preferBootstrapToken: Boolean(setup),
      deviceIdentity: stored.identity,
      hostDeps,
      clientName: "gateway-client",
      clientDisplayName: "Yorozu",
      mode: "backend",
      role: "operator",
      scopes: ["operator.read", "operator.write"],
      caps: ["tool-events"],
      minProtocol: 4,
      maxProtocol: 4,
      onEvent: (event) => this.handleEvent(event),
      onHelloOk: () => {
        this.#client = client;
        ready.resolve(client);
        // Tool recipient IDs belong to the old connection. The installed Gateway exposes
        // ongoing tools via session.tool after reconnect; filter those by our active run.
        if (this.#pending.size) void client.request("sessions.subscribe", {}).catch(() => {});
        for (const pending of this.#pending) void this.restoreProgress(client, pending);
      },
      onClose: () => {
        for (const pending of this.#pending) this.activity(pending, `reconnecting:${Date.now()}`, {
          kind: "thought", data: { text: "Reconnecting to OpenClaw…", transient: true },
        });
      },
      onConnectError: (error) => ready.reject(error),
    });
    client.start();
    try {
      return await ready.promise;
    } catch (error) {
      client.stop();
      this.#connecting = undefined;
      throw error;
    }
  }

  private handleEvent(event: EventFrame): void {
    if (!event.payload || typeof event.payload !== "object") return;
    const payload = event.payload as Record<string, unknown>;
    if (event.event === "agent" || event.event === "session.tool") {
      const sessionKey = string(payload.sessionKey).toLowerCase();
      const pending = [...this.#pending].find((item) => item.sessionKey === sessionKey && item.runId === payload.runId);
      if (pending) this.agentActivity(pending, payload);
      return;
    }
    if (event.event === "task") {
      const task = payload.task;
      if (payload.action === "upserted" && task && typeof task === "object") {
        const record = task as Record<string, unknown>;
        const sessionKey = string(record.sessionKey ?? record.ownerKey).toLowerCase();
        const pending = [...this.#pending].find((item) => item.sessionKey === sessionKey);
        if (!pending || typeof record.createdAt !== "number" || record.createdAt < pending.startedAt) return;
        const deliveryStatus = record.deliveryStatus;
        if (pending && (deliveryStatus === "pending" || deliveryStatus === "in_progress")) {
          pending.awaitsAnnouncement = true;
          this.storePending(pending);
        }
        const taskId = string(record.id ?? record.taskId);
        const childRunId = string(record.runId ?? record.childRunId);
        if (childRunId && !pending.childRunIds.has(childRunId)) {
          pending.childRunIds.add(childRunId);
          this.storePending(pending);
        }
        const status = string(record.status);
        if (taskId && taskId.length <= 256 && status && pending.tasks.get(taskId) !== status) {
          pending.tasks.set(taskId, status);
          this.storePending(pending);
          const agentId = `${activityText(record.title ?? record.label ?? record.agentId).slice(0, 120) || "Delegated work"} · ${taskId.slice(0, 8)}`;
          const terminal = ["completed", "succeeded", "failed", "timed_out", "cancelled", "lost"].includes(status);
          this.activity(pending, `task:${taskId}:${status}`, terminal ? {
            kind: "message", data: { role: "agent", text: `Delegated work ${status.replaceAll("_", " ")}.`, done: true },
          } : { kind: "thought", data: { text: `Delegated work ${status}.` } }, agentId);
        }
      }
      return;
    }
    if (event.event !== "chat") return;
    const sessionKey = string(payload.sessionKey).toLowerCase();
    const runId = typeof payload.runId === "string" ? payload.runId : undefined;
    const pending = [...this.#pending].find(
      (item) => item.sessionKey === sessionKey && (
        !item.runId || item.runId === runId || (
          item.awaitsAnnouncement && announcementMatches(runId, item.childRunIds)
        )
      ),
    );
    if (!pending || !runId) return;
    const key = `chat:${runId}:${payload.seq}:${payload.state}`;
    if (pending.seen.has(key)) return;
    pending.seen.add(key);
    if (payload.state === "delta") {
      const delta = typeof payload.deltaText === "string" ? payload.deltaText : "";
      pending.text = payload.replace === true ? delta : pending.text + delta;
      if (pending.text) pending.onUpdate?.(pending.text);
    } else if (payload.state === "final") {
      const text = messageText(payload.message) || pending.text;
      if (!pending.awaitsAnnouncement || announcementMatches(runId, pending.childRunIds)) void this.finish(this.#client, pending, text);
      else if (text) pending.onUpdate?.(text);
    } else if (payload.state === "aborted") {
      pending.resolve("");
    } else if (payload.state === "error") {
      const detail = typeof payload.errorMessage === "string" ? payload.errorMessage : "unknown error";
      pending.resolve("OpenClaw turn failed: " + detail);
    }
  }

  /**
   * Images the agent sent (message tool, image generation) live only in the transcript as
   * Gateway-hosted blocks: the final chat event carries text alone. Each becomes its own
   * inline agent message before the text final, so a relay client shows it like a user photo.
   * Fetch failures drop the image rather than the turn.
   */
  private async finish(client: Gateway | undefined, pending: PendingTurn, text: string, messages?: unknown[]): Promise<void> {
    if (client && pending.onEvent) try {
      messages ??= (await client.request<History>("chat.history", {
        sessionKey: pending.sessionKey, limit: 1000, inputRunIds: [pending.runId],
      })).messages ?? [];
      for (const value of messages) {
        const message = record(value);
        if (message.role !== "assistant" || string(record(message.__openclaw).runId ?? message.runId) !== pending.runId) continue;
        for (const blockValue of Array.isArray(message.content) ? message.content : []) {
          const block = record(blockValue);
          const artifactId = string(block.artifactId);
          if (block.type !== "image" || !artifactId || pending.seen.has(`openclaw:${pending.runId}:image:${artifactId}`)) continue;
          const attachment = await this.fetchImage(client, pending.sessionKey, artifactId, string(block.mimeType), string(block.alt));
          if (attachment) this.activity(pending, `image:${artifactId}`, { kind: "message", data: { role: "agent", text: "", attachments: [attachment] } });
        }
      }
    } catch {
      // Text still answers the turn.
    }
    pending.resolve(text);
  }

  private async fetchImage(client: Gateway, sessionKey: string, artifactId: string, mime: string, name: string): Promise<MessageAttachment | undefined> {
    const { url } = await client.request<{ url?: string }>("artifacts.download", { sessionKey, artifactId });
    if (!url) return undefined;
    const response = await this.#fetch(new URL(url, this.#httpBase));
    if (!response.ok) return undefined;
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.byteLength > ATTACHMENT_MAX_BYTES) return undefined;
    return { name: name || artifactId, mime: response.headers.get("content-type")?.split(";")[0] || mime || "image/*", data: bytes.toString("base64") };
  }

  private activity(pending: PendingTurn, key: string, payload: EventPayload, agentId = "main"): void {
    const id = `openclaw:${pending.runId}:${key}`;
    if (pending.seen.has(id)) return;
    pending.seen.add(id);
    pending.onEvent?.({ id, threadId: pending.threadId, ts: Date.now(), agentId,
      ...(agentId !== "main" ? { parentAgentId: "main" } : {}), ...payload });
  }

  private agentActivity(pending: PendingTurn, payload: Record<string, unknown>): void {
    const data = record(payload.data);
    const phase = string(data.phase);
    const key = `agent:${payload.seq}:${payload.stream}`;
    if (payload.stream === "tool") {
      const rawId = string(data.toolCallId);
      if (!rawId || rawId.length > 256) return;
      const callId = `${pending.runId}:${rawId}`;
      if (!pending.calls.has(callId)) {
        pending.calls.add(callId);
        this.activity(pending, `call:${rawId}`, { kind: "tool_call", data: {
          callId, name: activityText(data.name).slice(0, 128) || "Tool", args: record(safeActivityValue(data.args)),
        } });
        // The card comes from the call itself, not only the plan stream: history replay after
        // a failed or reattached run carries tool calls but never plan events.
        if (data.name === "progress_card") {
          const args = record(data.args);
          if (typeof args.markdown === "string" && args.markdown.trim()) pending.progressNote = activityText(args.markdown.trim());
          if (Array.isArray(args.plan)) this.progressCard(pending, `progress:${rawId}`, args.plan);
        }
      }
      if (phase === "result") this.activity(pending, `result:${rawId}`, { kind: "tool_result", data: {
        callId, ok: data.isError !== true,
        output: activityText(data.result ?? data.output ?? "Completed"),
      } });
    } else if (payload.stream === "reasoning" || (payload.stream === "lifecycle" && phase === "start")) {
      this.activity(pending, "thinking", { kind: "thought", data: { text: "Thinking…", transient: true } });
    } else if (payload.stream === "run_status") {
      if (phase) this.activity(pending, key, { kind: "thought", data: { text: `${phase.replaceAll("_", " ")}…`, transient: true } });
    } else if (payload.stream === "item" && data.kind === "preamble" && phase !== "delta") {
      const text = activityText(data.text ?? data.content ?? "");
      if (text) this.activity(pending, key, { kind: "thought", data: { text } });
    } else if (payload.stream === "plan" && Array.isArray(data.steps)) {
      this.progressCard(pending, key, data.steps);
    }
  }

  private progressCard(pending: PendingTurn, key: string, plan: unknown[]): void {
    this.activity(pending, key, { kind: "progress_card", data: {
      cardId: `openclaw-plan:${pending.runId}`, title: "Progress",
      ...(pending.progressNote ? { note: pending.progressNote } : {}),
      steps: plan.slice(0, 30).map((step) => {
        const item = record(step);
        const status = item.status ?? item.state;
        return { label: activityText(item.step ?? item.label), state: status === "completed" ? "done" : status === "in_progress" ? "running" : status === "failed" ? "failed" : "pending" };
      }),
    } });
  }

  private async restoreProgress(client: Gateway, pending: PendingTurn): Promise<void> {
    try {
      const history = await client.request<{ inFlightRun?: Record<string, unknown> }>("chat.history", { sessionKey: pending.sessionKey, limit: 1 });
      const snapshot = history.inFlightRun;
      if (!this.#pending.has(pending) || !snapshot || snapshot.runId !== pending.runId) return;
      this.restoreSnapshot(pending, snapshot);
    } catch {
      // Connection recovery remains owned by GatewayClient. Never replay chat.send.
    }
  }

  private restoreSnapshot(pending: PendingTurn, snapshot: Record<string, unknown>): void {
    if (Array.isArray(snapshot.events)) for (const event of snapshot.events) this.agentActivity(pending, record(event));
    if (typeof snapshot.text === "string" && snapshot.text) {
      pending.text = snapshot.text;
      pending.onUpdate?.(pending.text);
    }
  }

  private restoreHistory(pending: PendingTurn, messages: unknown[]): void {
    const start = messages.findIndex((value) => {
      const message = record(value);
      return string(record(message.__openclaw).runId ?? message.runId) === pending.runId && message.role === "user";
    });
    const end = messages.findIndex((value, index) => {
      if (index < start) return false;
      const message = record(value);
      return message.role === "assistant" &&
        string(record(message.__openclaw).runId ?? message.runId) === pending.runId &&
        ["stop", "length", "error", "aborted"].includes(string(message.stopReason));
    });
    for (const [index, value] of messages.entries()) {
      const message = record(value);
      const meta = record(message.__openclaw);
      const owner = string(meta.runId ?? message.runId);
      if (owner !== pending.runId && !(start >= 0 && index >= start && (end < 0 || index <= end))) continue;
      for (const blockValue of Array.isArray(message.content) ? message.content : []) {
        const block = record(blockValue);
        const type = string(block.type);
        const rawId = string(block.id ?? block.toolCallId);
        if (type === "toolCall" && rawId) this.agentActivity(pending, {
          runId: pending.runId, stream: "tool", seq: block.seq ?? rawId,
          data: { phase: "start", toolCallId: rawId, name: block.name, args: block.arguments },
        });
      }
      if (message.role === "toolResult") {
        const rawId = string(message.toolCallId);
        if (rawId) this.agentActivity(pending, {
          runId: pending.runId, stream: "tool", seq: message.seq ?? rawId,
          data: { phase: "result", toolCallId: rawId, name: message.name, result: message.content, isError: message.isError },
        });
      }
    }
    this.storePending(pending);
  }

  private readPending(requireKnown = false): StoredPendingTurn[] {
    let raw: string;
    try {
      raw = readFileSync(this.#pendingFile, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
      throw error;
    }
    // A damaged ledger is not an empty ledger: accepting a new turn would overwrite ownership
    // of existing work and could acknowledge an operation the host cannot recover.
    const value = JSON.parse(raw);
    if (!Array.isArray(value)) throw new Error(requireKnown ? "Unknown pending agent state" : "Damaged pending agent state");
    const turns = value.filter((item): item is StoredPendingTurn =>
      item && typeof item.threadId === "string" && typeof item.sessionKey === "string" &&
      typeof item.runId === "string" && typeof item.startedAt === "number")
      .map((item) => ({ ...item,
        completionId: typeof item.completionId === "string" ? item.completionId : `openclaw:${item.runId}:final`,
        awaitsAnnouncement: item.awaitsAnnouncement === true,
        taskIds: Array.isArray(item.taskIds) ? item.taskIds.filter((id): id is string => typeof id === "string") : [],
        childRunIds: Array.isArray(item.childRunIds) ? item.childRunIds.filter((id): id is string => typeof id === "string") : [],
        input: storedInput(item.input),
        state: item.state === "queued" ? "queued" as const : "active" as const,
      }));
    if (turns.length !== value.length) throw new Error(requireKnown ? "Unknown pending agent state" : "Damaged pending agent state");
    return turns;
  }

  private storePending(pending: PendingTurn): void {
    const turns = this.readPending();
    const index = turns.findIndex((item) =>
      pending.userEventId ? item.userEventId === pending.userEventId : item.threadId === pending.threadId);
    const current = turns[index];
    const stored: StoredPendingTurn = {
      threadId: pending.threadId, sessionKey: pending.sessionKey, runId: pending.runId!, startedAt: pending.startedAt,
      completionId: current?.completionId ?? pending.completionId ?? `openclaw:` + pending.runId + `:final`,
      ...(current?.userEventId ?? pending.userEventId ? { userEventId: current?.userEventId ?? pending.userEventId } : {}),
      awaitsAnnouncement: pending.awaitsAnnouncement, taskIds: [...pending.tasks.keys()],
      childRunIds: [...pending.childRunIds], input: pending.input, state: "active",
    };
    if (index >= 0) turns[index] = stored;
    else turns.push(stored);
    this.writePending(turns);
  }

  private clearPending(pending: PendingTurn): void {
    this.writePending(this.readPending().filter((item) => pending.userEventId ? item.userEventId !== pending.userEventId : item.threadId !== pending.threadId));
  }

  private clearStored(stored: StoredPendingTurn): void {
    this.writePending(this.readPending().filter((item) => stored.userEventId
      ? item.userEventId !== stored.userEventId
      : item.threadId !== stored.threadId || item.runId !== stored.runId));
  }

  private writePending(turns: StoredPendingTurn[]): void {
    mkdirSync(dirname(this.#pendingFile), { recursive: true });
    const temporary = `${this.#pendingFile}.tmp`;
    writeFileSync(temporary, JSON.stringify(turns), { mode: 0o600 });
    renameSync(temporary, this.#pendingFile);
  }

  private readStoredAuth(): StoredGatewayAuth | undefined {
    try {
      const value = JSON.parse(readFileSync(this.#stateFile, "utf8")) as StoredGatewayAuth;
      return value.identity?.deviceId ? value : undefined;
    } catch {
      return undefined;
    }
  }

  private writeStoredAuth(auth: StoredGatewayAuth): void {
    mkdirSync(dirname(this.#stateFile), { recursive: true });
    writeFileSync(this.#stateFile, JSON.stringify(auth), { mode: 0o600 });
  }

  private readSetupCode(): Promise<SetupCode> {
    return new Promise((resolve, reject) => {
      const child = this.#spawn(this.#command, ["qr", "--setup-code-only", "--url", DEFAULT_GATEWAY_URL], {
        stdio: ["ignore", "pipe", "pipe"],
      });
      let stdout = "";
      child.stdout?.setEncoding("utf8");
      child.stdout?.on("data", (chunk: string) => (stdout += chunk));
      child.on("error", reject);
      child.on("close", (code) => {
        if (code !== 0) return reject(new Error(`openclaw setup exited ${code}`));
        try {
          const encoded = stdout.trim().replace(/^oc-pair:\/\//, "");
          const decoded = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")) as SetupCode;
          if (!decoded.url || !decoded.bootstrapToken) throw new Error("invalid setup code");
          resolve(decoded);
        } catch {
          reject(new Error("openclaw returned invalid setup code"));
        }
      });
    });
  }
}

function createIdentity(): DeviceIdentity {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const publicKeyPem = publicKey.export({ type: "spki", format: "pem" }).toString();
  return {
    deviceId: createHash("sha256").update(rawPublicKey(publicKeyPem)).digest("hex"),
    publicKeyPem,
    privateKeyPem: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
  };
}

function rawPublicKey(pem: string): Buffer {
  return createPublicKey(pem).export({ type: "spki", format: "der" }).subarray(-32);
}
interface History { messages?: unknown[]; inFlightRun?: Record<string, unknown>; inputReceipts?: Array<{ runId?: string; state?: string }> }
function correlatedFinal(messages: unknown[], pending: Pick<PendingTurn, "runId" | "awaitsAnnouncement" | "childRunIds">): { found: boolean; text: string } {
  for (const value of [...messages].reverse()) {
    const message = record(value);
    if (message.role !== "assistant") continue;
    const meta = record(message.__openclaw);
    const runId = string(meta.runId ?? message.runId);
    const terminal = ["stop", "length", "error", "aborted"].includes(string(message.stopReason));
    const exact = pending.awaitsAnnouncement
      ? announcementMatches(runId, pending.childRunIds)
      : runId === pending.runId;
    if (exact && terminal) {
      const text = messageText(message).replace(/^NO_REPLY$/i, "");
      return { found: true, text: string(message.stopReason) === "error"
        ? "OpenClaw turn failed: " + (text || "unknown error") : text };
    }
  }
  return { found: false, text: "" };
}
function definitiveRejection(error: unknown): boolean {
  const value = record(error);
  const code = string(value.code);
  return value.retryable === false || ["INVALID_REQUEST", "UNAUTHORIZED", "FORBIDDEN", "NOT_FOUND"].includes(code);
}
function failureText(error: unknown): string {
  const value = record(error);
  return "OpenClaw turn failed: " + (error instanceof Error ? error.message : string(value.message) || String(error));
}
function announcementMatches(runId: unknown, childRunIds: Set<string>): boolean {
  const id = string(runId);
  if (!id.startsWith("announce:requester-settle:")) return false;
  const batch = id.replace(/:yield-[^:]+$/, "").split(":").at(-1)?.split(",") ?? [];
  return batch.some((childRunId) => childRunIds.has(childRunId));
}
function storedInput(value: unknown): StoredTurnInput {
  const item = record(value);
  return {
    text: string(item.text),
    ...(typeof item.model === "string" ? { model: item.model } : {}),
    ...(typeof item.effort === "string" ? { effort: item.effort as ReasoningEffort } : {}),
    attachments: Array.isArray(item.attachments) ? item.attachments as MessageAttachment[] : [],
  };
}
const delay = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

function messageText(value: unknown): string {
  if (!value || typeof value !== "object") return "";
  const content = (value as { content?: unknown }).content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.flatMap((item) => {
    const block = item as { type?: string; text?: unknown };
    return block.type === "text" && typeof block.text === "string" ? [block.text] : [];
  }).join("\n");
}

function gatewayAttachments(attachments: MessageAttachment[] | undefined): object[] | undefined {
  if (!attachments?.length) return undefined;
  return attachments.map((attachment) => ({
    type: attachment.mime.startsWith("image/") ? "image" : "file",
    mimeType: attachment.mime,
    fileName: attachment.name,
    content: attachment.data,
    sizeBytes: Buffer.from(attachment.data, "base64").byteLength,
  }));
}

const string = (value: unknown): string => typeof value === "string" ? value : "";
const record = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};

/** Display-only copy: bounded before persistence/relay; never forward binary or credential fields. */
function safeActivityValue(value: unknown): unknown {
  let remaining = 12_000;
  const visit = (value: unknown, depth: number): unknown => {
    if (remaining <= 0 || depth > 4) return "[omitted]";
    if (typeof value === "string") {
      if (value.length > 65_536) return "[oversized content omitted]";
      const redacted = value
        .replace(/-----BEGIN [\s\S]*?PRIVATE KEY-----[\s\S]*?-----END [\s\S]*?PRIVATE KEY-----/g, "[redacted]")
        .replace(/\bBearer\s+[^\s"']+/gi, "Bearer [redacted]")
        .replace(/\b(password|passwd|secret|(?:access[_-]?|refresh[_-]?)?token|api[_-]?key|authorization|cookie)\b(["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;}]+)/gi, "$1$2[redacted]")
        .replace(/\b(?:sk-[a-zA-Z0-9_-]{16,}|gh[pousr]_[a-zA-Z0-9]{20,})\b/g, "[redacted]")
        .replace(/data:[^\s;,]+;base64,[a-zA-Z0-9+/=]+/g, "[binary omitted]");
      const result = redacted.slice(0, remaining);
      remaining -= result.length;
      return result + (result.length < redacted.length ? "… [truncated]" : "");
    }
    if (Array.isArray(value)) return value.slice(0, 30).map((item) => visit(item, depth + 1));
    if (value && typeof value === "object" && ["image", "image_url", "base64", "file"].includes(string(record(value).type))) return "[binary omitted]";
    if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).slice(0, 30).map(([key, item]) => {
      remaining -= key.length + 8;
      return [key.slice(0, 100), /password|passwd|secret|token|authorization|cookie|api.?key|private.?key|base64|image|screenshot/i.test(key)
        ? "[redacted]" : visit(item, depth + 1)];
    }));
    return typeof value === "number" || typeof value === "boolean" || value === null ? value : "";
  };
  return visit(value, 0);
}

function activityText(value: unknown): string {
  const safe = safeActivityValue(value);
  return (typeof safe === "string" ? safe : JSON.stringify(safe)).slice(0, 14_000);
}
