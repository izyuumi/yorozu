// Test-only phone link. Touch DROP_FILE to lose host frames while phone sends still reach host.
import { existsSync } from "node:fs";
import { createRequire } from "node:module";

const { WebSocket, WebSocketServer } = createRequire(new URL("../../relay/package.json", import.meta.url))("ws");

const port = Number(process.env.PORT ?? 8792);
const upstream = process.env.UPSTREAM ?? "ws://127.0.0.1:8791";
const dropFile = process.env.DROP_FILE;

new WebSocketServer({ port }).on("connection", (phone) => {
  console.log("phone connected");
  const relay = new WebSocket(upstream);
  const pending = [];
  phone.on("message", (data, isBinary) => {
    if (relay.readyState === WebSocket.OPEN) relay.send(data, { binary: isBinary });
    else pending.push([data, isBinary]);
  });
  relay.on("open", () => {
    for (const [data, isBinary] of pending) relay.send(data, { binary: isBinary });
    pending.length = 0;
  });
  relay.on("message", (data, isBinary) => {
    if (dropFile && existsSync(dropFile)) {
      console.log("dropped host frame");
      return;
    }
    if (phone.readyState === WebSocket.OPEN) phone.send(data, { binary: isBinary });
  });
  phone.on("close", (code) => { console.log(`phone closed ${code}`); relay.close(); });
  relay.on("close", (code) => { console.log(`relay closed ${code}`); phone.close(); });
  phone.on("error", (error) => { console.log(`phone error ${error.message}`); relay.close(); });
  relay.on("error", (error) => { console.log(`relay error ${error.message}`); phone.close(); });
}).on("listening", () => console.log(`fault proxy listening on :${port}`));
