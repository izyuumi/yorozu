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
import { readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import type { ChannelModelChoice, ChannelModelOption, MessageAttachment } from "@yorozu/shared";
import { startLocalChannel, type Send } from "./local.js";

export const channelSocketPath = (dir: string): string => join(dir, "channel.sock");
const outboxFile = (dir: string): string => join(dir, "channel-outbox.json");

export interface ChannelInbound {
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
  /** Title for a thread this message creates. Ignored when the thread exists. */
  title?: string;
}

export type HostFrame =
  | { type: "model_catalog_request" | "model_selection_request"; requestId: string; threadId: string }
  | { type: "model_select"; requestId: string; threadId: string; model: string | null }
  | { type: "inbound"; message: ChannelInbound }
  | { type: "abort"; messageId: string }
  | { type: "ack"; id: string }
  | { type: "error"; id: string; reason: string };

export type RunStatus = "completed" | "failed" | "aborted";
export type PluginFrame = ({ type: "deliver" } & ChannelDeliver)
  | { type: "ack"; id: string }
  | { type: "hello"; capabilities?: string[] }
  | { type: "run_started"; messageId: string }
  | { type: "run_finished"; messageId: string; status: RunStatus }
  | { type: "model_catalog"; requestId: string; models: ChannelModelOption[] }
  | { type: "model_selection"; requestId: string; model: string | null }
  | { type: "model_select_result"; requestId: string; ok: boolean; model?: string | null; error?: string };

export interface ChannelHostOptions {
  dir: string;
  /** Makes the message durable in its thread. Throws when it could not. */
  deliver(message: ChannelDeliver): void;
  forwarded(message: ChannelInbound): void;
  runStarted(messageId: string): void;
  runFinished(messageId: string, status: RunStatus): void;
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
  /** Whether attachments can go out: `unknown` while no plugin is connected or one has not said hello yet. */
  readonly attachments: "supported" | "unsupported" | "unknown";
  refreshModels(threadId: string): Promise<ChannelModelOption[]>;
  selectModel(threadId: string, model: string | null): Promise<void>;
  retry(threadId: string): void;
  /** Queues a user message for OpenClaw. Durable before it returns. */
  forward(message: ChannelInbound): void;
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

function loadOutbox(dir: string): ChannelInbound[] {
  try {
    return JSON.parse(readFileSync(outboxFile(dir), "utf8")) as ChannelInbound[];
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw new Error(`Cannot read ${outboxFile(dir)}; repair or remove it`, { cause: error });
  }
}

function saveJson(file: string, value: unknown): void {
  writeFileSync(`${file}.tmp`, JSON.stringify(value), { mode: 0o600, flush: true });
  try {
    renameSync(`${file}.tmp`, file);
  } catch (error) {
    rmSync(`${file}.tmp`, { force: true });
    throw error;
  }
}

export function startChannelHost(options: ChannelHostOptions): ChannelHost {
  const { dir } = options;
  let outbox = loadOutbox(dir);
  // Keep model preparation after ack: replaying an old draft must not restore its old pin.
  const deliveryFile = join(dir, "channel-model-delivery.json");
  let modelDelivery: Record<string, "prepared" | "delivered"> = {};
  try { modelDelivery = JSON.parse(readFileSync(deliveryFile, "utf8")); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
  if (outbox.some((message) => modelDelivery[message.id] === "delivered")) {
    outbox = outbox.filter((message) => modelDelivery[message.id] !== "delivered");
    saveJson(outboxFile(dir), outbox);
  }
  const markDelivery = (id: string, status: "prepared" | "delivered"): void => {
    const updated = { ...modelDelivery, [id]: status };
    saveJson(deliveryFile, updated);
    modelDelivery = updated;
  };
  const plugins = new Map<string, Send<HostFrame>>();
  const runBoundaryPlugins = new Set<string>();
  const capable = new Set<string>();
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
  const drainAll = (): void => { for (const threadId of new Set(outbox.map((m) => m.threadId))) drain(threadId); };
  const drain = (threadId: string): void => {
    if (draining.has(threadId)) { drainAgain.add(threadId); return; }
    draining.add(threadId);
    void serial(threadId, async () => {
      for (const message of outbox.filter((m) => m.threadId === threadId)) {
        if (modelDelivery[message.id] === "delivered") continue;
        if (message.channelModel !== undefined) {
          try {
            if (modelDelivery[message.id] !== "prepared") {
              await select(deviceForModels(), threadId, message.channelModel.model ?? null);
              markDelivery(message.id, "prepared");
            }
            // Persist confirmation before dispatch. Reconnect must not restore an old override.
            const updated = outbox.map((m) => {
              if (m.id !== message.id) return m;
              const { channelModel: _, ...ready } = m;
              return ready;
            });
            saveJson(outboxFile(dir), updated);
            outbox = updated;
          } catch (error) {
            options.onDeliveryError?.(message, reason(error));
            break;
          }
        }
        const { channelModel: _, ...ready } = message;
        const media = Boolean(ready.attachments?.length);
        if (media && mediaPlugins.size === 0) {
          // Keep order: nothing behind it goes out until we know whether it can.
          if (plugins.size === 0 || undecided.size > 0) break;
          outbox = outbox.filter((m) => m.id !== message.id);
          saveJson(outboxFile(dir), outbox);
          options.onRejected?.(ready, "attachments-unsupported");
          continue;
        }
        if (plugins.size) options.forwarded(ready);
        for (const [device, send] of plugins) {
          if (media && !mediaPlugins.has(device)) continue;
          if (sent.get(device)?.has(message.id)) continue;
          sent.get(device)?.add(message.id);
          send({ type: "inbound", message: ready });
        }
      }
    }).catch((error) => options.onError?.(reason(error))).finally(() => {
      draining.delete(threadId);
      if (drainAgain.delete(threadId)) drain(threadId);
    });
  };

  const socket = startLocalChannel<PluginFrame, HostFrame>({
    path: channelSocketPath(dir),
    onOpen: (device, send) => {
      plugins.set(device, send);
      sent.set(device, new Set());
      // A plugin with attachments waiting announces `media-v1` right away; one that never says hello is old.
      undecided.set(device, setTimeout(() => { undecided.delete(device); drainAll(); }, HELLO_GRACE_MS).unref());
      drainAll();
    },
    onClose: (device) => {
      plugins.delete(device);
      sent.delete(device);
      capable.delete(device);
      mediaPlugins.delete(device);
      decided(device);
      runBoundaryPlugins.delete(device);
      for (const [id, entry] of pending) {
        if (entry.device !== device) continue;
        clearTimeout(entry.timer);
        pending.delete(id);
        entry.reject(new Error("OpenClaw disconnected"));
      }
      options.onCapabilities?.();
    },
    onError: options.onError,
    onEvent: (device, frame) => {
      const send = plugins.get(device);
      if (!send || !frame || typeof frame !== "object") return;
      if (frame.type === "hello") {
        if (!Array.isArray(frame.capabilities) || !frame.capabilities.every((c) => typeof c === "string")) return;
        if (frame.capabilities.includes("run-boundary-v1")) runBoundaryPlugins.add(device);
        else runBoundaryPlugins.delete(device);
        if (frame.capabilities.includes("model-select-v1")) capable.add(device);
        else capable.delete(device);
        if (frame.capabilities.includes("media-v1")) mediaPlugins.add(device);
        else mediaPlugins.delete(device);
        decided(device);
        options.onCapabilities?.();
        drainAll();
        return;
      }
      if (frame.type === "run_started" || frame.type === "run_finished") {
        if (!runBoundaryPlugins.has(device) || !validId(frame.messageId)) return;
        if (frame.type === "run_started") options.runStarted(frame.messageId);
        else if (["completed", "failed", "aborted"].includes(frame.status)) options.runFinished(frame.messageId, frame.status);
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
        if (modelDelivery[frame.id] === "prepared") markDelivery(frame.id, "delivered");
        outbox = outbox.filter((message) => message.id !== frame.id);
        saveJson(outboxFile(dir), outbox);
        return;
      }
      if (frame.type !== "deliver") return;
      const id = typeof frame.id === "string" ? frame.id.slice(0, MAX_ID) : "";
      if (!validId(frame.id) || !validId(frame.threadId) || typeof frame.text !== "string" ||
          frame.text.length > MAX_TEXT || (frame.title !== undefined && typeof frame.title !== "string")) {
        return send({ type: "error", id, reason: "invalid-deliver" });
      }
      try {
        options.deliver({ id: frame.id, threadId: frame.threadId, text: frame.text,
          ...(frame.title !== undefined ? { title: frame.title.slice(0, 200) } : {}) });
      } catch (error) {
        // No ack: the plugin keeps it and retries.
        return send({ type: "error", id, reason: error instanceof Error ? error.message : String(error) });
      }
      send({ type: "ack", id: frame.id });
    },
  });

  return {
    get connected() {
      return plugins.size > 0;
    },
    get modelSelection() { return capable.size > 0; },
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
    forward(message) {
      if (modelDelivery[message.id] === "delivered") return;
      if (outbox.some((queued) => queued.id === message.id)) { drain(message.threadId); return; }
      if ([...sent.values()].some((ids) => ids.has(message.id))) return;
      outbox = [...outbox, message];
      saveJson(outboxFile(dir), outbox);
      drain(message.threadId);
    },
    abort(messageId) {
      for (const device of runBoundaryPlugins) plugins.get(device)?.({ type: "abort", messageId });
    },
    close: async () => {
      for (const entry of pending.values()) {
        clearTimeout(entry.timer);
        entry.reject(new Error("OpenClaw disconnected"));
      }
      pending.clear();
      for (const timer of undecided.values()) clearTimeout(timer);
      undecided.clear();
      await socket.close();
    },
  };
}
