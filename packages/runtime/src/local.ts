/**
 * The local channel: a Unix domain socket at `<state dir>/local.sock` carrying the same
 * `YorozuEvent` JSON the relay carries, one event per line, in the clear.
 *
 * The Mac app is on the same machine as the sidecar and runs as the same user, so there is
 * nothing to encrypt against and no relay hop worth paying for: the socket's own mode is the
 * access control. Every connection is treated as one more paired device by serve.ts, which is
 * what makes broadcasts — replies, approval cards, thread lists — reach it for free.
 * See docs/spec-v1.html section 8.
 */
import { chmodSync, mkdirSync, rmSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { dirname, join } from "node:path";
import type { YorozuEvent } from "@yorozu/shared";

/** Writes one event to a single connected client. */
export type Send = (event: YorozuEvent) => void;

export const localSocketPath = (dir: string): string => join(dir, "local.sock");

export interface LocalChannelOptions {
  path: string;
  /** A client connected. `device` is its id for the lifetime of the connection. */
  onOpen(device: string, send: Send): void;
  onEvent(device: string, event: YorozuEvent): void;
  onClose(device: string): void;
  onError?(message: string): void;
}

export interface LocalChannel {
  readonly path: string;
  close(): Promise<void>;
}

export function startLocalChannel(options: LocalChannelOptions): LocalChannel {
  // Keys and plaintext logs live in the state dir, so nobody but the owner may even list it.
  // It is usually there already (loadKeys and the transcripts make it); this is for when it is not.
  mkdirSync(dirname(options.path), { recursive: true, mode: 0o700 });
  // A socket file left behind by a killed sidecar would refuse the bind. There is only ever
  // one sidecar per state dir, so whatever is there is ours and stale.
  rmSync(options.path, { force: true });

  const clients = new Set<Socket>();
  let devices = 0;

  const server = createServer((socket) => {
    const device = `local-${++devices}`;
    clients.add(socket);
    socket.setEncoding("utf8");
    let buffer = "";

    const send: Send = (event) => {
      if (!socket.destroyed) socket.write(`${JSON.stringify(event)}\n`);
    };

    socket.on("data", (chunk: string) => {
      buffer += chunk;
      // Everything before the last newline is a whole line; what follows it is the start of
      // the next one, which the next chunk finishes.
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          options.onEvent(device, JSON.parse(line) as YorozuEvent);
        } catch (e) {
          // A bad line is one bad line: never a reason to drop the connection.
          options.onError?.(`local-frame-error ${e instanceof Error ? e.message : String(e)}`);
        }
      }
    });
    socket.on("error", (e) => options.onError?.(`local-error ${e.message}`));
    socket.on("close", () => {
      clients.delete(socket);
      options.onClose(device);
    });

    options.onOpen(device, send);
  });

  server.on("error", (e) => options.onError?.(`local-error ${e.message}`));
  // Plaintext events cross this socket, so only its owner may open it. The bind creates the
  // node with the process umask applied, so a chmod afterwards leaves a window in which another
  // local user could connect: the umask is narrowed around the bind so the node is 0600 from
  // the start. It is put back as soon as listen settles, either way, so a failed bind does not
  // leave the whole process at 0o077 — and again from close(), because a server closed before
  // `listening` fires never fires it at all. Only the first restore does anything.
  let previous: number | undefined = process.umask(0o077);
  const restore = () => {
    if (previous === undefined) return;
    process.umask(previous);
    previous = undefined;
  };
  server.once("error", restore);
  server.listen(options.path, () => {
    restore();
    // Belt and braces, for a platform whose bind ignores the umask.
    try {
      chmodSync(options.path, 0o600);
    } catch (e) {
      options.onError?.(`local-error ${e instanceof Error ? e.message : String(e)}`);
    }
  });

  return {
    path: options.path,
    close: () =>
      new Promise<void>((done) => {
        restore();
        for (const socket of clients) socket.destroy();
        server.close(() => {
          rmSync(options.path, { force: true });
          done();
        });
      }),
  };
}
