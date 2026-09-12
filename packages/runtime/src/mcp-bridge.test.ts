import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { afterEach, expect, test } from "vitest";
import { serveMcp, type BridgeConfig } from "./mcp-bridge.js";

const TOOLS = [
  {
    name: "echo",
    description: "Echo the given text back to the caller.",
    parameters: { type: "object", properties: { text: { type: "string" } } },
  },
];

let cleanup: (() => Promise<void>)[] = [];

afterEach(async () => {
  for (const done of cleanup.splice(0)) await done();
});

/** An adapter-side socket that answers every forwarded call with `answer`. */
async function fakeAdapter(answer: string): Promise<{ path: string; seen: unknown[] }> {
  const dir = await mkdtemp(join(tmpdir(), "yorozu-bridge-test-"));
  const path = join(dir, "tools.sock");
  const seen: unknown[] = [];
  const server = createServer((socket) => {
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      seen.push(JSON.parse(chunk));
      socket.end(`${JSON.stringify({ result: answer })}\n`);
    });
  });
  await new Promise<void>((resolve) => server.listen(path, resolve));
  cleanup.push(async () => {
    server.close();
    await rm(dir, { recursive: true, force: true });
  });
  return { path, seen };
}

/** Drives the server over a pair of pipes and collects the frames it writes back. */
function driven(config: BridgeConfig) {
  const input = new PassThrough();
  const output = new PassThrough();
  const frames: Record<string, any>[] = [];
  output.setEncoding("utf8");
  let buffer = "";
  output.on("data", (chunk: string) => {
    buffer += chunk;
    for (let i; (i = buffer.indexOf("\n")) >= 0; buffer = buffer.slice(i + 1)) {
      frames.push(JSON.parse(buffer.slice(0, i)));
    }
  });
  const closed = serveMcp(config, input, output);
  return {
    frames,
    send: (body: unknown) => input.write(`${JSON.stringify(body)}\n`),
    async next(): Promise<Record<string, any>> {
      const before = frames.length;
      while (frames.length === before) await new Promise((r) => setTimeout(r, 5));
      return frames[before]!;
    },
    async end() {
      input.end();
      await closed;
    },
  };
}

test("initialize, tools/list and a tools/call that round-trips over the socket", async () => {
  const adapter = await fakeAdapter("pong");
  const mcp = driven({ socket: adapter.path, tools: TOOLS });

  mcp.send({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} });
  expect(await mcp.next()).toMatchObject({
    id: 1,
    result: { capabilities: { tools: {} }, serverInfo: { name: "yorozu" } },
  });

  // A notification is answered with nothing at all, not even an error frame.
  mcp.send({ jsonrpc: "2.0", method: "notifications/initialized" });

  mcp.send({ jsonrpc: "2.0", id: 2, method: "tools/list" });
  expect(await mcp.next()).toEqual({
    jsonrpc: "2.0",
    id: 2,
    result: {
      tools: [
        {
          name: "echo",
          description: TOOLS[0]!.description,
          inputSchema: TOOLS[0]!.parameters,
        },
      ],
    },
  });

  mcp.send({
    jsonrpc: "2.0",
    id: 3,
    method: "tools/call",
    params: { name: "echo", arguments: { text: "ping" } },
  });
  expect(await mcp.next()).toEqual({
    jsonrpc: "2.0",
    id: 3,
    result: { content: [{ type: "text", text: "pong" }] },
  });
  // The bridge ran nothing itself: the call went to the adapter as it stood.
  expect(adapter.seen).toEqual([{ name: "echo", arguments: { text: "ping" } }]);

  await mcp.end();
  expect(mcp.frames).toHaveLength(3);
});

test("a call the adapter cannot take comes back as a failed tool result", async () => {
  const mcp = driven({ socket: join(tmpdir(), "yorozu-nothing-here.sock"), tools: TOOLS });

  mcp.send({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "echo" } });
  expect(await mcp.next()).toMatchObject({ id: 1, result: { isError: true } });

  mcp.send({ jsonrpc: "2.0", id: 2, method: "resources/list" });
  expect(await mcp.next()).toMatchObject({ id: 2, error: { code: -32601 } });

  await mcp.end();
});
