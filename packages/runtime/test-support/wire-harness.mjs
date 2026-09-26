// The real relay and the real sidecar, with a TCP proxy between the relay and the phone that
// can fail the way a phone's network does. Driven by the Swift wire tests
// (packages/shared-swift/Tests/YorozuSharedTests/WireTests.swift); needs `pnpm -r build`.
//
// stdout, one JSON line each: {"qr", "proxy"} once ready, then one reply per command.
// stdin commands:
//   blackhole  every phone connection, open or new, stays open and carries nothing
//   down       destroy every phone connection now, and refuse new ones
//   heal       new connections carry traffic again; blackholed ones stay dead
//   dials      when each phone connection arrived, in ms since the harness started
//   events <threadId>  the thread's durable events, as the Mac recorded them
import { mkdirSync, mkdtempSync } from "node:fs";
import { createConnection, createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { startRelay } from "@yorozu/relay";

// stdout is this script's reply channel; the relay's own log lines go with the sidecar's.
console.log = console.error;

const stateDir = mkdtempSync(join(tmpdir(), "yorozu-wire-"));
process.env.YOROZU_PROJECTS_DIR = join(stateDir, "projects");
mkdirSync(process.env.YOROZU_PROJECTS_DIR);
const { serve } = await import("../dist/serve.js");
const { openaiCompat } = await import("../dist/provider.js");
const { readThreadEvents } = await import("../dist/threads.js");

/** Answers every turn with `echo: <text>` in words spaced 50ms apart, so a drop can land mid-reply. */
const model = async (_url, init) => {
  const { messages } = JSON.parse(init.body);
  const { content } = messages.at(-1);
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

/** Phone connections: the side the phone dialled and the side that reaches the relay. */
const links = new Set();
let blackholed = false;
let down = false;
const dials = [];
const proxy = createServer((phone) => {
  dials.push(Math.round(performance.now()));
  if (down) return phone.destroy();
  const upstream = createConnection(relay.port, "127.0.0.1");
  const link = { phone, upstream, dead: blackholed };
  links.add(link);
  phone.on("data", (data) => link.dead || upstream.write(data));
  upstream.on("data", (data) => link.dead || phone.write(data));
  const drop = () => { phone.destroy(); upstream.destroy(); links.delete(link); };
  phone.on("close", drop).on("error", drop);
  upstream.on("close", drop).on("error", drop);
});
await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));

const reply = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
reply({ qr: await qrPrinted, proxy: proxy.address().port });

for await (const line of createInterface({ input: process.stdin })) {
  const [command, arg] = line.trim().split(" ");
  if (command === "blackhole") {
    blackholed = true;
    for (const link of links) link.dead = true;
    reply({ ok: command });
  } else if (command === "down") {
    down = true;
    for (const link of links) { link.phone.destroy(); link.upstream.destroy(); }
    reply({ ok: command });
  } else if (command === "heal") {
    blackholed = down = false;
    reply({ ok: command });
  } else if (command === "dials") {
    reply({ dials });
  } else if (command === "events") {
    reply({ events: readThreadEvents(arg, stateDir) });
  } else {
    reply({ error: `unknown command ${command}` });
  }
}
// The test closing stdin is the end of the run.
proxy.close();
await sidecar.close();
await relay.close();
process.exit(0);
