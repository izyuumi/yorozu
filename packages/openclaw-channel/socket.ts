// Client for Yorozu's channel.sock (packages/runtime/src/channel.ts in the Yorozu repo).
// Newline-delimited JSON. Both directions are acked by id; the host resends unacked
// inbound messages on every connect, so inbound ids are deduped here.
import { randomUUID } from "node:crypto";
import { createConnection, type Socket } from "node:net";

export type Inbound = { id: string; threadId: string; ts: number; text: string };
type HostFrame =
  | { type: "inbound"; message: Inbound }
  | { type: "ack"; id: string }
  | { type: "error"; id: string; reason: string };

export type YorozuLinkOptions = {
  path: string;
  /** Resolves once OpenClaw has taken the message; only then is it acked. */
  onInbound: (message: Inbound) => Promise<void>;
  onStatus?: (connected: boolean) => void;
  onError?: (message: string) => void;
  retryMs?: number;
  ackTimeoutMs?: number;
};

export type YorozuLink = {
  readonly connected: boolean;
  deliver: (threadId: string, text: string) => Promise<string>;
  close: () => void;
};

export function connectYorozu(options: YorozuLinkOptions): YorozuLink {
  const retryMs = options.retryMs ?? 2000;
  const ackTimeoutMs = options.ackTimeoutMs ?? 10_000;
  const waiting = new Map<string, { resolve: () => void; reject: (error: Error) => void }>();
  const seen = new Set<string>();
  let socket: Socket | undefined;
  let connected = false;
  let closed = false;
  let timer: NodeJS.Timeout | undefined;

  const write = (frame: unknown) => socket?.write(`${JSON.stringify(frame)}\n`);

  const handle = (frame: HostFrame) => {
    if (frame.type === "inbound") {
      const { message } = frame;
      if (seen.has(message.id)) return void write({ type: "ack", id: message.id });
      seen.add(message.id);
      options.onInbound(message).then(
        () => write({ type: "ack", id: message.id }),
        (error) => {
          // Not acked: the host resends it on the next connect.
          seen.delete(message.id);
          options.onError?.(`inbound ${message.id} failed: ${String(error)}`);
        },
      );
      return;
    }
    const pending = waiting.get(frame.id);
    if (!pending) return;
    waiting.delete(frame.id);
    if (frame.type === "ack") pending.resolve();
    else pending.reject(new Error(`yorozu refused: ${frame.reason}`));
  };

  const open = () => {
    if (closed) return;
    const next = createConnection(options.path);
    socket = next;
    let buffer = "";
    next.setEncoding("utf8");
    next.on("connect", () => {
      connected = true;
      options.onStatus?.(true);
    });
    next.on("data", (chunk: string) => {
      buffer += chunk;
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          handle(JSON.parse(line) as HostFrame);
        } catch (error) {
          options.onError?.(`bad frame: ${String(error)}`);
        }
      }
    });
    next.on("error", (error) => options.onError?.(error.message));
    next.on("close", () => {
      if (connected) options.onStatus?.(false);
      connected = false;
      for (const [id, pending] of waiting) {
        waiting.delete(id);
        pending.reject(new Error("yorozu disconnected"));
      }
      if (!closed) timer = setTimeout(open, retryMs);
    });
  };
  open();

  return {
    get connected() {
      return connected;
    },
    deliver(threadId, text) {
      if (!connected) return Promise.reject(new Error("yorozu is not running"));
      const id = randomUUID();
      return new Promise<string>((resolve, reject) => {
        const timeout = setTimeout(() => {
          waiting.delete(id);
          reject(new Error("yorozu did not ack"));
        }, ackTimeoutMs);
        waiting.set(id, {
          resolve: () => (clearTimeout(timeout), resolve(id)),
          reject: (error) => (clearTimeout(timeout), reject(error)),
        });
        write({ type: "deliver", id, threadId, text });
      });
    },
    close() {
      closed = true;
      clearTimeout(timer);
      socket?.destroy();
    },
  };
}
