/**
 * The OpenClaw channel socket: `<state dir>/channel.sock`, where OpenClaw's `yorozu` channel
 * plugin connects. Newline-delimited JSON, owner-only like `local.sock`.
 *
 * Both directions are at-least-once and acknowledged by id:
 *  - `deliver` (plugin → host) is an agent message for a thread. The host acks once it is in
 *    the thread's log; a repeat of a logged id is acked again, never logged twice.
 *  - `inbound` (host → plugin) is a user message typed in a channel thread. It sits in
 *    `channel-outbox.json` until the plugin acks it, and is resent whenever a plugin connects.
 *    Ids can repeat after a crash; the plugin dedupes by id.
 */
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import type { ChannelModelChoice, ChannelModelOption, MessageAttachment } from "@yorozu/shared";
import { startLocalChannel, type Send } from "./local.js";
import { hostRequest } from "./rust-host.js";
import { retainSharedSyncHost } from "./rust-sync.js";

export const channelSocketPath = (dir: string): string => join(dir, "channel.sock");

export interface ChannelInbound {
  /** Host outbox marker persisted before sending a quoted request; stripped from plugin frames. */
  replyAttempted?: boolean;
  /** Host-resolved, bounded quoted context; never supplied as command text. */
  replyContext?: { id: string; text: string; sender: string };
  channelModel?: ChannelModelChoice;
  id: string;
  threadId: string;
  ts: number;
  text: string;
  attachments?: MessageAttachment[];
}

export interface ChannelDeliver {
  id: string;
  threadId: string;
  text: string;
  /** Stable triggering run for negotiated reply streaming. */
  messageId?: string;
  interrupted?: boolean;
  failed?: boolean;
  /** Title for a thread this message creates. Ignored when the thread exists. */
  title?: string;
}

export type HostFrame =
  | { type: "hello"; capabilities: string[] }
  | { type: "model_catalog_request" | "model_selection_request"; requestId: string; threadId: string }
  | { type: "model_select"; requestId: string; threadId: string; model: string | null }
  | { type: "inbound"; message: ChannelInbound }
  | { type: "abort"; messageId: string }
  | { type: "ack"; id: string }
  | { type: "error"; id: string; reason: string };

export type RunStatus = "completed" | "failed" | "aborted";
export type PluginFrame = ({ type: "deliver" } & ChannelDeliver)
  | ({ type: "reply_preview" } & ChannelDeliver & { messageId: string })
  | { type: "ack"; id: string }
  | { type: "hello"; capabilities?: string[] }
  | { type: "run_started"; messageId: string }
  | { type: "run_finished"; messageId: string; status: RunStatus }
  | { type: "tool_started"; messageId: string; callId: string; name: string; args: Record<string, unknown> }
  | { type: "tool_finished"; messageId: string; callId: string; ok: boolean; output: string }
  | { type: "model_catalog"; requestId: string; models: ChannelModelOption[] }
  | { type: "model_selection"; requestId: string; model: string | null }
  | { type: "model_select_result"; requestId: string; ok: boolean; model?: string | null; error?: string };

export interface ChannelHostOptions {
  dir: string;
  /** Makes the message durable. Auxiliary SDK prompts do not finish a negotiated answer draft. */
  deliver(message: ChannelDeliver, auxiliary?: boolean): void;
  /** Best-effort snapshot; durable delivery still goes through deliver. */
  preview?(message: ChannelDeliver & { messageId: string }): void;
  forwarded(message: Pick<ChannelInbound, "id" | "threadId">): void;
  runStarted(messageId: string): void;
  runFinished(messageId: string, status: RunStatus): void;
  /** A message went to a run-boundary plugin, which will now report its run. Repeats on resend. */
  handedOff(message: Pick<ChannelInbound, "id" | "threadId">): void;
  /** Rechecked after storage awaits and immediately before dispatch. */
  canDispatch?(messageId: string): boolean;
  /** The last run-boundary plugin disconnected: hand-offs that never started are queued again. */
  runBoundaryLost(): void;
  toolStarted(messageId: string, callId: string, name: string, args: Record<string, unknown>): void;
  toolFinished(messageId: string, callId: string, ok: boolean, output: string): void;
  onError?(message: string): void;
  onCapabilities?(): void;
  onModel?(threadId: string, model: string | null): void;
  onDeliveryError?(message: ChannelInbound, error: string): void;
  /** A queued message that will never be sent, e.g. attachments for a plugin without `media-v1`. */
  onRejected?(message: ChannelInbound, reason: string): void;
}

export interface ChannelHost {
  /** Whether a plugin is connected right now. Messages are queued either way. */
  readonly connected: boolean;
  readonly modelSelection: boolean;
  /** Capabilities announced by the connected plugins. Empty for a legacy plugin, or none. */
  readonly announced: ReadonlySet<string>;
  /** Whether attachments can go out: `unknown` while no plugin is connected or one has not said hello yet. */
  readonly attachments: "supported" | "unsupported" | "unknown";
  refreshModels(threadId: string): Promise<ChannelModelOption[]>;
  selectModel(threadId: string, model: string | null): Promise<void>;
  retry(threadId: string): void;
  /** Queues a user message for OpenClaw. Durable before its promise resolves. */
  forward(message: ChannelInbound): Promise<void>;
  /** Only a proven pre-dispatch withdrawal may remove queued work. */
  withdraw(messageId: string): Promise<void>;
  abort(messageId: string): void;
  close(): Promise<void>;
}

const MAX_ID = 128;
const MAX_TEXT = 256 * 1024;
/** How long a connected plugin may take to say hello before it counts as one that never will. */
const HELLO_GRACE_MS = 1000;
const validModel = (value: unknown): value is string => typeof value === "string" && value.length > 0 && value.length <= 512;
const validId = (value: unknown): value is string =>
  typeof value === "string" && value.length > 0 && value.length <= MAX_ID;

export function startChannelHost(options: ChannelHostOptions): ChannelHost {
  const { dir } = options;
  const releaseStorage = retainSharedSyncHost(dir);
  try {
  let outbox: Pick<ChannelInbound, "id" | "threadId">[] = [];
  let modelDelivery: Record<string, "prepared" | "delivered"> = {};
  let storageTail: Promise<unknown> = Promise.resolve();
  let closing = false;
  const storage = (op: string, data: Record<string, unknown> = {}): Promise<unknown> => {
    const next = storageTail.catch(() => {}).then(async () => {
      const result = await hostRequest(dir, { op, ...data }) as {
        error?: unknown; outbox?: typeof outbox; modelDelivery?: typeof modelDelivery; message?: ChannelInbound | null;
      };
      if (!result || typeof result !== "object" || result.error !== undefined) throw new Error("channel-storage-failed");
      if (op === "outbox_get") return result.message ?? undefined;
      if (!Array.isArray(result.outbox) || !result.outbox.every((m) => validId(m.id) && validId(m.threadId)) ||
          !result.modelDelivery || typeof result.modelDelivery !== "object" ||
          Object.values(result.modelDelivery).some((status) => status !== "prepared" && status !== "delivered")) {
        throw new Error("channel-storage-failed");
      }
      outbox = result.outbox; modelDelivery = result.modelDelivery;
    });
    storageTail = next; return next;
  };
  const recovered = storage("outbox_snapshot").then(() => {
    // Run replay may arrive immediately on connect, before an async drain finishes.
    // Restore ownership from durable metadata before accepting those lifecycle frames.
    for (const message of outbox) options.forwarded(message);
  }).catch(() => options.onError?.("channel-storage-failed"));
  const plugins = new Map<string, Send<HostFrame>>();
  const runBoundaryPlugins = new Set<string>();
  const capable = new Set<string>();
  const progressPlugins = new Set<string>();
  const announcedBy = new Map<string, Set<string>>();
  const mediaPlugins = new Set<string>();
  const undecided = new Map<string, NodeJS.Timeout>();
  const sent = new Map<string, Set<string>>();
  type Response = Extract<PluginFrame, { requestId: string }>;
  const pending = new Map<string, { device: string; type: Response["type"];
    resolve: (frame: Response) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();
  const operations = new Map<string, Promise<unknown>>();
  const draining = new Set<string>();
  const drainAgain = new Set<string>();
  const reason = (error: unknown): string => error instanceof Error ? error.message : String(error);
  const serial = <T>(threadId: string, work: () => Promise<T>): Promise<T> => {
    const next = (operations.get(threadId) ?? Promise.resolve()).catch(() => {}).then(work);
    operations.set(threadId, next);
    void next.finally(() => { if (operations.get(threadId) === next) operations.delete(threadId); }).catch(() => {});
    return next;
  };
  const request = (device: string, frame: HostFrame & { requestId: string }, type: Response["type"]): Promise<Response> =>
    new Promise((resolve, reject) => {
      const send = plugins.get(device);
      if (!send || !capable.has(device)) return reject(new Error("OpenClaw model selection unavailable"));
      const timer = setTimeout(() => {
        pending.delete(frame.requestId);
        reject(new Error("OpenClaw model request timed out"));
      }, 10_000);
      pending.set(frame.requestId, { device, type, resolve, reject, timer });
      send(frame);
    });
  const deviceForModels = (): string => {
    const device = capable.values().next().value;
    if (!device) throw new Error("OpenClaw model selection unavailable");
    return device;
  };
  const catalog = async (device: string, threadId: string): Promise<ChannelModelOption[]> => {
    const frame = await request(device, { type: "model_catalog_request", requestId: randomUUID(), threadId }, "model_catalog");
    if (frame.type !== "model_catalog" || !Array.isArray(frame.models) || frame.models.length > 10_000 ||
        !frame.models.every((m) => m && validModel(m.id) && typeof m.label === "string" &&
          m.label.length > 0 && m.label.length <= 512 && typeof m.available === "boolean" &&
          (m.unavailableReason === undefined || typeof m.unavailableReason === "string" && m.unavailableReason.length <= 2048)) ||
        new Set(frame.models.map((m) => m.id)).size !== frame.models.length) throw new Error("Invalid OpenClaw model catalog");
    return frame.models.map(({ id, label, available, unavailableReason }) => ({ id, label, available,
      ...(unavailableReason !== undefined ? { unavailableReason } : {}) }));
  };
  const select = async (device: string, threadId: string, model: string | null): Promise<void> => {
    if (model !== null) {
      const option = (await catalog(device, threadId)).find((m) => m.id === model);
      if (!option?.available) throw new Error(option?.unavailableReason ?? "OpenClaw model is unavailable or not permitted");
    }
    const frame = await request(device, { type: "model_select", requestId: randomUUID(), threadId, model }, "model_select_result");
    if (frame.type !== "model_select_result" || frame.ok !== true) {
      throw new Error(frame.type === "model_select_result" && typeof frame.error === "string"
        ? frame.error.slice(0, 2048) : "OpenClaw model selection failed");
    }
    if (frame.model !== undefined && frame.model !== null && !validModel(frame.model)) throw new Error("Invalid OpenClaw model selection");
    options.onModel?.(threadId, frame.model === undefined ? model : frame.model);
  };
  const decided = (device: string): void => {
    const timer = undecided.get(device);
    if (!timer) return;
    clearTimeout(timer);
    undecided.delete(device);
  };
  const drainAll = (): void => {
    if (closing) return;
    void storage("outbox_snapshot").then(() => {
      for (const threadId of new Set(outbox.map((m) => m.threadId))) drain(threadId);
    }).catch(() => options.onError?.("channel-storage-failed"));
  };
  const drain = (threadId: string): void => {
    if (closing) return;
    if (draining.has(threadId)) { drainAgain.add(threadId); return; }
    draining.add(threadId);
    void serial(threadId, async () => {
      await storage("outbox_snapshot");
      for (const queued of outbox.filter((m) => m.threadId === threadId)) {
        if (closing || options.canDispatch?.(queued.id) === false) continue;
        const message = await storage("outbox_get", { messageId: queued.id }) as ChannelInbound | undefined;
        if (!message || closing || options.canDispatch?.(queued.id) === false) continue;
        if (modelDelivery[message.id] === "delivered") continue;
        if (message.channelModel !== undefined) {
          try {
            if (modelDelivery[message.id] !== "prepared") {
              await select(deviceForModels(), threadId, message.channelModel.model ?? null);
            }
            // Preparation intent and pin removal are replayable Rust transitions.
            await storage("outbox_prepared", { messageId: message.id });
          } catch (error) {
            options.onDeliveryError?.(message, reason(error));
            break;
          }
        }
        const { channelModel: _, replyAttempted: __, ...ready } = message;
        const reply = ready.replyContext !== undefined;
        if (reply && ![...announcedBy.values()].some((caps) => caps.has("reply-context-v1"))) {
          if (plugins.size === 0 || undecided.size > 0) break;
          if (message.replyAttempted) {
            options.onDeliveryError?.(ready, "reply-delivery-unconfirmed");
            break;
          }
          options.onRejected?.(ready, "reply-context-unsupported");
          await storage("outbox_reject", { messageId: message.id });
          continue;
        }
        const media = Boolean(ready.attachments?.length);
        if (media && mediaPlugins.size === 0) {
          // Keep order: nothing behind it goes out until we know whether it can.
          if (plugins.size === 0 || undecided.size > 0) break;
          if (reply && message.replyAttempted) {
            options.onDeliveryError?.(ready, "reply-delivery-unconfirmed");
            break;
          }
          await storage("outbox_reject", { messageId: message.id });
          options.onRejected?.(ready, "attachments-unsupported");
          continue;
        }
        const eligible = [...plugins].filter(([device]) =>
          (!media || mediaPlugins.has(device)) && (!reply || announcedBy.get(device)?.has("reply-context-v1")));
        if (!eligible.length) {
          if (!plugins.size || undecided.size) break;
          if (message.replyAttempted) {
            options.onDeliveryError?.(ready, "reply-delivery-unconfirmed");
            break;
          }
          options.onRejected?.(ready, "reply-context-unsupported");
          await storage("outbox_reject", { messageId: message.id });
          continue;
        }
        // Losing an ack cannot turn a possibly executed reply into a definite rejection.
        // Preserve this marker across host restart before the first socket write.
        if (reply && !message.replyAttempted) {
          await storage("outbox_attempted", { messageId: message.id });
        }
        if (closing || options.canDispatch?.(message.id) === false) continue;
        options.forwarded(ready);
        for (const [device, send] of eligible) {
          if (sent.get(device)?.has(message.id)) continue;
          sent.get(device)?.add(message.id);
          send({ type: "inbound", message: ready });
          if (runBoundaryPlugins.has(device)) options.handedOff(ready);
        }
      }
    }).catch((error) => options.onError?.(reason(error))).finally(() => {
      draining.delete(threadId);
      if (drainAgain.delete(threadId)) drain(threadId);
    });
  };

  const processFrame = (device: string, frame: PluginFrame): void => {
    const send = plugins.get(device);
    if (!send || !frame || typeof frame !== "object") return;
    if (frame.type === "hello") {
      if (!Array.isArray(frame.capabilities) || !frame.capabilities.every((c) => typeof c === "string")) return;
      announcedBy.set(device, new Set(frame.capabilities));
      if (frame.capabilities.includes("progress-v1")) progressPlugins.add(device);
      else progressPlugins.delete(device);
      if (frame.capabilities.includes("run-boundary-v1")) runBoundaryPlugins.add(device);
      else runBoundaryPlugins.delete(device);
      if (frame.capabilities.includes("model-select-v1")) capable.add(device);
      else capable.delete(device);
      if (frame.capabilities.includes("media-v1")) mediaPlugins.add(device);
      else mediaPlugins.delete(device);
      decided(device);
      options.onCapabilities?.();
      // Messages sent before this hello were already on their way to a run-boundary plugin.
      if (runBoundaryPlugins.has(device)) {
        for (const message of outbox) if (sent.get(device)?.has(message.id)) options.handedOff(message);
      }
      drainAll();
      return;
    }
    if (frame.type === "run_started" || frame.type === "run_finished") {
      if (!runBoundaryPlugins.has(device) || !validId(frame.messageId)) return;
      if (frame.type === "run_started") options.runStarted(frame.messageId);
      else if (["completed", "failed", "aborted"].includes(frame.status)) options.runFinished(frame.messageId, frame.status);
      return;
    }
    if (frame.type === "tool_started" || frame.type === "tool_finished") {
      // Best effort and unacknowledged: anything malformed or from the wrong plugin is dropped.
      if (!runBoundaryPlugins.has(device) || !progressPlugins.has(device) ||
          !validId(frame.messageId) || !validId(frame.callId)) return;
      if (frame.type === "tool_started") {
        if (typeof frame.name === "string" && frame.name && frame.name.length <= 256 &&
            frame.args && typeof frame.args === "object" && !Array.isArray(frame.args)) {
          options.toolStarted(frame.messageId, frame.callId, frame.name, frame.args);
        }
      } else if (typeof frame.ok === "boolean" && typeof frame.output === "string") {
        options.toolFinished(frame.messageId, frame.callId, frame.ok, frame.output);
      }
      return;
    }
    if ("requestId" in frame) {
      const entry = pending.get(frame.requestId);
      if (!entry || entry.device !== device || entry.type !== frame.type) return;
      clearTimeout(entry.timer);
      pending.delete(frame.requestId);
      entry.resolve(frame);
      return;
    }
    if (frame.type === "ack") {
      if (!validId(frame.id) || !sent.get(device)?.has(frame.id) || !outbox.some((message) => message.id === frame.id)) return;
      void storage("outbox_ack", { messageId: frame.id }).catch(() => options.onError?.("channel-storage-failed"));
      return;
    }
    if (frame.type === "reply_preview") {
      if (!runBoundaryPlugins.has(device) || !announcedBy.get(device)?.has("reply-stream-v1") ||
          !validId(frame.id) || !validId(frame.messageId) || !validId(frame.threadId) ||
          typeof frame.text !== "string" || Buffer.byteLength(JSON.stringify(frame.text)) > MAX_TEXT) return;
      options.preview?.({ id: frame.id, messageId: frame.messageId, threadId: frame.threadId, text: frame.text });
      return;
    }
    if (frame.type !== "deliver") return;
    const id = typeof frame.id === "string" ? frame.id.slice(0, MAX_ID) : "";
    if (!validId(frame.id) || !validId(frame.threadId) || typeof frame.text !== "string" ||
        frame.text.length > MAX_TEXT || (frame.title !== undefined && typeof frame.title !== "string") ||
        (frame.messageId !== undefined && (!validId(frame.messageId) || !runBoundaryPlugins.has(device) ||
          !announcedBy.get(device)?.has("reply-stream-v1") ||
          Buffer.byteLength(JSON.stringify(frame.text)) > MAX_TEXT)) ||
        (frame.failed !== undefined && typeof frame.failed !== "boolean") ||
        (frame.interrupted !== undefined && typeof frame.interrupted !== "boolean")) {
      return send({ type: "error", id, reason: "invalid-deliver" });
    }
    try {
      options.deliver({ id: frame.id, threadId: frame.threadId, text: frame.text,
        ...(frame.messageId !== undefined ? { messageId: frame.messageId, failed: frame.failed, interrupted: frame.interrupted } : {}),
        ...(frame.title !== undefined ? { title: frame.title.slice(0, 200) } : {}) },
        frame.messageId === undefined && runBoundaryPlugins.has(device) &&
          announcedBy.get(device)?.has("reply-stream-v1") === true);
    } catch (error) {
      // No ack: the plugin keeps it and retries.
      return send({ type: "error", id, reason: error instanceof Error ? error.message : String(error) });
    }
    send({ type: "ack", id: frame.id });
  };
  const frameChains = new Map<string, Promise<void>>();
  const socket = startLocalChannel<PluginFrame, HostFrame>({
    path: channelSocketPath(dir),
    onOpen: (device, send) => {
      plugins.set(device, send);
      send({ type: "hello", capabilities: ["reply-stream-v1"] });
      sent.set(device, new Set());
      // A plugin that says nothing within the grace is legacy: tell clients, and settle what waited on it.
      // A plugin with attachments waiting announces `media-v1` right away.
      undecided.set(device, setTimeout(() => {
        undecided.delete(device);
        options.onCapabilities?.();
        drainAll();
      }, HELLO_GRACE_MS).unref());
      drainAll();
    },
    onClose: (device) => {
      plugins.delete(device);
      sent.delete(device);
      capable.delete(device);
      mediaPlugins.delete(device);
      decided(device);
      runBoundaryPlugins.delete(device);
      progressPlugins.delete(device);
      announcedBy.delete(device);
      for (const [id, entry] of pending) {
        if (entry.device !== device) continue;
        clearTimeout(entry.timer);
        pending.delete(id);
        entry.reject(new Error("OpenClaw disconnected"));
      }
      if (!runBoundaryPlugins.size) options.runBoundaryLost();
      options.onCapabilities?.();
    },
    onError: options.onError,
    onEvent(device, frame) {
      // Per-connection wire order survives asynchronous state recovery.
      const next = (frameChains.get(device) ?? recovered).then(() => { if (!closing) processFrame(device, frame); });
      frameChains.set(device, next);
      void next.finally(() => { if (frameChains.get(device) === next) frameChains.delete(device); })
        .catch(() => options.onError?.("channel-storage-failed"));
    },
  });

  return {
    get connected() {
      return plugins.size > 0;
    },
    get modelSelection() { return capable.size > 0; },
    get announced() { return new Set([...announcedBy.values()].flatMap((caps) => [...caps])); },
    get attachments() {
      return mediaPlugins.size > 0 ? "supported" : plugins.size === 0 || undecided.size > 0 ? "unknown" : "unsupported";
    },
    refreshModels: (threadId) => serial(threadId, async () => {
      const device = deviceForModels();
      const models = await catalog(device, threadId);
      const frame = await request(device, { type: "model_selection_request", requestId: randomUUID(), threadId }, "model_selection");
      if (frame.type !== "model_selection" || frame.model !== null && !validModel(frame.model)) throw new Error("Invalid OpenClaw model selection");
      options.onModel?.(threadId, frame.model);
      return models;
    }),
    selectModel: (threadId, model) => serial(threadId, () => select(deviceForModels(), threadId, model)),
    retry: drain,
    async forward(message) {
      if (closing) throw new Error("channel-closed");
      await storage("outbox_enqueue", { message });
      drain(message.threadId);
    },
    async withdraw(messageId) { await storage("outbox_withdraw", { messageId }); },
    abort(messageId) {
      for (const device of runBoundaryPlugins) plugins.get(device)?.({ type: "abort", messageId });
    },
    close: async () => {
      closing = true;
      for (const entry of pending.values()) {
        clearTimeout(entry.timer);
        entry.reject(new Error("OpenClaw disconnected"));
      }
      pending.clear();
      for (const timer of undecided.values()) clearTimeout(timer);
      undecided.clear();
      await socket.close();
      await Promise.allSettled([...operations.values()]);
      await storageTail.catch(() => {});
      releaseStorage();
    },
  };
  } catch (error) { releaseStorage(); throw error; }
}
