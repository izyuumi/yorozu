// The real relay and the real sidecar, with a proxy between the relay and the phone that can
// fail the way a phone's network does. Test-only; needs `pnpm -r build`. Used by the Swift wire
// tests (packages/shared-swift/Tests/YorozuSharedTests/WireTests.swift) and the iOS UI tests
// (apps/ios/e2e/ui-tests.sh).
//
//   node wire-harness.mjs [control-port]
//
// Prints {"control": port} once ready, then serves on 127.0.0.1:port until stdin closes or it
// is signalled:
//   GET  /pairing         {"qr"}: the pairing string, pointed at the proxy
//   POST /blackhole       every phone connection, open or new, stays open and carries nothing
//   POST /drop-host       frames from the Mac stop reaching the phone; the phone's still arrive
//   POST /down            close every phone connection now, and refuse new ones
//   POST /heal            back to normal for new connections and frames; blackholed ones stay dead
//   GET  /dials           {"dials"}: when each phone connection arrived, ms since start
//   GET  /events?thread=  {"events"}: the thread's durable events, as the Mac recorded them
//   GET  /messages        {"messages"}: every user message and finished answer the Mac recorded
import { mkdirSync, mkdtempSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay } from "@yorozu/relay";
import { WebSocket, WebSocketServer } from "ws";

// stdout carries only the ready line; the relay's own log lines go with the sidecar's.
console.log = console.error;

const stateDir = mkdtempSync(join(tmpdir(), "yorozu-wire-"));
process.env.YOROZU_PROJECTS_DIR = join(stateDir, "projects");
mkdirSync(process.env.YOROZU_PROJECTS_DIR);
const { serve } = await import("../dist/serve.js");
const { openaiCompat } = await import("../dist/provider.js");
const { listThreads, readThreadEvents } = await import("../dist/threads.js");

/** Answers every turn with `echo: <text>` in words spaced 50ms apart, so a drop can land mid-reply. */
const model = async (_url, init) => {
  const { content } = JSON.parse(init.body).messages.at(-1);
  const words = `echo: ${typeof content === "string" ? content : JSON.stringify(content)}`.split(" ");
  const encoder = new TextEncoder();
  const body = new ReadableStream({
    async start(controller) {
      for (const [i, word] of words.entries()) {
        const delta = { content: (i ? " " : "") + word };
        const finish = i === words.length - 1 ? "stop" : null;
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ choices: [{ delta, finish_reason: finish }] })}\n\n`));
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  });
  return new Response(body, { headers: { "content-type": "text/event-stream" } });
};

const relay = await startRelay(0);
let qrLine;
const qrPrinted = new Promise((resolve) => (qrLine = resolve));
const sidecar = serve({
  relayUrl: `ws://127.0.0.1:${relay.port}`,
  stateDir,
  provider: openaiCompat({ baseUrl: "https://model.invalid", model: "m", fetch: model }),
  nativeRunners: {},
  titler: async () => "",
  log: (line) => {
    if (line.startsWith("QR ")) qrLine(line.slice(3));
    else process.stderr.write(`${line}\n`);
  },
});

// The phone's side. Frame by frame rather than byte by byte, so dropping one direction leaves
// a connection that still works the other way, the way a lost receipt looks from the phone.
const links = new Set();
const fault = { blackholed: false, dropHost: false, down: false };
const dials = [];
const phones = new WebSocketServer({ noServer: true });
const proxy = createServer();
proxy.on("upgrade", (request, socket, head) => {
  dials.push(Math.round(performance.now()));
  if (fault.down) return socket.destroy();
  phones.handleUpgrade(request, socket, head, (phone) => {
    const upstream = new WebSocket(`ws://127.0.0.1:${relay.port}${request.url}`);
    const link = { phone, upstream, dead: fault.blackholed };
    links.add(link);
    const early = [];
    phone.on("message", (data, binary) => {
      if (link.dead) return;
      if (upstream.readyState === WebSocket.OPEN) upstream.send(data, { binary });
      else early.push([data, binary]);
    });
    upstream.on("open", () => { for (const [data, binary] of early.splice(0)) upstream.send(data, { binary }); });
    upstream.on("message", (data, binary) => { if (!link.dead && !fault.dropHost) phone.send(data, { binary }); });
    const drop = () => { phone.terminate(); upstream.terminate(); links.delete(link); };
    phone.on("close", drop).on("error", drop);
    upstream.on("close", drop).on("error", drop);
  });
});
await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));
const pairing = (await qrPrinted).replace(
  /relay=[^&]+/, `relay=${encodeURIComponent(`ws://127.0.0.1:${proxy.address().port}`)}`);

const faults = {
  blackhole() { fault.blackholed = true; for (const link of links) link.dead = true; },
  "drop-host"() { fault.dropHost = true; },
  down() { fault.down = true; for (const link of links) { link.phone.terminate(); link.upstream.terminate(); } },
  heal() { fault.blackholed = fault.dropHost = fault.down = false; },
};
const messages = (thread) => readThreadEvents(thread, stateDir)
  .filter((event) => event.kind === "message" && (event.data.role === "user" || event.data.done))
  .map((event) => ({ thread, role: event.data.role, text: event.data.text }));

const control = createServer((request, response) => {
  const url = new URL(request.url, "http://control");
  const name = url.pathname.slice(1);
  let body;
  if (request.method === "POST" && faults[name]) { faults[name](); body = { ok: name }; }
  else if (name === "pairing") body = { qr: pairing };
  else if (name === "dials") body = { dials };
  else if (name === "events") body = { events: readThreadEvents(url.searchParams.get("thread"), stateDir) };
  else if (name === "messages") body = { messages: listThreads(stateDir).flatMap((thread) => messages(thread.id)) };
  response.writeHead(body ? 200 : 404, { "content-type": "application/json" });
  response.end(JSON.stringify(body ?? { error: `no ${request.method} ${name}` }));
});
await new Promise((resolve) => control.listen(Number(process.argv[2] ?? 0), "127.0.0.1", resolve));
process.stdout.write(`${JSON.stringify({ control: control.address().port })}\n`);

async function stop() {
  control.close();
  proxy.close();
  await sidecar.close();
  await relay.close();
  process.exit(0);
}
process.stdin.on("end", stop).resume();
process.on("SIGTERM", stop).on("SIGINT", stop);
