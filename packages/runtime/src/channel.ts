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
import type { MessageAttachment } from "@yorozu/shared";
import { startLocalChannel, type Send } from "./local.js";

export const channelSocketPath = (dir: string): string => join(dir, "channel.sock");
const outboxFile = (dir: string): string => join(dir, "channel-outbox.json");

export interface ChannelInbound {
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
  | { type: "inbound"; message: ChannelInbound }
  | { type: "ack"; id: string }
  | { type: "error"; id: string; reason: string };

export type PluginFrame = ({ type: "deliver" } & ChannelDeliver) | { type: "ack"; id: string };

export interface ChannelHostOptions {
  dir: string;
  /** Makes the message durable in its thread. Throws when it could not. */
  deliver(message: ChannelDeliver): void;
  onError?(message: string): void;
}

export interface ChannelHost {
  /** Whether a plugin is connected right now. Messages are queued either way. */
  readonly connected: boolean;
  /** Queues a user message for OpenClaw. Durable before it returns. */
  forward(message: ChannelInbound): void;
  close(): Promise<void>;
}

const MAX_ID = 128;
const MAX_TEXT = 256 * 1024;
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

function saveOutbox(dir: string, outbox: ChannelInbound[]): void {
  const file = outboxFile(dir);
  writeFileSync(`${file}.tmp`, JSON.stringify(outbox), { mode: 0o600, flush: true });
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
  const plugins = new Map<string, Send<HostFrame>>();

  const socket = startLocalChannel<PluginFrame, HostFrame>({
    path: channelSocketPath(dir),
    onOpen: (device, send) => {
      plugins.set(device, send);
      for (const message of outbox) send({ type: "inbound", message });
    },
    onClose: (device) => plugins.delete(device),
    onError: options.onError,
    onEvent: (device, frame) => {
      const send = plugins.get(device);
      if (!send || !frame || typeof frame !== "object") return;
      if (frame.type === "ack") {
        if (!validId(frame.id) || !outbox.some((message) => message.id === frame.id)) return;
        outbox = outbox.filter((message) => message.id !== frame.id);
        saveOutbox(dir, outbox);
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
    forward(message) {
      if (outbox.some((queued) => queued.id === message.id)) return;
      outbox = [...outbox, message];
      saveOutbox(dir, outbox);
      for (const send of plugins.values()) send({ type: "inbound", message });
    },
    close: () => socket.close(),
  };
}
