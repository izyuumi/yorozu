// The MCP surface: tools, doc resources and the setup prompt, all answered from the bundled content.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import * as z from "zod";
import pkg from "../package.json" with { type: "json" };
import { content as bundled, type Content } from "./content.ts";
import * as help from "./help.ts";

const readOnly = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
const platform = z.enum(["ios", "macos"]).describe("ios for iPhone and iPad, macos for the Mac");
const text = (value: string): CallToolResult => ({ content: [{ type: "text", text: value }] });
const data = (value: object): CallToolResult => text(JSON.stringify(value, null, 2));
const error = (value: string): CallToolResult => ({ content: [{ type: "text", text: value }], isError: true });

export function createServer(content: Content = bundled): McpServer {
  const server = new McpServer(
    { name: "yorozu-help", title: "Yorozu Help", version: pkg.version },
    {
      instructions:
        "Read-only help for Yorozu, the end-to-end-encrypted OpenClaw chat app for iPhone, iPad and Mac. Answers come from the Yorozu repository's docs and code at build time. Start with get_setup_guide for a new user, troubleshoot for an error message, and search_docs for anything else. Nothing here reads or changes the user's devices.",
    },
  );

  server.registerTool(
    "search_docs",
    {
      title: "Search the Yorozu docs",
      description: "Full-text search over the Yorozu README, docs/ and plugin README. Returns the best matching sections with their resource URIs.",
      inputSchema: { query: z.string().min(1).max(200), limit: z.number().int().min(1).max(10).optional() },
      annotations: readOnly,
    },
    ({ query, limit }) => text(help.formatDocHits(query, help.searchDocs(content, query, limit))),
  );

  server.registerTool(
    "get_setup_guide",
    {
      title: "Setup guide",
      description: "Step-by-step setup for one platform: install the OpenClaw plugin, install the app, pair, notifications and voice input.",
      inputSchema: { platform },
      annotations: readOnly,
    },
    ({ platform }) => text(help.setupGuide(content, platform)),
  );

  server.registerTool(
    "list_settings",
    {
      title: "List settings",
      description: "Every app setting (key, default, options, where to find it) and every channels.yorozu host config key, from the app's code and the plugin manifest.",
      inputSchema: { platform: platform.optional() },
      annotations: readOnly,
    },
    ({ platform }) => data(help.listSettings(content, platform)),
  );

  server.registerTool(
    "explain_setting",
    {
      title: "Explain a setting",
      description: "What one setting does, its default, options, where to change it and the source files that define it. Accepts an app key (accent), its title (Accent Color) or a host key (channels.yorozu.agent, or agent).",
      inputSchema: { key: z.string().min(1).max(100) },
      annotations: readOnly,
    },
    ({ key }) => {
      const setting = help.findSetting(content, key);
      return setting ? data(setting) : error(`No setting "${key}". Known keys: ${help.settingKeys(content).join(", ")}.`);
    },
  );

  server.registerTool(
    "troubleshoot",
    {
      title: "Troubleshoot",
      description: "Match a symptom or the exact text the app or a command shows (relay or Gateway offline, pairing, voice model, microphone) to its cause and fix.",
      inputSchema: { symptom: z.string().min(1).max(500) },
      annotations: readOnly,
    },
    ({ symptom }) => text(help.formatTroubleshoot(symptom, help.troubleshoot(content, symptom))),
  );

  server.registerTool(
    "get_permissions_needed",
    {
      title: "Permissions needed",
      description: "The system permissions and entitlements the app has on one platform, with the prompt text the user sees and why.",
      inputSchema: { platform },
      annotations: readOnly,
    },
    ({ platform }) => data(help.permissionsNeeded(content, platform)),
  );

  server.registerTool(
    "latest_version",
    {
      title: "Latest version",
      description: "The newest Yorozu version in CHANGELOG.md and its release notes.",
      annotations: readOnly,
    },
    () => data(help.latestVersion(content)),
  );

  server.registerTool(
    "changelog",
    {
      title: "Changelog",
      description: "Release notes from CHANGELOG.md: one version, or the newest few.",
      inputSchema: {
        version: z.string().regex(/^v?\d+\.\d+\.\d+$/).optional().describe("for example 0.10.0"),
        limit: z.number().int().min(1).max(20).optional(),
      },
      annotations: readOnly,
    },
    ({ version, limit }) => {
      const notes = help.changelog(content, version, limit);
      return notes ? text(notes) : error(`No version ${version} in CHANGELOG.md. Versions: ${content.releases.map((r) => r.version).join(", ")}.`);
    },
  );

  for (const doc of content.docs) {
    server.registerResource(doc.id, doc.uri, { title: doc.title, description: `${doc.path} in the Yorozu repository`, mimeType: "text/markdown" }, (uri) => ({
      contents: [{ uri: uri.href, mimeType: "text/markdown", text: doc.text }],
    }));
  }

  server.registerPrompt(
    "setup_yorozu",
    {
      title: "Help me set up Yorozu",
      description: "Walks the user through setting up Yorozu, one step at a time.",
      argsSchema: { platform: z.enum(["ios", "macos"]).optional().describe("ios or macos; asked if missing") },
    },
    ({ platform }) => ({
      messages: [
        {
          role: "user",
          content: {
            type: "text",
            text: [
              "Help me set up Yorozu.",
              platform ? `I want to use it on ${platform === "ios" ? "an iPhone or iPad" : "a Mac"}.` : "Ask me first whether I'm setting it up on an iPhone or iPad, or on a Mac.",
              "Use the yorozu-help tools: get_setup_guide for the steps, get_permissions_needed for what the system will ask, list_settings and explain_setting for options, and troubleshoot with the exact text of any error.",
              "Go one step at a time and wait for me to confirm each one. Commands marked for the OpenClaw Gateway run on the computer that runs OpenClaw. Before pairing, remind me to check that the host key matches the fingerprint `openclaw yorozu pair` prints.",
            ].join(" "),
          },
        },
      ],
    }),
  );

  return server;
}
