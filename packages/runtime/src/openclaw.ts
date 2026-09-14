import { spawn } from "node:child_process";
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, randomUUID, sign } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { GatewayClient, type DeviceIdentity, type GatewayClientHostDeps } from "@openclaw/gateway-client";
import type { EventFrame } from "@openclaw/gateway-protocol/frame-guards";
import type { MessageAttachment, ReasoningEffort } from "@yorozu/shared";

const DEFAULT_GATEWAY_URL = "ws://127.0.0.1:18789";

interface StoredGatewayAuth { identity: DeviceIdentity; token?: string; scopes?: string[] }
interface SetupCode { url: string; bootstrapToken: string }
interface Gateway {
  start(): void;
  stop(): void;
  request<T = Record<string, unknown>>(method: string, params?: unknown): Promise<T>;
}
interface PendingTurn {
  sessionKey: string;
  runId?: string;
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

  async run(turn: OpenClawTurn): Promise<string | undefined> {
    if (turn.signal?.aborted) return "";
    const client = await this.connect();
    const sessionKey = `agent:main:yorozu:${turn.threadId}`;
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
      pending = { sessionKey, text: "", onUpdate: turn.onUpdate, resolve, reject };
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
      const result = await client.request<{ runId?: string }>("chat.send", {
        sessionKey,
        message: turn.text,
        attachments: gatewayAttachments(turn.attachments),
        thinking: turn.effort,
        deliver: false,
        idempotencyKey: randomUUID(),
      });
      pending.runId = result.runId;
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
      minProtocol: 4,
      maxProtocol: 4,
      onEvent: (event) => this.handleEvent(event),
      onHelloOk: () => {
        this.#client = client;
        ready.resolve(client);
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
    if (event.event !== "chat" || !event.payload || typeof event.payload !== "object") return;
    const payload = event.payload as Record<string, unknown>;
    const sessionKey = typeof payload.sessionKey === "string" ? payload.sessionKey : undefined;
    const runId = typeof payload.runId === "string" ? payload.runId : undefined;
    const pending = [...this.#pending].find(
      (item) => item.sessionKey === sessionKey && (!item.runId || item.runId === runId),
    );
    if (!pending || !runId) return;
    pending.runId ??= runId;
    if (payload.state === "delta") {
      const delta = typeof payload.deltaText === "string" ? payload.deltaText : "";
      pending.text = payload.replace === true ? delta : pending.text + delta;
      if (pending.text) pending.onUpdate?.(pending.text);
    } else if (payload.state === "final") {
      pending.resolve(messageText(payload.message) || pending.text);
    } else if (payload.state === "aborted") {
      pending.resolve("");
    } else if (payload.state === "error") {
      pending.reject(new Error(typeof payload.errorMessage === "string" ? payload.errorMessage : "OpenClaw turn failed"));
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
