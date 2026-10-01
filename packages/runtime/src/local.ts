/** Native plaintext JSON-lines sockets, owned by the portable Rust worker. */
import { basename, dirname, join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import type { YorozuEvent } from "@yorozu/shared";
import { hostRequest, retainHostWorker, subscribeHostEvents } from "./rust-host.js";

export type Send<Out = YorozuEvent> = (event: Out) => void;
export const localSocketPath = (dir: string): string => join(dir, "local.sock");
export interface LocalChannelOptions<In = YorozuEvent, Out = YorozuEvent> {
  path: string;
  onOpen(device: string, send: Send<Out>): void;
  onEvent(device: string, event: In): void;
  onClose(device: string): void;
  onError?(message: string): void;
}
export interface LocalChannel {
  readonly path: string;
  /** Actual bound-listener confirmation, rather than process-spawn success. */
  readonly ready: Promise<void>;
  close(): Promise<void>;
}

export function startLocalChannel<In = YorozuEvent, Out = YorozuEvent>(options: LocalChannelOptions<In, Out>): LocalChannel {
  const dir = dirname(resolve(options.path)); const name = basename(options.path);
  const release = retainHostWorker(dir);
  let closing = false; let port = ""; let devices = 0; let queuedBytes = 0;
  let retry: ReturnType<typeof setTimeout> | undefined;
  let retryMs = 100;
  let opening: Promise<void> = Promise.resolve();
  const peers = new Map<string, { logical: string; port: string }>();
  const active = new Map<string, { peer: string; port: string }>();
  const writes = new Map<string, Promise<void>>();
  const closed = (logical: string): void => {
    if (!active.delete(logical)) return;
    writes.delete(logical); options.onClose(logical);
  };
  const recover = (): void => {
    if (closing || retry) return;
    retry = setTimeout(() => { retry = undefined; opening = open(); void opening.catch(() => {}); }, retryMs);
    retry.unref(); retryMs = Math.min(30_000, retryMs * 2);
  };
  const failed = (): void => {
    peers.clear(); for (const logical of [...active.keys()]) closed(logical);
    options.onError?.("local-host-unavailable"); recover();
  };
  const send = (logical: string, frame: Out): void => {
    const target = active.get(logical);
    if (closing || !target) return;
    let bytes: number; let snapshot: Out;
    try {
      const encoded = JSON.stringify(frame);
      bytes = Buffer.byteLength(encoded); snapshot = JSON.parse(encoded) as Out;
    } catch { options.onError?.("invalid-local-frame"); return; }
    if (bytes > 32 * 1024 * 1024 - 512 || queuedBytes + bytes > 64 * 1024 * 1024) {
      options.onError?.("local-output-limit");
      void hostRequest(dir, { op: "transport_disconnect", transportId: target.port, device: target.peer }).catch(() => {});
      closed(logical); return;
    }
    queuedBytes += bytes;
    const next = (writes.get(logical) ?? opening).catch(() => {}).then(async () => {
      if (closing || active.get(logical) !== target) return;
      const result = await hostRequest(dir, { op: "transport_send", transportId: target.port, device: target.peer, frame: snapshot }) as { sent?: unknown; error?: unknown };
      if (result?.sent !== true) { closed(logical); options.onError?.("local-write-unconfirmed"); }
    }).catch(() => { closed(logical); options.onError?.("local-write-unconfirmed"); })
      .finally(() => { queuedBytes -= bytes; if (writes.get(logical) === next) writes.delete(logical); });
    writes.set(logical, next);
  };
  const unsubscribe = subscribeHostEvents(dir, (event) => {
    if (closing) return;
    if (event.event === "lost") return failed();
    if (event.transportId !== port) return;
    if (event.event === "open") {
      const logical = `local-${++devices}`;
      peers.set(event.device, { logical, port }); active.set(logical, { peer: event.device, port });
      options.onOpen(logical, (frame) => send(logical, frame));
    } else {
      const peer = peers.get(event.device);
      if (!peer || peer.port !== port) return;
      if (event.event === "close") { peers.delete(event.device); closed(peer.logical); }
      else if (event.event === "error") options.onError?.("local-frame-error");
      else if (event.event === "frame") {
        try { options.onEvent(peer.logical, event.frame as In); }
        catch { options.onError?.("local-frame-error"); }
      }
    }
  });
  async function open(): Promise<void> {
    if (closing) return;
    port = randomUUID();
    try {
      const result = await hostRequest(dir, { op: "transport_open", transportId: port, name }) as { ready?: unknown };
      if (result?.ready !== true) throw new Error("local-listener-unavailable");
      retryMs = 100;
    } catch (error) { if (!closing) { options.onError?.("local-listener-unavailable"); recover(); } throw error; }
  }
  opening = open(); const ready = opening; void ready.catch(() => {});
  return {
    path: options.path, ready,
    async close() {
      if (closing) return;
      closing = true; if (retry) clearTimeout(retry);
      await opening.catch(() => {});
      await Promise.allSettled([...writes.values()]);
      await hostRequest(dir, { op: "transport_close", transportId: port }).catch(() => {});
      unsubscribe(); peers.clear(); for (const logical of [...active.keys()]) closed(logical);
      await release();
    },
  };
}
