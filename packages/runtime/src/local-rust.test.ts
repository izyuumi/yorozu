import { existsSync, mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createConnection, type Socket } from "node:net";
import { afterEach, expect, test, vi } from "vitest";
import { startLocalChannel, type LocalChannel, type Send } from "./local.js";
import { AttachmentUploads } from "./attachment-upload.js";
import { hostWorkerPid, closeHostWorker } from "./rust-host.js";

const channels: LocalChannel[] = [];
const roots: string[] = [];
const sockets: Socket[] = [];
afterEach(async () => {
  for (const socket of sockets.splice(0)) socket.destroy();
  for (const channel of channels.splice(0)) await channel.close();
  for (const root of roots.splice(0)) { await closeHostWorker(root); rmSync(root, { recursive: true, force: true }); }
});
function root(): string { const dir = mkdtempSync(join(tmpdir(), "yorozu-port-client-")); roots.push(dir); return dir; }
async function connect(path: string) {
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      const socket = await new Promise<Socket>((resolve, reject) => {
        const socket = createConnection(path); socket.once("connect", () => resolve(socket));
        socket.once("error", (error) => { socket.destroy(); reject(error); });
      });
      sockets.push(socket); return socket;
    } catch { await new Promise((resolve) => setTimeout(resolve, 20)); }
  }
  throw new Error("test listener did not recover");
}
function frames(socket: Socket): unknown[] {
  const frames: unknown[] = []; let buffer = "";
  socket.setEncoding("utf8"); socket.on("data", (part: string) => {
    buffer += part; let newline: number;
    while ((newline = buffer.indexOf("\n")) >= 0) { frames.push(JSON.parse(buffer.slice(0,newline))); buffer = buffer.slice(newline+1); }
  });
  return frames;
}

test("the Rust transport snapshots outgoing frames and preserves fragmented incoming Unicode", async () => {
  const dir = root(); const received: unknown[] = []; let send!: Send<{ text: string }>;
  const channel = startLocalChannel<unknown, { text: string }>({ path: join(dir,"local.sock"),
    onOpen: (_, writer) => { send = writer; }, onEvent: (_, frame) => received.push(frame), onClose() {} });
  channels.push(channel); await channel.ready;
  const socket = await connect(channel.path); const output = frames(socket);
  await vi.waitFor(() => expect(send).toBeTypeOf("function"));
  const message = { text: "original" }; send(message); message.text = "mutated after send";
  await vi.waitFor(() => expect(output).toEqual([{ text: "original" }]));
  socket.write('{"text":"日本'); socket.write('語🙂","future":true}\n');
  await vi.waitFor(() => expect(received).toEqual([{ text: "日本語🙂", future: true }]));
});

test("actual worker termination rebinds sockets without routing retired callbacks to a new connection", async () => {
  const dir = root(); const writers = new Map<string, Send<{ text: string }>>(); const closed: string[] = [];
  const channel = startLocalChannel<unknown, { text: string }>({ path: join(dir,"local.sock"),
    onOpen: (id,send) => writers.set(id,send), onEvent() {}, onClose: (id) => closed.push(id) });
  channels.push(channel); await channel.ready;
  const old = await connect(channel.path);
  await vi.waitFor(() => expect(writers.size).toBe(1)); const [oldId, retired] = [...writers][0]!;
  const pid = hostWorkerPid(dir); expect(pid).toBeTypeOf("number"); process.kill(pid!, "SIGKILL");
  await vi.waitFor(() => expect(closed).toEqual([oldId]));
  await vi.waitFor(() => expect(hostWorkerPid(dir)).not.toBe(pid)); old.destroy();
  const current = await connect(channel.path); const output = frames(current);
  await vi.waitFor(() => expect(writers.size).toBe(2));
  const [newId, send] = [...writers].at(-1)!; expect(newId).not.toBe(oldId);
  retired({ text: "retired" }); send({ text: "current" });
  await vi.waitFor(() => expect(output).toEqual([{ text: "current" }]));
  expect(closed.filter((id) => id === oldId)).toHaveLength(1);
});

test("closing one storage owner keeps transport alive; the last owner reclaims it without touching drafts", async () => {
  const dir = root(); const file = join(dir,"draft.json"); writeFileSync(file,'{"text":"keep","attachment":"retained"}');
  const uploads = new AttachmentUploads(dir);
  const channel = startLocalChannel<{ text: string }, { text: string }>({ path: join(dir,"local.sock"),
    onOpen: (_,send) => send({ text: "ready" }), onEvent() {}, onClose() {} });
  channels.push(channel); await channel.ready; const pid = hostWorkerPid(dir);
  await uploads.close(); expect(hostWorkerPid(dir)).toBe(pid);
  const socket = await connect(channel.path); const output = frames(socket);
  await vi.waitFor(() => expect(output).toEqual([{ text: "ready" }]));
  socket.destroy(); await channel.close();
  expect(hostWorkerPid(dir)).toBeUndefined(); expect(existsSync(channel.path)).toBe(false);
  expect(readFileSync(file,"utf8")).toBe('{"text":"keep","attachment":"retained"}');
});
