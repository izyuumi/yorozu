/**
 * Codex through the installed `codex` binary and its subscription login.
 *
 * Codex takes tools only from an MCP server, so the loop's catalog goes in as one: a local
 * stdio bridge (mcp-bridge.ts) that executes nothing and forwards each call over a Unix
 * socket to this adapter. A forwarded call is emitted as a normal `tool_call` event and the
 * Codex turn is left waiting; the loop dispatches it with the same approval and recording as
 * for any provider, and the next `stream` call carries the result back down the socket. So
 * one Yorozu turn is one Codex turn, paused as many times as it calls tools.
 * See docs/spec-v1.html section 2.
 */

import { Codex, type ThreadEvent } from "@openai/codex-sdk";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { execPath } from "node:process";
import { fileURLToPath } from "node:url";
import type { BridgeCall } from "./mcp-bridge.js";
import {
  onPath,
  renderTranscript,
  runCli,
  systemOf,
  type Message,
  type Provider,
  type ProviderEvent,
  type ToolCall,
  type ToolDef,
} from "./provider.js";

const BINARY = "codex";
/** MCP server name Codex knows the catalog by. */
const SERVER = "yorozu";
const BRIDGE = fileURLToPath(new URL("./mcp-bridge.js", import.meta.url));

export interface CodexCliConfig {
  /** Empty means whatever the CLI is already configured to use. */
  model?: string;
}

/** One call the bridge forwarded, and the way back to it. */
interface Pending {
  call: ToolCall;
  reply(result: string): void;
}

interface Socket {
  path: string;
  /** The next forwarded call, whenever it arrives. */
  next(): Promise<Pending>;
  close(): void;
}

/** Where the bridge sends the calls it refuses to run. One directory per turn. */
async function listen(): Promise<Socket> {
  const dir = await mkdtemp(join(tmpdir(), "yorozu-codex-"));
  const path = join(dir, "tools.sock");
  const queue: Pending[] = [];
  let wake: (() => void) | undefined;
  let calls = 0;

  const server: Server = createServer((socket) => {
    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      const call = JSON.parse(buffer.slice(0, newline)) as BridgeCall;
      queue.push({
        // The MCP protocol carries no id we could reuse, and the loop needs one to match
        // the result to, so the pairing is ours to make.
        call: {
          id: `codex_${++calls}`,
          name: call.name,
          arguments: JSON.stringify(call.arguments ?? {}),
        },
        reply: (result) => socket.end(`${JSON.stringify({ result })}\n`),
      });
      wake?.();
    });
    socket.on("error", () => {});
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(path, resolve);
  });

  return {
    path,
    async next() {
      while (!queue.length) await new Promise<void>((resolve) => (wake = resolve));
      return queue.shift()!;
    },
    close() {
      server.close();
      void rm(dir, { recursive: true, force: true }).catch(() => {});
    },
  };
}

/** A Codex turn in flight: its event stream, its socket, and the call it is waiting on. */
interface Session {
  socket: Socket;
  events: AsyncGenerator<ThreadEvent>;
  pending?: Pending;
  /** Held across `stream` calls so neither promise of the race is ever dropped half-settled. */
  nextEvent?: Promise<{ event: IteratorResult<ThreadEvent> }>;
  nextCall?: Promise<{ incoming: Pending }>;
  close(): void;
}

export function codexCli(config: CodexCliConfig = {}): Provider {
  /** Set only between the turn's tool call and the loop coming back with its result. */
  let paused: Session | undefined;

  async function start(messages: Message[], tools: ToolDef[]): Promise<Session> {
    const socket = await listen();
    const configFile = join(dirname(socket.path), "bridge.json");
    await writeFile(configFile, JSON.stringify({ socket: socket.path, tools }));

    // The SDK resolves its own bundled binary by default; point it at the one the
    // user logged in with instead, when there is one.
    const binary = onPath(BINARY);
    const thread = new Codex({
      ...(binary ? { codexPathOverride: binary } : {}),
      ...(tools.length
        ? {
            config: {
              mcp_servers: {
                [SERVER]: {
                  command: execPath,
                  args: [BRIDGE, configFile],
                  // Auto-approved at the Codex layer because ours is the real gate: an
                  // approval Codex asks for here has nobody to ask under `approvalPolicy:
                  // "never"`, and the call fails with "requires approval" instead.
                  default_tools_approval_mode: "approve",
                },
              },
            },
          }
        : {}),
    }).startThread({
      ...(config.model ? { model: config.model } : {}),
      sandboxMode: "read-only",
      skipGitRepoCheck: true,
      // Ours is the only gate: Codex asking for its own approval would have nobody to ask.
      approvalPolicy: "never",
    });

    const system = systemOf(messages);
    const transcript = renderTranscript(messages);
    const { events } = await thread.runStreamed(
      system ? `${system}\n\n${transcript}` : transcript,
    );
    return {
      socket,
      events,
      close() {
        socket.close();
        void events.return?.(undefined).catch(() => {});
      },
    };
  }

  return {
    async auth() {
      const binary = onPath(BINARY);
      if (!binary) return { ok: false, reason: `${BINARY} is not on PATH` };
      try {
        // Prints which kind of account is in use, never the token — and prints it on
        // stderr, exiting 0 either way, so both streams count.
        const { stdout, stderr } = await runCli(binary, ["login", "status"]);
        const status = `${stdout}${stderr}`.toLowerCase();
        return status.includes("logged in") && !status.includes("not logged in")
          ? { ok: true }
          : { ok: false, reason: `${BINARY} is installed but not logged in` };
      } catch (e) {
        return { ok: false, reason: e instanceof Error ? e.message : String(e) };
      }
    },

    async *stream(messages, tools) {
      let resumed = paused;
      paused = undefined;
      if (resumed) {
        const pending = resumed.pending!;
        const result = messages.findLast(
          (m) => m.role === "tool" && m.tool_call_id === pending.call.id,
        );
        // No result for the call we stopped on means that turn was abandoned, so the Codex
        // process waiting on it should go too, and this is a fresh turn.
        if (result) {
          resumed.pending = undefined;
          pending.reply(result.content);
        } else {
          resumed.close();
          resumed = undefined;
        }
      }
      const session = resumed ?? (await start(messages, tools));

      try {
        for (;;) {
          session.nextEvent ??= session.events.next().then((event) => ({ event }));
          session.nextCall ??= session.socket.next().then((incoming) => ({ incoming }));
          const settled = await Promise.race<
            { event: IteratorResult<ThreadEvent> } | { incoming: Pending }
          >([session.nextEvent, session.nextCall]);

          if ("incoming" in settled) {
            session.nextCall = undefined;
            session.pending = settled.incoming;
            // The Codex turn stays alive, blocked on the bridge, until the loop comes back
            // with the result; `paused` is what stops the `finally` below from killing it.
            paused = session;
            yield { type: "tool_call", call: settled.incoming.call } satisfies ProviderEvent;
            yield { type: "done", reason: "tool_calls" };
            return;
          }

          session.nextEvent = undefined;
          if (settled.event.done) break;
          const event = settled.event.value;
          switch (event.type) {
            case "item.completed":
              if (event.item.type === "agent_message" && event.item.text) {
                yield { type: "text", text: event.item.text };
              }
              break;
            // Usage limits and auth failures arrive as these; throwing before the first
            // token is what lets the chain advance to the next provider.
            case "error":
              throw new Error(event.message);
            case "turn.failed":
              throw new Error(event.error.message);
            case "turn.completed":
              yield { type: "done", reason: "stop" };
              return;
          }
        }
        yield { type: "done" };
      } finally {
        if (paused !== session) session.close();
      }
    },
  };
}
