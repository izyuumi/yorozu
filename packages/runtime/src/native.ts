/**
 * Native coding agents: a thread whose agent is `claude-code` or `codex` is one of that agent's
 * own sessions, run headless in the thread's folder with the agent's own tools. Yorozu relays
 * the prompt in and the reply out; it does not dispatch tools, classify actions or keep rules
 * for these threads. See PAIOS Projects/Yorozu, "Native agent bridge — grill decisions".
 *
 * Each agent is one `NativeAgentRunner`. The runner is given the thread's stored native session
 * id and hands back the one to store, so a later prompt resumes where the agent left off.
 */

import { query as sdkQuery, type Options, type Query, type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import type { ReasoningEffort } from "@yorozu/shared";

export interface NativeTurn {
  threadId: string;
  /** The folder the agent runs in, fixed at thread creation. Absent runs where the sidecar does. */
  cwd?: string;
  text: string;
  /** The agent's own session id from the thread's last turn; absent starts a new session. */
  sessionId?: string;
  model?: string;
  effort?: ReasoningEffort;
  signal: AbortSignal;
  /** Every delta re-sends the whole reply so far, the way the phone redraws it. */
  onUpdate?: (text: string) => void;
}

export interface NativeTurnResult {
  /** The finished reply. Empty when the turn was aborted before it said anything. */
  text: string;
  /** The session to resume next time. Kept even for an aborted turn: the session survives it. */
  sessionId?: string;
}

export interface NativeAgentRunner {
  run(turn: NativeTurn): Promise<NativeTurnResult>;
}

export type QueryFn = (params: { prompt: string; options?: Options }) => Query;

/**
 * Claude Code through the Agent SDK. The CLI's own tools, settings and permission model apply
 * — this is a coding session, not Yorozu's loop — and `resume` carries the thread's session.
 *
 * Permission prompts are not passed through yet: a tool the CLI would ask about is refused,
 * and the reply says so. That passthrough is its own change.
 */
export function claudeCodeRunner(query: QueryFn = sdkQuery): NativeAgentRunner {
  return {
    async run(turn) {
      const abort = new AbortController();
      const onAbort = (): void => abort.abort();
      if (turn.signal.aborted) onAbort();
      else turn.signal.addEventListener("abort", onAbort, { once: true });

      const session = query({
        prompt: turn.text,
        options: {
          abortController: abort,
          ...(turn.cwd ? { cwd: turn.cwd } : {}),
          ...(turn.sessionId ? { resume: turn.sessionId } : {}),
          ...(turn.model ? { model: turn.model } : {}),
          ...(turn.effort ? { effort: turn.effort } : {}),
          includePartialMessages: true,
          canUseTool: async (toolName) => ({
            behavior: "deny",
            message: `Yorozu cannot yet relay a permission prompt for ${toolName}; approvals passthrough is a later change.`,
          }),
        },
      });

      let text = "";
      let streamed = "";
      let sessionId = turn.sessionId;
      try {
        for await (const message of session as AsyncIterable<SDKMessage>) {
          if ("session_id" in message && message.session_id) sessionId = message.session_id;
          if (message.type === "stream_event") {
            const event = message.event;
            if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
              streamed += event.delta.text;
              turn.onUpdate?.(streamed);
            } else if (event.type === "message_start") {
              // Each API message is one block of the reply; only the last one is the answer.
              streamed = "";
            }
          } else if (message.type === "assistant") {
            const spoken = message.message.content
              .filter((block) => block.type === "text")
              .map((block) => block.text)
              .join("");
            if (spoken) text = spoken;
          } else if (message.type === "result") {
            if (message.subtype === "success") text = message.result || text;
            else if (!turn.signal.aborted) text = text || `Claude Code stopped: ${message.subtype.replace(/^error_/, "").replace(/_/g, " ")}.`;
          }
        }
      } catch (error) {
        // Stop is an answer of its own; anything else is the agent's failure to report.
        if (!turn.signal.aborted) throw error;
      } finally {
        turn.signal.removeEventListener("abort", onAbort);
        session.close();
      }
      return { text: turn.signal.aborted ? "" : text, ...(sessionId ? { sessionId } : {}) };
    },
  };
}
