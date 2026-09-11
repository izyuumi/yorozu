/**
 * Claude through the installed `claude` CLI and its subscription login.
 *
 * The SDK is used for auth and streaming only. Our loop still owns tool dispatch, so the
 * tools go in as an in-process MCP server whose calls `canUseTool` denies: the attempted
 * call is exactly the event the loop wants back, and the handler never runs.
 * See docs/spec-v1.html section 2.
 */

import { createSdkMcpServer, query } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import {
  onPath,
  renderTranscript,
  runCli,
  systemOf,
  type Provider,
  type ToolCall,
} from "./provider.js";

const BINARY = "claude";
/** MCP server name. The CLI exposes its tools as `mcp__<server>__<tool>`. */
const SERVER = "yorozu";
const PREFIX = `mcp__${SERVER}__`;

export interface ClaudeCliConfig {
  /** Empty means whatever the CLI is already configured to use. */
  model?: string;
}

type JsonSchema = {
  type?: string;
  description?: string;
  enum?: string[];
  items?: JsonSchema;
  properties?: Record<string, JsonSchema>;
  required?: string[];
};

/** Our ToolDefs carry JSON Schema; the SDK's MCP server only takes zod. */
function zodField(schema: JsonSchema): z.ZodType {
  const field = (): z.ZodType => {
    if (schema.enum?.length) return z.enum(schema.enum as [string, ...string[]]);
    switch (schema.type) {
      case "string":
        return z.string();
      case "number":
      case "integer":
        return z.number();
      case "boolean":
        return z.boolean();
      case "array":
        return z.array(schema.items ? zodField(schema.items) : z.unknown());
      case "object":
        return z.object(zodShape(schema));
      default:
        return z.unknown();
    }
  };
  return schema.description ? field().describe(schema.description) : field();
}

function zodShape(schema: JsonSchema): Record<string, z.ZodType> {
  const required = new Set(schema.required ?? []);
  return Object.fromEntries(
    Object.entries(schema.properties ?? {}).map(([name, property]) => [
      name,
      required.has(name) ? zodField(property) : zodField(property).optional(),
    ]),
  );
}

export function claudeCli(config: ClaudeCliConfig = {}): Provider {
  return {
    async auth() {
      if (!onPath(BINARY)) return { ok: false, reason: `${BINARY} is not on PATH` };
      try {
        // Reports whether a login exists; the credential itself is never read.
        const { stdout } = await runCli(BINARY, ["auth", "status", "--json"]);
        const status = JSON.parse(stdout) as { loggedIn?: boolean };
        return status.loggedIn
          ? { ok: true }
          : { ok: false, reason: `${BINARY} is installed but not logged in` };
      } catch (e) {
        return { ok: false, reason: e instanceof Error ? e.message : String(e) };
      }
    },

    async *stream(messages, tools) {
      const server = createSdkMcpServer({
        name: SERVER,
        tools: tools.map((tool) => ({
          name: tool.name,
          description: tool.description,
          inputSchema: zodShape((tool.parameters ?? {}) as JsonSchema),
          // Unreachable: the permission callback denies every call first.
          handler: async () => ({ content: [{ type: "text" as const, text: "" }] }),
        })),
      });

      const system = systemOf(messages);
      const session = query({
        prompt: renderTranscript(messages),
        options: {
          ...(config.model ? { model: config.model } : {}),
          ...(system ? { systemPrompt: system } : {}),
          // None of Claude Code's own tools and none of the user's settings files:
          // this is Yorozu's loop, not a coding session.
          tools: [],
          settingSources: [],
          mcpServers: { [SERVER]: server },
          maxTurns: 1,
          // A tool named in `allowedTools` would be auto-approved and run in-process,
          // so the tools stay unlisted and fall through to here.
          canUseTool: async () => ({
            behavior: "deny" as const,
            message: "the Yorozu loop dispatches tools",
            interrupt: true,
          }),
        },
      });

      const calls: ToolCall[] = [];
      try {
        for await (const message of session) {
          if (message.type !== "assistant") continue;
          for (const block of message.message.content) {
            if (block.type === "text") {
              if (block.text) yield { type: "text", text: block.text };
            } else if (block.type === "tool_use") {
              calls.push({
                id: block.id,
                name: block.name.startsWith(PREFIX)
                  ? block.name.slice(PREFIX.length)
                  : block.name,
                arguments: JSON.stringify(block.input ?? {}),
              });
            }
          }
          if (calls.length) break;
        }
      } catch (e) {
        // The denial interrupts the turn, which surfaces as a failed result. A real
        // failure (auth, rate limit, transport) has no call to show for it.
        if (!calls.length) throw e;
      } finally {
        session.close();
      }

      for (const call of calls) yield { type: "tool_call", call };
      yield { type: "done", reason: calls.length ? "tool_calls" : "stop" };
    },
  };
}
