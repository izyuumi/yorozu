// Client for Yorozu's channel.sock (packages/runtime/src/channel.ts in the Yorozu repo).
// Newline-delimited JSON. Both directions are acked by id; the host resends unacked
// inbound messages on every connect, so inbound ids are deduped here.
//
// Host frames:   { type: "inbound", message: { id, threadId, ts, text, attachments? } }
//                  (attachments: [{ name, mime, data: base64 }]; sent only to plugins announcing media-v1)
//                { type: "ack", id } | { type: "error", id, reason }
//                { type: "abort", messageId }
//                { type: "model_catalog_request" | "model_selection_request" | "model_select", requestId, threadId, ... }
// Plugin frames: { type: "hello", capabilities } (first on every connection)
//                { type: "deliver", id, threadId, text } | { type: "ack", id }
//                { type: "run_started", messageId } | { type: "run_finished", messageId, status }
//                { type: "model_catalog" | "model_selection" | "model_select_result", requestId, ... }
import { randomUUID } from "node:crypto";
import { createConnection } from "node:net";

/**
 * @param {{
 *   path: string,
 *   onInbound: (message: { id: string, threadId: string, ts: number, text: string, attachments?: { name: string, mime: string, data: string }[] }) => Promise<void>,
 *   onStatus?: (connected: boolean) => void,
 *   onError?: (message: string) => void,
 *   capabilities?: string[],
 *   onOpen?: () => void,
 *   onAbort?: (messageId: string) => void,
 *   onModelRequest?: (frame: object) => Promise<object>,
 *   retryMs?: number,
 *   ackTimeoutMs?: number,
 * }} options `onInbound` resolves once OpenClaw has taken the message; only then is it acked.
 * `capabilities` go out in the hello; `onOpen` runs right after it (replay run boundaries there).
 * `onModelRequest` resolves with the reply frame, which goes back on the connection that asked.
 */
export function connectYorozu(options) {
  const retryMs = options.retryMs ?? 2000;
  const ackTimeoutMs = options.ackTimeoutMs ?? 10_000;
  const waiting = new Map();
  const seen = new Set();
  const inflight = new Set();
  let socket;
  let connected = false;
  let streaming = false;
  let closed = false;
  let timer;

  // False when there is no live connection, so callers can keep the frame for the next one.
  const write = (frame) => {
    if (!connected) return false;
    socket.write(`${JSON.stringify(frame)}\n`);
    return true;
  };

  const handle = (frame) => {
    if (frame.type === "hello") {
      streaming = Array.isArray(frame.capabilities) && frame.capabilities.includes("reply-stream-v1");
      return;
    }
    if (frame.type === "inbound") {
      const { message } = frame;
      if (seen.has(message.id)) return void write({ type: "ack", id: message.id });
      // A reconnect can resend a run still waiting for its final delivery receipt.
      // Acking that duplicate would erase the host's durable run association.
      if (inflight.has(message.id)) return;
      inflight.add(message.id);
      options.onInbound(message).then(
        () => {
          inflight.delete(message.id);
          seen.add(message.id);
          write({ type: "ack", id: message.id });
        },
        (error) => {
          // Not acked: the host resends it on the next connect.
          inflight.delete(message.id);
          options.onError?.(`inbound ${message.id} failed: ${String(error)}`);
        },
      );
      return;
    }
    if (frame.type === "abort") return void options.onAbort?.(frame.messageId);
    if (frame.type === "model_catalog_request" || frame.type === "model_selection_request" || frame.type === "model_select") {
      const asked = socket;
      options.onModelRequest?.(frame).then((reply) => {
        if (socket === asked) write(reply);
      }, (error) => options.onError?.(`model request ${frame.requestId} failed: ${String(error)}`));
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
      write({ type: "hello", capabilities: options.capabilities ?? [] });
      options.onOpen?.();
      for (const pending of waiting.values()) if (pending.replay) write(pending.frame);
      options.onStatus?.(true);
    });
    next.on("data", (chunk) => {
      buffer += chunk;
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          handle(JSON.parse(line));
        } catch (error) {
          options.onError?.(`bad frame: ${String(error)}`);
        }
      }
    });
    next.on("error", (error) => options.onError?.(error.message));
    next.on("close", () => {
      if (connected) options.onStatus?.(false);
      connected = false;
      streaming = false;
      for (const [id, pending] of waiting) {
        if (pending.replay) continue;
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
    get streaming() { return streaming; },
    /** Resolves with the message id once Yorozu has logged it. */
    deliver(threadId, text, reply) {
      if (!connected && !(reply?.messageId || reply?.retryReceipt)) return Promise.reject(new Error("yorozu is not running"));
      if (closed) return Promise.reject(new Error("yorozu is closed"));
      const { id = randomUUID(), retryReceipt = false, ...fields } = reply ?? {};
      const frame = { type: "deliver", id, threadId, text, ...fields };
      const replay = Boolean(reply?.messageId || retryReceipt);
      return new Promise((resolve, reject) => {
        let timeout;
        const retry = () => {
          if (replay) {
            write(frame); // Same identity: a lost ack cannot duplicate the transcript.
            timeout = setTimeout(retry, ackTimeoutMs);
          } else {
            waiting.delete(id);
            reject(new Error("yorozu did not ack"));
          }
        };
        timeout = setTimeout(retry, ackTimeoutMs);
        waiting.set(id, {
          frame, replay,
          resolve: () => (clearTimeout(timeout), resolve(id)),
          reject: (error) => (clearTimeout(timeout), reject(error)),
        });
        write(frame);
      });
    },
    /** Sends a frame if connected; false means the caller must resend on the next `onOpen`. */
    send: write,
    close() {
      closed = true;
      clearTimeout(timer);
      for (const pending of waiting.values()) pending.reject(new Error("yorozu is closed"));
      waiting.clear();
      socket?.destroy();
    },
  };
}
