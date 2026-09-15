import { spawn } from "node:child_process";
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, randomUUID, sign } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { GatewayClient, type DeviceIdentity, type GatewayClientHostDeps } from "@openclaw/gateway-client";
import type { EventFrame } from "@openclaw/gateway-protocol/frame-guards";
import type { EventPayload, MessageAttachment, ModelOption, ReasoningEffort, YorozuEvent } from "@yorozu/shared";

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
  seen: Set<string>;
  calls: Set<string>;
  tasks: Map<string, string>;
  onEvent?: (event: YorozuEvent) => void;
  awaitsAnnouncement: boolean;
  text: string;
  onUpdate?: (text: string) => void;
  resolve: (text: string) => void;
  reject: (error: Error) => void;
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
}

export interface OpenClawRunnerOptions {
  command?: string;
  stateDir?: string;
  spawnProcess?: typeof spawn;
  clientFactory?: (options: ConstructorParameters<typeof GatewayClient>[0]) => Gateway;
}

/** Thin Gateway bridge. OpenClaw owns sessions, tools, credentials, and policy. */
export class OpenClawRunner {
  readonly #command: string;
  readonly #stateFile: string;
  readonly #spawn: typeof spawn;
  readonly #clientFactory: NonNullable<OpenClawRunnerOptions["clientFactory"]>;
  readonly #pending = new Set<PendingTurn>();
  #client?: Gateway;
  #connecting?: Promise<Gateway>;

  constructor(options: OpenClawRunnerOptions = {}) {
    this.#command = options.command ?? process.env.OPENCLAW_BIN ?? "openclaw";
    this.#stateFile = join(options.stateDir ?? process.env.YOROZU_STATE_DIR ?? ".", "openclaw-gateway.json");
    this.#spawn = options.spawnProcess ?? spawn;
    this.#clientFactory = options.clientFactory ?? ((clientOptions) => new GatewayClient(clientOptions));
  }

  async listModels(): Promise<ModelOption[]> {
    const result = await (await this.connect()).request<{ models?: unknown[] }>("models.list", {});
    return (result.models ?? []).flatMap((value) => {
      if (!value || typeof value !== "object") return [];
      const model = value as Record<string, unknown>;
      const id = typeof model.id === "string" ? model.id : "";
      const provider = typeof model.provider === "string" ? model.provider : "";
      if (!id || !provider || model.available === false) return [];
      return [{
        id: `${provider}/${id}`,
        label: typeof model.alias === "string" && model.alias ? model.alias : id,
        providerLabel: provider,
      }];
    });
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

  async run(turn: OpenClawTurn): Promise<string | undefined> {
    if (turn.signal?.aborted) return "";
    const client = await this.connect();
    const sessionKey = `agent:main:yorozu:${turn.threadId}`.toLowerCase();
    const active = [...this.#pending].find((item) => item.sessionKey === sessionKey);
    if (active) {
      await client.request("chat.send", {
        sessionKey,
        message: turn.text,
        attachments: gatewayAttachments(turn.attachments),
        queueMode: "steer",
        deliver: false,
        idempotencyKey: randomUUID(),
      });
      return undefined;
    }
    if (turn.model || turn.effort) {
      await client.request("sessions.patch", {
        key: sessionKey,
        ...(turn.model ? { model: turn.model } : {}),
        ...(turn.effort ? { thinkingLevel: turn.effort } : {}),
      });
    }

    let pending!: PendingTurn;
    const completed = new Promise<string>((resolve, reject) => {
      pending = {
        threadId: turn.threadId, sessionKey, runId: randomUUID(), startedAt: Date.now(),
        seen: new Set(), calls: new Set(), tasks: new Map(), onEvent: turn.onEvent,
        awaitsAnnouncement: false, text: "", onUpdate: turn.onUpdate, resolve, reject,
      };
      this.#pending.add(pending);
      const abort = () => {
        this.#pending.delete(pending);
        void client.request("chat.abort", { sessionKey, ...(pending.runId ? { runId: pending.runId } : {}) });
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
    });

    try {
      this.activity(pending, "starting", { kind: "thought", data: { text: "Starting OpenClaw…", transient: true } });
      const result = await client.request<{ runId?: string }>("chat.send", {
        sessionKey,
        message: turn.text,
        attachments: gatewayAttachments(turn.attachments),
        thinking: turn.effort,
        deliver: false,
        idempotencyKey: pending.runId,
      });
      pending.runId = result.runId ?? pending.runId;
    } catch (error) {
      pending.reject(error instanceof Error ? error : new Error(String(error)));
    }
    return completed;
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
        }
        const taskId = string(record.id ?? record.taskId);
        const status = string(record.status);
        if (taskId && taskId.length <= 256 && status && pending.tasks.get(taskId) !== status) {
          pending.tasks.set(taskId, status);
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
          item.awaitsAnnouncement && runId?.startsWith("announce:requester-settle:")
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
      if (!pending.awaitsAnnouncement || runId.startsWith("announce:requester-settle:")) pending.resolve(text);
      else if (text) pending.onUpdate?.(text);
    } else if (payload.state === "aborted") {
      pending.resolve("");
    } else if (payload.state === "error") {
      pending.reject(new Error(typeof payload.errorMessage === "string" ? payload.errorMessage : "OpenClaw turn failed"));
    }
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
      const cardId = `openclaw-plan:${pending.runId}`;
      this.activity(pending, key, { kind: "progress_card", data: {
        cardId, title: "Progress", steps: data.steps.slice(0, 30).map((step) => {
          const item = record(step);
          const status = item.status ?? item.state;
          return { label: activityText(item.step ?? item.label), state: status === "completed" ? "done" : status === "in_progress" ? "running" : status === "failed" ? "failed" : "pending" };
        }),
      } });
    }
  }

  private async restoreProgress(client: Gateway, pending: PendingTurn): Promise<void> {
    try {
      const history = await client.request<{ inFlightRun?: Record<string, unknown> }>("chat.history", { sessionKey: pending.sessionKey, limit: 1 });
      const snapshot = history.inFlightRun;
      if (!this.#pending.has(pending) || !snapshot || snapshot.runId !== pending.runId) return;
      if (Array.isArray(snapshot.events)) for (const event of snapshot.events) this.agentActivity(pending, record(event));
      if (typeof snapshot.text === "string" && snapshot.text) {
        pending.text = snapshot.text;
        pending.onUpdate?.(pending.text);
      }
    } catch {
      // Connection recovery remains owned by GatewayClient. Never replay chat.send.
    }
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
