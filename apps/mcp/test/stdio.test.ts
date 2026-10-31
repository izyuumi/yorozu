import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createServer as createNetServer, type AddressInfo } from "node:net";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { callEveryTool, toolNames } from "./calls.ts";

const pkgDir = fileURLToPath(new URL("..", import.meta.url));
const repoRoot = realpathSync(fileURLToPath(new URL("../../..", import.meta.url)));
// Node's permission model: read files under the repository, nothing else (no network, no writes, no child processes).
const sandbox = ["--permission", `--allow-fs-read=${repoRoot}`];

async function run(args: string[]) {
  const client = new Client({ name: "test", version: "0" });
  await client.connect(new StdioClientTransport({ command: process.execPath, args, cwd: pkgDir, stderr: "pipe" }));
  return client;
}

test("stdio: every tool, a resource and the prompt, end to end", async () => {
  const client = await run(["src/stdio.ts"]);
  assert.deepEqual((await client.listTools()).tools.map((t) => t.name).sort(), toolNames);
  await callEveryTool(client);
  const { contents } = await client.readResource({ uri: "yorozu://docs/setup" });
  assert.match((contents[0] as { text: string }).text, /^# /);
  assert.equal((await client.getPrompt({ name: "setup_yorozu", arguments: { platform: "macos" } })).messages.length, 1);
  await client.close();
});

// Node 24 has no network permission (--allow-net came in Node 25), so there the sandbox does not block connections.
const netPermission = process.allowedNodeEnvironmentFlags.has("--allow-net");

test("the sandbox denies network access (control)", { skip: !netPermission && "this Node has no network permission (--allow-net needs Node 25 or later)" }, async () => {
  // A listening server, so a refused connection cannot pass for a denied one.
  const server = createNetServer((socket) => socket.end()).listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address() as AddressInfo;
  const probe = `require("node:net").connect(${port}, "127.0.0.1").on("connect", () => { console.log("connected"); process.exit(0); }).on("error", () => { console.log("blocked"); process.exit(0); });`;
  const child = spawn(process.execPath, [...sandbox, "-e", probe]);
  let stdout = "";
  child.stdout.on("data", (d) => (stdout += d));
  await once(child, "exit");
  server.close();
  assert.equal(stdout.trim(), "blocked");
});

test("stdio: every tool answers in the sandbox (no writes or child processes; no network on Node 25 or later)", async () => {
  const client = await run([...sandbox, "src/stdio.ts"]);
  await callEveryTool(client);
  await client.close();
});
