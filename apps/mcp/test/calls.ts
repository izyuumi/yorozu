// Calls every tool once with a realistic argument; shared by the in-process, stdio and sandboxed runs.
import assert from "node:assert/strict";
import type { Client } from "@modelcontextprotocol/sdk/client/index.js";

export const toolNames = [
  "changelog",
  "explain_setting",
  "get_permissions_needed",
  "get_setup_guide",
  "latest_version",
  "list_settings",
  "search_docs",
  "troubleshoot",
];

export function textOf(result: unknown): string {
  const content = (result as { content: { type: string; text: string }[] }).content;
  return content.map((c) => c.text).join("\n");
}

export async function callEveryTool(client: Client): Promise<Record<string, string>> {
  const calls: Record<string, Record<string, unknown>> = {
    changelog: {},
    explain_setting: { key: "accent" },
    get_permissions_needed: { platform: "ios" },
    get_setup_guide: { platform: "macos" },
    latest_version: {},
    list_settings: {},
    search_docs: { query: "pair a device" },
    troubleshoot: { symptom: "relay offline" },
  };
  const out: Record<string, string> = {};
  for (const [name, args] of Object.entries(calls)) {
    const result = await client.callTool({ name, arguments: args });
    assert.ok(!result.isError, `${name} failed: ${textOf(result)}`);
    out[name] = textOf(result);
    assert.ok(out[name].length > 20, `${name} answered too little`);
  }
  return out;
}
