#!/usr/bin/env node
/**
 * The Yorozu tool catalog as a stdio MCP server, for Codex to call.
 *
 * It runs no tool of its own: a `tools/call` is forwarded over a Unix socket to the codex.ts
 * adapter that spawned Codex, and the adapter hands it to the loop, which applies approval,
 * dispatches and records it exactly as it does for any other provider. One catalog, one
 * permission model. See docs/spec-v1.html section 2.
 *
 * Spawned as `node dist/mcp-bridge.js <config.json>`, where the config file holds the socket
 * path and the ToolDefs of that one turn.
 */

import { readFileSync } from "node:fs";
import { connect } from "node:net";
import { argv, stdin, stdout } from "node:process";
import { createInterface } from "node:readline";
import type { ToolDef } from "./provider.js";

/** What the adapter writes for the bridge to read, and the only argument the bridge takes. */
export interface BridgeConfig {
  /** Unix socket the adapter is listening on. */
  socket: string;
  tools: ToolDef[];
}

/** What crosses the socket: one JSON line each way. */
export interface BridgeCall {
  name: string;
  arguments: unknown;
}

const MCP_VERSION = "2025-06-18";

/** Forwards one call to the adapter and resolves with the result it sends back. */
export function callAdapter(socketPath: string, call: BridgeCall): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = connect(socketPath);
    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("connect", () => socket.write(`${JSON.stringify(call)}\n`));
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      socket.end();
      resolve((JSON.parse(buffer.slice(0, newline)) as { result: string }).result);
    });
    socket.on("error", reject);
    // Only reached before a result: the adapter is gone, so the turn it belonged to is too.
    socket.on("close", () => reject(new Error("yorozu bridge: the adapter closed the socket")));
  });
}

/**
 * Serves MCP over the given streams until stdin ends. Line-delimited JSON-RPC, which is what
 * the stdio transport is; only the four methods a client needs to list and call tools are
 * answered, because those are the only ones Codex sends us.
 */
export function serveMcp(
  config: BridgeConfig,
  input: NodeJS.ReadableStream = stdin,
  output: NodeJS.WritableStream = stdout,
): Promise<void> {
  const send = (body: Record<string, unknown>): void => {
    output.write(`${JSON.stringify({ jsonrpc: "2.0", ...body })}\n`);
  };

  const handle = async (method: string, params: Record<string, unknown>): Promise<unknown> => {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: MCP_VERSION,
          capabilities: { tools: {} },
          serverInfo: { name: "yorozu", version: "1.5" },
        };
      case "ping":
        return {};
      case "tools/list":
        return {
          tools: config.tools.map((tool) => ({
            name: tool.name,
            description: tool.description,
            inputSchema: tool.parameters ?? { type: "object", properties: {} },
          })),
        };
      case "tools/call": {
        const text = await callAdapter(config.socket, {
          name: String(params.name ?? ""),
          arguments: params.arguments ?? {},
        });
        return { content: [{ type: "text", text }] };
      }
      default:
        throw new Error(`unknown method: ${method}`);
    }
  };

  const lines = createInterface({ input });
  lines.on("line", (line) => {
    if (!line.trim()) return;
    const request = JSON.parse(line) as {
      id?: number | string;
      method: string;
      params?: Record<string, unknown>;
    };
    // A request without an id is a notification — `notifications/initialized` and friends
    // want no answer at all, not even an error.
    if (request.id === undefined) return;
    void handle(request.method, request.params ?? {}).then(
      (result) => send({ id: request.id, result }),
      (e: unknown) => {
        const message = e instanceof Error ? e.message : String(e);
        // A failed tool call is a result the model should see and retry from; anything else
        // is the protocol going wrong, which is an error frame.
        if (request.method === "tools/call") {
          send({
            id: request.id,
            result: { content: [{ type: "text", text: `error: ${message}` }], isError: true },
          });
        } else {
          send({ id: request.id, error: { code: -32601, message } });
        }
      },
    );
  });
  return new Promise((resolve) => lines.on("close", () => resolve()));
}

// Spawned by the adapter, never imported by it.
if (argv[1]?.endsWith("mcp-bridge.js")) {
  await serveMcp(JSON.parse(readFileSync(argv[2] ?? "", "utf8")) as BridgeConfig);
}
