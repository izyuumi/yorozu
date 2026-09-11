import type { EventPayload, YorozuEvent } from "@yorozu/shared";
import { checkApproval, type ActionClass, type AskFn } from "./approval.js";
import { autoAssignTool } from "./assign.js";
import type { Memory } from "./memory.js";
import { rememberTool } from "./memory.js";
import type { Message, Provider, ToolCall, ToolDef } from "./provider.js";
import { listScheduleTool, scheduleTool, unscheduleTool } from "./scheduler.js";
import { skillTool } from "./skills.js";
import { browserTools } from "./tools/browser.js";
import { fsListTool, fsReadTool, fsWriteTool } from "./tools/fs.js";
import {
  inputClickTool,
  inputKeyTool,
  inputTypeTool,
  screenCaptureTool,
  screenReadTool,
} from "./tools/native.js";
import { shellTool } from "./tools/shell.js";
import { readTranscriptsTool } from "./transcripts.js";

export * from "./provider.js";
export * from "./approval.js";
export * from "./frontmatter.js";
export * from "./agents.js";
export * from "./skills.js";
export * from "./delegate.js";
export * from "./memory.js";
export * from "./cron.js";
export * from "./scheduler.js";
export * from "./transcripts.js";
export * from "./chain.js";
export * from "./catalog.js";
export * from "./assign.js";
export * from "./claude.js";
export * from "./codex.js";
export * from "./probe.js";
export * from "./tools/browser.js";
export * from "./tools/shell.js";
export * from "./tools/fs.js";
export * from "./tools/native.js";

/** One line per event, as the agent loop will emit them. */
export function describeEvent(event: YorozuEvent): string {
  return `[${event.threadId}] ${event.kind}`;
}

/** Who is running the current turn. Tools that record provenance or schedule work need it. */
export interface TurnContext {
  threadId: string;
  agentId: string;
}

export interface Tool extends ToolDef {
  /**
   * Set when the tool has an effect outside the runtime. Declaring it puts every call
   * through the approval engine; leaving it off means the tool only reads.
   */
  actionClass?: ActionClass;
  /** Derives what the approval card names, from this call's arguments. */
  action?(args: Record<string, unknown>): { target: string; amount?: number };
  run(args: Record<string, unknown>, context?: TurnContext): string | Promise<string>;
}

/** Dummy tool so the loop has something to round-trip. */
export const echoTool: Tool = {
  name: "echo",
  description: "Echo the given text back to the caller.",
  parameters: {
    type: "object",
    properties: { text: { type: "string" } },
    required: ["text"],
  },
  run: ({ text }) => String(text ?? ""),
};

export const defaultTools: Tool[] = [
  echoTool,
  rememberTool,
  scheduleTool,
  unscheduleTool,
  listScheduleTool,
  readTranscriptsTool,
  shellTool,
  fsReadTool,
  fsWriteTool,
  fsListTool,
  screenReadTool,
  screenCaptureTool,
  inputClickTool,
  inputTypeTool,
  inputKeyTool,
  ...browserTools,
  skillTool,
  autoAssignTool,
];

export type AgentEvent =
  | { type: "text"; text: string }
  | { type: "tool_call"; call: ToolCall }
  | { type: "tool_result"; id: string; name: string; result: string }
  | { type: "final"; text: string };

/** Tool arguments are raw model output: a broken JSON string must not kill the event. */
export function safeArgs(json: string): Record<string, unknown> {
  try {
    const parsed: unknown = JSON.parse(json || "{}");
    return typeof parsed === "object" && parsed !== null
      ? (parsed as Record<string, unknown>)
      : { value: parsed };
  } catch {
    return { raw: json };
  }
}

/**
 * The wire payload for one loop event, or null for the ones that are no event of their own:
 * `text` deltas and `final` are the turn's single message, which the caller owns. Shared so
 * the main agent's turn and a delegated one report their tool use identically.
 */
export function eventPayload(event: AgentEvent): EventPayload | null {
  if (event.type === "tool_call") {
    return {
      kind: "tool_call",
      data: { callId: event.call.id, name: event.call.name, args: safeArgs(event.call.arguments) },
    };
  }
  if (event.type === "tool_result") {
    return {
      kind: "tool_result",
      data: { callId: event.id, ok: !event.result.startsWith("error:"), output: event.result },
    };
  }
  return null;
}

export interface RunOptions {
  provider: Provider;
  system: string;
  messages: Message[];
  tools?: Tool[];
  /** When set, facts recalled for the latest user message lead the system prompt. */
  memory?: Pick<Memory, "recallForPrompt">;
  /** Thread and agent the turn belongs to; passed to every tool call. */
  context?: TurnContext;
  /**
   * How to put an approval card in front of the user. Without it there is nobody to ask,
   * so tools carrying an `actionClass` run ungated — the CLI and the unit tests.
   */
  ask?: AskFn;
  /** Guard against a model that never stops calling tools. */
  maxTurns?: number;
  /**
   * Cancels the run: the loop stops at the next event, tool call or turn boundary, and
   * breaking out of the provider's iterator closes the underlying stream. A delegating
   * agent passes its own signal down, so one abort stops the whole tree.
   */
  signal?: AbortSignal;
}

/** Runs the model, dispatches tool calls, loops until the model stops calling. */
export async function* runAgent(
  options: RunOptions,
): AsyncGenerator<AgentEvent> {
  const tools = options.tools ?? defaultTools;
  const defs = tools.map(({ name, description, parameters }) => ({
    name,
    description,
    parameters,
  }));
  const lastUser = options.messages.findLast((m) => m.role === "user");
  const recall = lastUser
    ? (options.memory?.recallForPrompt(lastUser.content) ?? "")
    : "";
  const history: Message[] = [
    {
      role: "system",
      content: recall ? `${recall}\n\n${options.system}` : options.system,
    },
    ...options.messages,
  ];

  let text = "";
  for (let turn = 0; turn < (options.maxTurns ?? 10); turn++) {
    if (options.signal?.aborted) break;
    text = "";
    const calls: ToolCall[] = [];
    for await (const event of options.provider.stream(history, defs)) {
      if (options.signal?.aborted) break;
      if (event.type === "text") {
        text += event.text;
        yield event;
      } else if (event.type === "tool_call") {
        calls.push(event.call);
        yield event;
      }
    }

    history.push({
      role: "assistant",
      content: text,
      ...(calls.length ? { tool_calls: calls } : {}),
    });
    if (!calls.length) break;

    for (const call of calls) {
      if (options.signal?.aborted) break;
      const tool = tools.find((t) => t.name === call.name);
      let result: string;
      try {
        if (!tool) {
          result = `unknown tool: ${call.name}`;
        } else {
          const args = JSON.parse(call.arguments || "{}") as Record<string, unknown>;
          // The gate runs before the tool does: a refusal is what the model gets back.
          const refused = options.ask
            ? await checkApproval(tool, args, options.ask, options.context)
            : null;
          result = refused ?? (await tool.run(args, options.context));
        }
      } catch (e) {
        result = `error: ${e instanceof Error ? e.message : String(e)}`;
      }
      yield { type: "tool_result", id: call.id, name: call.name, result };
      history.push({ role: "tool", tool_call_id: call.id, content: result });
    }
  }

  yield { type: "final", text };
}
