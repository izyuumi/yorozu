/**
 * Native coding agents: a thread whose agent is `claude-code` or `codex` is one of that agent's
 * own sessions, run headless in the thread's folder with the agent's own tools. Yorozu relays
 * the prompt in and the reply out; it does not dispatch tools, classify actions or keep rules
 * for these threads. See PAIOS Projects/Yorozu, "Native agent bridge — grill decisions".
 *
 * Each agent is one `NativeAgentRunner`. The runner is given the thread's stored native session
 * id and hands back the one to store, so a later prompt resumes where the agent left off.
 */

import { query as sdkQuery, type ModelInfo, type Options, type Query, type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import type { EventPayload, ModelOption, ReasoningEffort } from "@yorozu/shared";

export interface NativeTurn {
  threadId: string;
  /** The folder the agent runs in, fixed at thread creation. The runner refuses to start without one. */
  cwd: string;
  text: string;
  /** The agent's own session id from the thread's last turn; absent starts a new session. */
  sessionId?: string;
  bypass?: boolean;
  model?: string;
  effort?: ReasoningEffort;
  signal: AbortSignal;
  /** Every delta re-sends the whole reply so far, the way the phone redraws it. */
  onUpdate?: (text: string) => void;
  /**
   * What the agent did along the way — thoughts, tool calls, results — as the trace events the
   * work row already draws. `id` is stable per thing, so a replay does not double it up.
   */
  onActivity?: (id: string, payload: EventPayload) => void;
  onSession?: (sessionId: string) => void;
  approve?: (tool: string, input: Record<string, unknown>, signal: AbortSignal) => Promise<boolean>;
  ask?: (question: string, options: string[], signal: AbortSignal) => Promise<string | undefined>;
}

/**
 * The folder a turn must run in. The type already requires it; the check is for JS callers and
 * thread records from before cwd was required, so a missing folder never becomes the sidecar's.
 */
export function turnCwd(turn: NativeTurn): string {
  const cwd = typeof turn.cwd === "string" ? turn.cwd.trim() : "";
  if (!cwd) throw new Error("a native agent turn needs a working directory");
  return cwd;
}

/** A tool result's content as one string: text blocks joined, anything else named. */
function resultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((block) => {
      const item = block as { type?: string; text?: string };
      return item.type === "text" ? item.text ?? "" : `[${item.type ?? "block"}]`;
    })
    .join("\n");
}

/**
 * What an agent child — the Claude Code CLI, the Codex app server — may inherit from Yorozu's
 * own environment. Those children run arbitrary tools in the user's folders, so they get the
 * shell basics and their own configuration only: never Yorozu's secrets (`YOROZU_*`), and never
 * keys for providers Yorozu talks to on the user's behalf (`GOOGLE_API_KEY`, `AWS_*`,
 * `GITHUB_TOKEN`, any `*_API_KEY`). Anything not named here is dropped.
 */
export const CHILD_ENV_KEYS: readonly string[] = ["PATH", "HOME", "TMPDIR", "LANG", "USER", "SHELL", "TERM"];
/** Prefixes passed through whole: locale, XDG dirs, and each agent's own vendor variables. */
export const CHILD_ENV_PREFIXES: readonly string[] = ["LC_", "XDG_", "CLAUDE_", "ANTHROPIC_", "CODEX_", "OPENAI_"];

/**
 * The explicit env an agent child is started with, built from the allowlist above. Both SDKs
 * replace the child's environment with what they are given rather than merging it, so this
 * carries PATH and HOME itself. `extra` is for what the runner sets on its own and wins.
 */
export function childEnv(source: NodeJS.ProcessEnv = process.env, extra: Record<string, string> = {}): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(source)) {
    if (value === undefined) continue;
    if (CHILD_ENV_KEYS.includes(key) || CHILD_ENV_PREFIXES.some((prefix) => key.startsWith(prefix))) env[key] = value;
  }
  return { ...env, ...extra };
}

export interface NativeTurnResult {
  /** The finished reply. Empty when the turn was aborted before it said anything. */
  text: string;
  /** The SDK reported a terminal failure rather than a completed answer. */
  failed?: boolean;
  /** The session to resume next time. Kept even for an aborted turn: the session survives it. */
  sessionId?: string;
}

export interface NativeAgentRunner {
  models?(): Promise<ModelOption[]>;
  run(turn: NativeTurn): Promise<NativeTurnResult>;
}

export type QueryFn = typeof sdkQuery;

export const claudeEffort = (effort?: ReasoningEffort): Options["effort"] =>
  effort && ["low", "medium", "high", "xhigh", "max"].includes(effort) ? effort as Options["effort"] : undefined;

function claudeModelLabel(model: ModelInfo): string {
  const family = model.displayName.match(/^[A-Za-z]+/)?.[0];
  if (!family || !model.resolvedModel) return model.displayName;
  const version = model.resolvedModel.match(new RegExp(`^claude-${family.toLowerCase()}-(\\d+)(?:-(\\d+))?`));
  return version ? model.displayName.replace(family, `${family} ${version[1]}${version[2] ? `.${version[2]}` : ""}`) : model.displayName;
}

/**
 * Claude Code through the Agent SDK. The CLI's own tools, settings and permission model apply
 * — this is a coding session, not Yorozu's loop — and `resume` carries the thread's session.
 *
 * Permission decisions and questions are relayed without Yorozu action classification.
 */
export function claudeCodeRunner(query: QueryFn = sdkQuery): NativeAgentRunner {
  return {
    async models() {
      // No prompt is submitted while asking the CLI for its own catalog.
      const session = query({ prompt: (async function* () {})(), options: { tools: [], env: childEnv() } });
      try {
        return (await session.supportedModels()).map((model) => ({
          id: model.value, label: claudeModelLabel(model), providerLabel: "Claude Code",
          efforts: model.supportedEffortLevels ?? [],
        }));
      } finally { session.close(); }
    },
    async run(turn) {
      // Refuse before anything is spawned: a turn with no folder must not run where the sidecar does.
      const cwd = turnCwd(turn);
      const abort = new AbortController();
      const onAbort = (): void => abort.abort();
      if (turn.signal.aborted) onAbort();
      else turn.signal.addEventListener("abort", onAbort, { once: true });

      const answerQuestions = async (input: Record<string, unknown>, signal: AbortSignal) => {
        const answers: Record<string, string> = {};
        if (!Array.isArray(input.questions) || !input.questions.length || signal.aborted) return;
        for (const item of input.questions) {
          if (!item || typeof item.question !== "string" || !Array.isArray(item.options)) return;
          const labels = item.options.map((option: { label?: unknown }) => option?.label)
            .filter((label: unknown): label is string => typeof label === "string");
          const answer = await turn.ask?.(item.question, labels, signal);
          if (answer === undefined || signal.aborted) return;
          answers[item.question] = answer;
        }
        return { ...input, answers };
      };

      const session = query({
        prompt: turn.text,
        options: {
          abortController: abort,
          cwd,
          // Replaces the CLI's environment: Yorozu's own secrets and other providers' keys stay here.
          env: childEnv(),
          ...(turn.sessionId ? { resume: turn.sessionId } : {}),
          ...(turn.model ? { model: turn.model } : {}),
          ...(claudeEffort(turn.effort) ? { effort: claudeEffort(turn.effort) } : {}),
          includePartialMessages: true,
          permissionMode: turn.bypass ? "bypassPermissions" : "default",
          allowDangerouslySkipPermissions: turn.bypass === true,
          hooks: { PreToolUse: [{ matcher: "AskUserQuestion", timeout: 86400, hooks: [async (input, _id, options) => {
            if (input.hook_event_name !== "PreToolUse") return {};
            if (!input.tool_input || typeof input.tool_input !== "object" || Array.isArray(input.tool_input)) return {};
            const updatedInput = await answerQuestions(input.tool_input as Record<string, unknown>, AbortSignal.any([turn.signal, options.signal]));
            return { hookSpecificOutput: { hookEventName: "PreToolUse",
              permissionDecision: updatedInput ? "allow" : "deny", ...(updatedInput ? { updatedInput } : {}) } };
          }] }] },
          canUseTool: async (toolName, input, options) => {
            const signal = AbortSignal.any([turn.signal, options.signal]);
            const deny = { behavior: "deny" as const, message: "User declined or request cancelled." };
            if (signal.aborted) return deny;
            if (toolName === "AskUserQuestion") {
              // PreToolUse already supplied answers even when permission checks are bypassed.
              if (input.answers && typeof input.answers === "object") return { behavior: "allow", updatedInput: input };
              const updatedInput = await answerQuestions(input, signal);
              return updatedInput ? { behavior: "allow", updatedInput } : deny;
            }
            if (turn.bypass) return { behavior: "allow", updatedInput: input };
            return await turn.approve?.(toolName, input, signal) && !signal.aborted
              ? { behavior: "allow", updatedInput: input }
              : deny;
          },
        },
      });

      let text = "";
      let streamed = "";
      let failed = false;
      let sessionId = turn.sessionId;
      try {
        for await (const message of session as AsyncIterable<SDKMessage>) {
          if ("session_id" in message && message.session_id && message.session_id !== sessionId) {
            sessionId = message.session_id;
            turn.onSession?.(sessionId);
          }
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
            // Subagents' own traffic stays inside their Task; the row is the main agent's.
            if (message.parent_tool_use_id) continue;
            const spoken = message.message.content
              .filter((block) => block.type === "text")
              .map((block) => block.text)
              .join("");
            if (spoken) text = spoken;
            for (const block of message.message.content) {
              if (block.type === "thinking" && block.thinking) {
                turn.onActivity?.(`${message.uuid}:thinking`, { kind: "thought", data: { text: block.thinking } });
              } else if (block.type === "tool_use") {
                const input = block.input && typeof block.input === "object" ? (block.input as Record<string, unknown>) : {};
                turn.onActivity?.(`call:${block.id}`, { kind: "tool_call", data: { callId: block.id, name: block.name, args: input } });
              }
            }
          } else if (message.type === "user") {
            if (message.parent_tool_use_id) continue;
            const content = message.message.content;
            if (!Array.isArray(content)) continue;
            for (const block of content) {
              if (block.type !== "tool_result") continue;
              turn.onActivity?.(`result:${block.tool_use_id}`, {
                kind: "tool_result",
                data: { callId: block.tool_use_id, ok: block.is_error !== true, output: resultText(block.content) },
              });
            }
          } else if (message.type === "result") {
            if (message.subtype === "success") text = message.result || text;
            else if (!turn.signal.aborted) {
              failed = true;
              text = text || `Claude Code stopped: ${message.subtype.replace(/^error_/, "").replace(/_/g, " ")}.`;
            }
          }
        }
      } catch (error) {
        // Stop is an answer of its own; anything else is the agent's failure to report.
        if (!turn.signal.aborted) throw error;
      } finally {
        turn.signal.removeEventListener("abort", onAbort);
        session.close();
      }
      return { text: turn.signal.aborted ? streamed || text : text, ...(failed ? { failed: true } : {}), ...(sessionId ? { sessionId } : {}) };
    },
  };
}
