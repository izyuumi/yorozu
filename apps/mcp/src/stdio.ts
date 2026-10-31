#!/usr/bin/env node
// stdio transport: `npx <path to apps/mcp>` or `node src/stdio.ts`. Logs go to stderr; stdout carries MCP.
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createServer } from "./server.ts";

await createServer().connect(new StdioServerTransport());
