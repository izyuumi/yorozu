/**
 * Codex through the installed `codex` binary and its subscription login.
 *
 * The Codex SDK exposes no custom-tool mechanism — Codex brings its own tools and runs
 * them itself — so this adapter streams text and ignores `tools`. Put a tool-capable
 * provider behind it in the chain when the loop needs tools. See docs/spec-v1.html
 * section 2.
 */

import { Codex } from "@openai/codex-sdk";
import {
  onPath,
  renderTranscript,
  runCli,
  systemOf,
  type Provider,
} from "./provider.js";

const BINARY = "codex";

export interface CodexCliConfig {
  /** Empty means whatever the CLI is already configured to use. */
  model?: string;
}

export function codexCli(config: CodexCliConfig = {}): Provider {
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

    async *stream(messages) {
      // The SDK resolves its own bundled binary by default; point it at the one the
      // user logged in with instead, when there is one.
      const binary = onPath(BINARY);
      const thread = new Codex(binary ? { codexPathOverride: binary } : {}).startThread({
        ...(config.model ? { model: config.model } : {}),
        sandboxMode: "read-only",
        skipGitRepoCheck: true,
      });

      const system = systemOf(messages);
      const transcript = renderTranscript(messages);
      const { events } = await thread.runStreamed(
        system ? `${system}\n\n${transcript}` : transcript,
      );

      for await (const event of events) {
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
    },
  };
}
