import assert from "node:assert/strict";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { content } from "../src/content.ts";
import { createServer } from "../src/server.ts";
import { callEveryTool, textOf, toolNames } from "./calls.ts";

async function connect(): Promise<Client> {
  const [a, b] = InMemoryTransport.createLinkedPair();
  await createServer().connect(a);
  const client = new Client({ name: "test", version: "0" });
  await client.connect(b);
  return client;
}

test("lists exactly the read-only tools", async () => {
  const client = await connect();
  const { tools } = await client.listTools();
  assert.deepEqual(tools.map((t) => t.name).sort(), toolNames);
  for (const tool of tools) {
    assert.equal(tool.annotations?.readOnlyHint, true, tool.name);
    assert.equal(tool.annotations?.openWorldHint, false, tool.name);
    assert.equal(tool.annotations?.destructiveHint, false, tool.name);
  }
  await client.close();
});

test("every tool answers", async () => {
  const client = await connect();
  const out = await callEveryTool(client);
  assert.match(out.get_setup_guide, /# Set up Yorozu/i);
  assert.equal(JSON.parse(out.explain_setting).key, "accent");
  assert.ok(JSON.parse(out.get_permissions_needed).permissions.length >= 3);
  assert.equal(JSON.parse(out.latest_version).version, content.releases[0].version);
  assert.ok(JSON.parse(out.list_settings).host.length > 0);
  assert.match(out.search_docs, /yorozu:\/\/docs\//);
  assert.match(out.troubleshoot, /relay/i);
  assert.match(out.changelog, /^## \d/);
  await client.close();
});

test("bad arguments come back as tool errors", async () => {
  const client = await connect();
  const unknown = await client.callTool({ name: "explain_setting", arguments: { key: "nope" } });
  assert.equal(unknown.isError, true);
  assert.match(textOf(unknown), /Known keys: .*accent/);
  const missing = await client.callTool({ name: "changelog", arguments: { version: "99.0.0" } });
  assert.equal(missing.isError, true);
  const invalid = await client.callTool({ name: "get_setup_guide", arguments: { platform: "android" } });
  assert.equal(invalid.isError, true);
  await client.close();
});

test("every docs page is a resource", async () => {
  const client = await connect();
  const { resources } = await client.listResources();
  assert.deepEqual(resources.map((r) => r.uri).sort(), content.docs.map((d) => d.uri).sort());
  for (const doc of content.docs) {
    const { contents } = await client.readResource({ uri: doc.uri });
    assert.equal(contents[0].mimeType, "text/markdown");
    assert.equal((contents[0] as { text: string }).text, doc.text);
  }
  await client.close();
});

test("the setup prompt", async () => {
  const client = await connect();
  const { prompts } = await client.listPrompts();
  assert.deepEqual(prompts.map((p) => [p.name, p.title]), [["setup_yorozu", "Help me set up Yorozu"]]);
  const ios = await client.getPrompt({ name: "setup_yorozu", arguments: { platform: "ios" } });
  const text = (ios.messages[0].content as { text: string }).text;
  assert.match(text, /iPhone or iPad/);
  assert.match(text, /get_setup_guide/);
  const any = await client.getPrompt({ name: "setup_yorozu", arguments: {} });
  assert.match((any.messages[0].content as { text: string }).text, /Ask me first/);
  await client.close();
});
