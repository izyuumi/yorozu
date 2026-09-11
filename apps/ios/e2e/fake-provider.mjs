/**
 * Test helper, not product code: the smallest OpenAI-compatible endpoint the sidecar accepts.
 * The first turn calls one tool, so the run proves a tool_call reaches the phone's trace; the
 * next streams a fixed reply word by word so the phone has real deltas to append.
 *
 * Point the sidecar at it with YOROZU_BASE_URL=http://127.0.0.1:<PORT>.
 */
import { createServer } from "node:http";

const port = Number(process.env.PORT ?? 8799);
const reply = process.env.REPLY ?? "hello from the fake model";

const chunk = (delta) => `data: ${JSON.stringify({ choices: [delta] })}\n\n`;

let turn = 0;

createServer((req, res) => {
  req.resume(); // drain the request body; its contents do not matter here
  if (req.url === "/v1/models") {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ data: [{ id: "fake" }] }));
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
    for (const word of reply.split(" ")) {
      res.write(chunk({ delta: { content: `${word} ` } }));
    }
    res.write(chunk({ delta: {}, finish_reason: "stop" }));
  }
  res.end("data: [DONE]\n\n");
}).listen(port, () => console.log(`fake provider on :${port}`));
