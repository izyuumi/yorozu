import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
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

test("the sandbox denies network access (control)", () => {
  const probe = `require("node:net").connect(9, "127.0.0.1").on("error", (e) => { console.log(e.code); process.exit(0); });`;
  const result = spawnSync(process.execPath, [...sandbox, "-e", probe], { encoding: "utf8" });
  assert.equal(result.stdout.trim(), "ERR_ACCESS_DENIED", result.stderr);
});

test("stdio: every tool answers with network, writes and child processes denied", async () => {
  const client = await run([...sandbox, "src/stdio.ts"]);
  await callEveryTool(client);
  await client.close();
});
