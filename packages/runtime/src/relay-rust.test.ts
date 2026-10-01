import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { WebSocketServer } from "ws";
import { expect, test, vi } from "vitest";
import { startRustRelay, type RustRelaySocket } from "./relay-rust.js";
import { closeHostWorker, hostWorkerPid } from "./rust-host.js";

test("actual relay worker termination retires callbacks before recovering a new socket", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-relay-recovery-"));
  const server = new WebSocketServer({ port: 0 });
  const received: { connection: number; text: string }[] = [];
  let connections = 0;
  server.on("connection", (socket) => {
    const connection = ++connections;
    socket.send('{"type":"registered"}');
    socket.on("message", (data) => { received.push({ connection, text: data.toString() }); });
  });
  const sockets: RustRelaySocket[] = [];
  const closed: RustRelaySocket[] = [];
  const relay = startRustRelay({ dir, url: `ws://127.0.0.1:${(server.address() as AddressInfo).port}`,
    heartbeat: { pingMs: 30_000, pongMs: 10_000 }, onState() {}, onSocket(socket) {
      sockets.push(socket); socket.on("error", () => {}); socket.on("close", () => closed.push(socket));
    } });
  try {
    await vi.waitFor(() => expect(sockets).toHaveLength(1));
    const retired = sockets[0]!;
    retired.send("original");
    await vi.waitFor(() => expect(received).toEqual([{ connection: 1, text: "original" }]));
    const pid = hostWorkerPid(dir);
    expect(pid).toBeTypeOf("number"); process.kill(pid!, "SIGKILL");
    await vi.waitFor(() => expect(closed).toEqual([retired]));
    await vi.waitFor(() => expect(sockets).toHaveLength(2));
    expect(hostWorkerPid(dir)).not.toBe(pid);
    expect(() => retired.send("must-not-replay")).toThrow("closed");
    sockets[1]!.send("current");
    await vi.waitFor(() => expect(received).toEqual([
      { connection: 1, text: "original" }, { connection: 2, text: "current" },
    ]));
    expect(closed.filter((socket) => socket === retired)).toHaveLength(1);
    await relay.close();
    expect(hostWorkerPid(dir)).toBeUndefined();
  } finally {
    await relay.close(); await closeHostWorker(dir);
    for (const socket of server.clients) socket.terminate();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    rmSync(dir, { recursive: true, force: true });
  }
});


test("a buffered relay burst drains amplified handler responses in arrival order", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-relay-burst-"));
  const server = new WebSocketServer({ port: 0 });
  const replies: { seq: number; response: number }[] = [];
  const acknowledgements: number[] = [];
  let connections = 0;
  server.on("connection", (socket) => {
    connections++;
    socket.on("message", (data) => {
      const frame = JSON.parse(data.toString());
      if (frame.type === "ack") acknowledgements.push(frame.seq);
      else if (frame.type === "response") replies.push({ seq: frame.seq, response: frame.response });
    });
    socket.send('{"type":"registered"}');
    for (let seq = 0; seq < 40; seq++) socket.send(JSON.stringify({ type: "frame", seq, payload: "opaque" }));
  });
  const errors: Error[] = [];
  const relay = startRustRelay({ dir, url: `ws://127.0.0.1:${(server.address() as AddressInfo).port}`,
    heartbeat: { pingMs: 30_000, pongMs: 10_000 }, onState() {}, onSocket(socket) {
      socket.on("error", (error) => errors.push(error));
      socket.on("message", (data: string, token: string | undefined) => {
        const frame = JSON.parse(data);
        if (frame.type !== "frame") return;
        expect(token).toBeTypeOf("string");
        // A released thread-list request emits a receipt and two synchronous replies.
        for (let response = 0; response < 3; response++) socket.send(JSON.stringify({ type: "response", seq: frame.seq, response }));
        socket.handled(token, true);
      });
    } });
  try {
    await vi.waitFor(() => expect(acknowledgements).toEqual(Array.from({ length: 40 }, (_, n) => n)), { timeout: 5_000 });
    expect(replies).toEqual(Array.from({ length: 40 }, (_, seq) => Array.from({ length: 3 }, (_, response) => ({ seq, response }))).flat());
    expect(connections).toBe(1); expect(errors).toEqual([]);
  } finally {
    await relay.close(); await closeHostWorker(dir);
    for (const socket of server.clients) socket.terminate();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    rmSync(dir, { recursive: true, force: true });
  }
});
