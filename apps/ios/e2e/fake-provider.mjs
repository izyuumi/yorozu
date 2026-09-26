/**
 * Test helper, not product code: the smallest OpenAI-compatible endpoint the sidecar accepts.
 * The first turn calls one tool, so the run proves a tool_call reaches the phone's trace; the
 * next streams a fixed reply word by word so the phone has real deltas to append.
 *
 * Point the sidecar at it with YOROZU_BASE_URL=http://127.0.0.1:<PORT>.
 */
import { createServer } from "node:http";
import { existsSync } from "node:fs";

const port = Number(process.env.PORT ?? 8799);
const reply = process.env.REPLY ?? "hello from the fake model";
/** Milliseconds between words. Zero for the e2e run; set it to watch a reply stream. */
const delay = Number(process.env.DELAY_MS ?? 0);
const faultFile = process.env.FAULT_FILE;
const releaseFile = process.env.RELEASE_FILE;

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

const chunk = (delta) => `data: ${JSON.stringify({ choices: [delta] })}\n\n`;

let turn = 0;

createServer(async (req, res) => {
  req.resume(); // drain the request body; its contents do not matter here
  if (req.url === "/v1/models") {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ data: [{ id: "fake" }] }));
  }
  console.log(`request ${turn + 1}`);
  const faultTurn = faultFile && existsSync(faultFile);
  if (faultTurn && releaseFile) {
    while (!existsSync(releaseFile)) await sleep(50);
  }
  res.writeHead(200, { "content-type": "text/event-stream" });
  if (turn++ === 0) {
    // The loop runs `echo` itself and comes back for the reply.
    res.write(
      chunk({
        delta: {
          tool_calls: [
            {
              index: 0,
              id: "call_1",
              function: { name: "echo", arguments: JSON.stringify({ text: "hi" }) },
            },
          ],
        },
        finish_reason: "tool_calls",
      }),
    );
  } else {
    for (const word of (faultTurn ? "finished after disconnect" : reply).split(" ")) {
      res.write(chunk({ delta: { content: `${word} ` } }));
      if (delay) await sleep(delay);
    }
    res.write(chunk({ delta: {}, finish_reason: "stop" }));
  }
  res.end("data: [DONE]\n\n");
}).listen(port, () => console.log(`fake provider on :${port}`));
