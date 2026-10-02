// The real relay and the real sidecar, with a proxy between the relay and the phone that can
// fail the way a phone's network does. Test-only; needs `pnpm -r build`. Used by the Swift wire
// tests (packages/shared-swift/Tests/YorozuSharedTests/WireTests.swift) and the iOS UI tests
// (apps/ios/e2e/ui-tests.sh).
//
//   node wire-harness.mjs [control-port]
//
// Prints {"control": port} once ready, then serves on 127.0.0.1:port until stdin closes or it
// is signalled:
//   GET  /pairing         {"qr"}: a fresh pairing string, pointed at the proxy
//   POST /blackhole       every phone connection, open or new, stays open and carries nothing
//   POST /drop-host-after-phone-frame  drop host frames after the next encrypted phone frame reaches the relay
//   POST /down            close every phone connection now, and refuse new ones
//   POST /lose-joined     the next phone to join is cut off just as the relay says `joined`
//   POST /hold-answer     pause the next provider answer until /release-answer
//   GET  /answer-started[?text=...]  {"started","count"}: provider starts, optionally for one prompt
//   POST /release-answer  let the paused provider answer finish
//   POST /heal            back to normal for new connections and frames; blackholed ones stay dead
//   GET  /dials           {"dials"}: when each phone connection arrived, ms since start
//   GET  /events?thread=  {"events"}: the thread's durable events, as the Mac recorded them
//   GET  /messages        {"messages"}: every user message and finished answer the Mac recorded
//   POST /seed-search     write a host-only search match without broadcasting it to the phone
//   GET  /metrics         content-free traffic and queue byte counts
// Set LINK_DELAY_MS and LINK_BYTES_PER_SECOND to shape both phone directions.
import { randomUUID } from "node:crypto";
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
const { appendThreadEvent, createThread, listThreads, readThreadEvents } = await import("../dist/threads.js");
const delayMs = Number(process.env.LINK_DELAY_MS ?? 0);
const bytesPerSecond = Number(process.env.LINK_BYTES_PER_SECOND ?? 0);
if (!Number.isFinite(delayMs) || delayMs < 0 || !Number.isFinite(bytesPerSecond) || bytesPerSecond < 0) {
  throw new Error("LINK_DELAY_MS and LINK_BYTES_PER_SECOND must be nonnegative finite numbers");
}

let heldAnswer;
let answerStarted = false;
let answerStarts = 0;
const answerStartsByPrompt = new Map();

/** Answers every turn with `echo: <text>` in words spaced 50ms apart, so a drop can land mid-reply. */
const model = async (_url, init) => {
  answerStarts++;
  const { content } = JSON.parse(init.body).messages.at(-1);
  const prompt = typeof content === "string" ? content : JSON.stringify(content);
  answerStartsByPrompt.set(prompt, (answerStartsByPrompt.get(prompt) ?? 0) + 1);
  const release = heldAnswer;
  if (release) answerStarted = true;
  const large = content === "__large_answer__";
  const words = large ? Array(48).fill("x".repeat(2048)) : `echo: ${prompt}`.split(" ");
  const encoder = new TextEncoder();
  const body = new ReadableStream({
    async start(controller) {
      if (release) await release.promise;
      for (const [i, word] of words.entries()) {
        const delta = { content: (i && !large ? " " : "") + word };
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
let firstQr;
const qrPrinted = new Promise((resolve) => (firstQr = resolve));
const pendingQr = [];
const sidecar = serve({
  relayUrl: `ws://127.0.0.1:${relay.port}`,
  stateDir,
  // Keep Settings scrolling coverage independent of the runner's computer name.
  computerName: () => "UI test Mac with a long computer name that wraps across several lines in Settings",
  provider: openaiCompat({ baseUrl: "https://model.invalid", model: "m", fetch: model }),
  nativeRunners: {},
  titler: async () => "",
  log: (line) => {
    if (line.startsWith("QR ")) {
      const qr = line.slice(3);
      if (firstQr) { firstQr(qr); firstQr = undefined; }
      else pendingQr.shift()?.(qr);
    }
    else process.stderr.write(`${line}\n`);
  },
});

// The phone's side. Frame by frame rather than byte by byte, so dropping one direction leaves
// a connection that still works the other way, the way a lost receipt looks from the phone.
const links = new Set();
const fault = { blackholed: false, dropHost: false, dropHostAfterPhoneFrame: false, down: false, loseJoined: false };
const dials = [];
const stats = { phoneToHostBytes: 0, hostToPhoneBytes: 0, droppedHostBytes: 0, peakQueuedBytes: 0 };
let queuedBytes = 0;
function recordQueuePeak() {
  const buffered = [...links].reduce((sum, link) => sum + link.phone.bufferedAmount + link.upstream.bufferedAmount, 0);
  stats.peakQueuedBytes = Math.max(stats.peakQueuedBytes, queuedBytes + buffered);
}
function isRelayFrame(data, binary) {
  if (binary) return false;
  try { return JSON.parse(data.toString()).type === "frame"; }
  catch { return false; }
}
function forward(link, direction, data, binary) {
  const sink = direction === "phoneToHostBytes" ? link.upstream : link.phone;
  const bytes = data.byteLength;
  const now = performance.now();
  const lane = direction === "phoneToHostBytes" ? "toHostAt" : "toPhoneAt";
  const readyAt = Math.max(now + delayMs, link[lane]) + (bytesPerSecond ? bytes * 1000 / bytesPerSecond : 0);
  link[lane] = readyAt;
  queuedBytes += bytes;
  recordQueuePeak();
  const deliver = () => {
    queuedBytes -= bytes;
    if (direction === "hostToPhoneBytes" && fault.dropHost) {
      stats.droppedHostBytes += bytes;
    } else if (!link.dead && sink.readyState === WebSocket.OPEN) {
      sink.send(data, { binary });
      stats[direction] += bytes;
      if (direction === "phoneToHostBytes" && fault.dropHostAfterPhoneFrame && isRelayFrame(data, binary)) {
        fault.dropHostAfterPhoneFrame = false;
        fault.dropHost = true;
      }
    }
    recordQueuePeak();
  };
  if (readyAt > now) setTimeout(deliver, readyAt - now);
  else deliver();
}
const phones = new WebSocketServer({ noServer: true });
const proxy = createServer();
proxy.on("upgrade", (request, socket, head) => {
  dials.push(Math.round(performance.now()));
  if (fault.down) return socket.destroy();
  phones.handleUpgrade(request, socket, head, (phone) => {
    const upstream = new WebSocket(`ws://127.0.0.1:${relay.port}${request.url}`);
    const link = { phone, upstream, dead: fault.blackholed, toHostAt: 0, toPhoneAt: 0 };
    links.add(link);
    const early = [];
    phone.on("message", (data, binary) => {
      if (link.dead) return;
      if (upstream.readyState === WebSocket.OPEN) forward(link, "phoneToHostBytes", data, binary);
      else { early.push([data, binary]); queuedBytes += data.byteLength; recordQueuePeak(); }
    });
    upstream.on("open", () => {
      for (const [data, binary] of early.splice(0)) {
        queuedBytes -= data.byteLength;
        forward(link, "phoneToHostBytes", data, binary);
      }
    });
    upstream.on("message", (data, binary) => {
      if (fault.loseJoined && !binary && data.toString().includes('"type":"joined"')) {
        fault.loseJoined = false;
        return phone.terminate();
      }
      if (!link.dead && !fault.dropHost) forward(link, "hostToPhoneBytes", data, binary);
      else if (fault.dropHost) stats.droppedHostBytes += data.byteLength;
    });
    const forget = () => {
      if (links.delete(link)) {
        for (const [data] of early.splice(0)) queuedBytes -= data.byteLength;
      }
      recordQueuePeak();
    };
    const drop = () => {
      forget();
      phone.terminate(); upstream.terminate();
    };
    // A close the relay says out loud reaches the phone as it was said; its reason is what the
    // phone acts on. 1005 and 1006 mean nothing was said, and cannot be sent on.
    const closedByRelay = (code, reason) => {
      if (link.dead || code === 1005 || code === 1006) return drop();
      forget();
      phone.close(code, reason);
      upstream.terminate();
    };
    phone.on("close", drop).on("error", drop);
    upstream.on("close", closedByRelay).on("error", drop);
  });
});
await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));
await qrPrinted;
function freshPairing() {
  // CI can spend longer than the relay's 10-minute token lifetime building iOS tests.
  return new Promise((resolve, reject) => {
    const onQr = (qr) => {
      clearTimeout(timeout);
      resolve(qr.replace(/relay=[^&]+/, `relay=${encodeURIComponent(`ws://127.0.0.1:${proxy.address().port}`)}`));
    };
    const timeout = setTimeout(() => {
      pendingQr.splice(pendingQr.indexOf(onQr), 1);
      reject(new Error("pairing token unavailable"));
    }, 10_000);
    pendingQr.push(onQr);
    sidecar.mint();
  });
}

const faults = {
  blackhole() { fault.blackholed = true; for (const link of links) link.dead = true; },
  "drop-host-after-phone-frame"() { fault.dropHostAfterPhoneFrame = true; },
  down() { fault.down = true; for (const link of links) { link.phone.terminate(); link.upstream.terminate(); } },
  "lose-joined"() { fault.loseJoined = true; },
  "hold-answer"() {
    heldAnswer?.resolve();
    heldAnswer = Promise.withResolvers();
    answerStarted = false;
    answerStarts = 0;
    answerStartsByPrompt.clear();
  },
  "release-answer"() { heldAnswer?.resolve(); heldAnswer = undefined; },
  heal() {
    fault.blackholed = fault.dropHost = fault.dropHostAfterPhoneFrame = fault.down = fault.loseJoined = false;
    heldAnswer?.resolve();
    heldAnswer = undefined;
  },
};
const messages = (thread) => readThreadEvents(thread, stateDir)
  .filter((event) => event.kind === "message" && (event.data.role === "user" || event.data.done))
  .map((event) => ({ thread, role: event.data.role, text: event.data.text }));

const control = createServer((request, response) => {
  const url = new URL(request.url, "http://control");
  const name = url.pathname.slice(1);
  let body;
  if (request.method === "POST" && faults[name]) { faults[name](); body = { ok: name }; }
  else if (request.method === "POST" && name === "seed-search") {
    const thread = createThread("Host-only search fixture", stateDir);
    const old = Date.now() - 100_000;
    appendThreadEvent({ id: randomUUID(), threadId: thread.id, ts: old, agentId: "main",
      kind: "message", data: { role: "user", text: "host-only marker 6e72" } }, stateDir);
    for (let index = 0; index < 45; index++) {
      appendThreadEvent({ id: randomUUID(), threadId: thread.id, ts: old + (index + 1) * 1_000,
        agentId: "main", kind: "message", data: { role: "user", text: `newer ordinary message ${index}` } }, stateDir);
    }
    body = { threadId: thread.id };
  }
  else if (name === "pairing") {
    freshPairing().then((qr) => {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ qr }));
    }, () => {
      response.writeHead(503, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "pairing token unavailable" }));
    });
    return;
  }
  else if (name === "dials") body = { dials };
  else if (name === "metrics") { recordQueuePeak(); body = { delayMs, bytesPerSecond, ...stats }; }
  else if (name === "answer-started") {
    const prompt = url.searchParams.get("text");
    const count = prompt === null ? answerStarts : (answerStartsByPrompt.get(prompt) ?? 0);
    body = { started: prompt === null ? answerStarted : count > 0, count };
  }
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
