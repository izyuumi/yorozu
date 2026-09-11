import type { YorozuEvent } from "@yorozu/shared";
import type { Memory } from "./memory.js";
import { rememberTool } from "./memory.js";
import type { Message, Provider, ToolCall, ToolDef } from "./provider.js";
import { listScheduleTool, scheduleTool, unscheduleTool } from "./scheduler.js";
import { browserTools } from "./tools/browser.js";
import { readTranscriptsTool } from "./transcripts.js";

export * from "./provider.js";
export * from "./memory.js";
export * from "./cron.js";
export * from "./scheduler.js";
export * from "./transcripts.js";
export * from "./chain.js";
export * from "./claude.js";
export * from "./codex.js";
export * from "./probe.js";
export * from "./tools/browser.js";

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
  ...browserTools,
];

export type AgentEvent =
  | { type: "text"; text: string }
  | { type: "tool_call"; call: ToolCall }
  | { type: "tool_result"; id: string; name: string; result: string }
  | { type: "final"; text: string };

export interface RunOptions {
  provider: Provider;
  system: string;
  messages: Message[];
  tools?: Tool[];
  /** When set, facts recalled for the latest user message lead the system prompt. */
  memory?: Pick<Memory, "recallForPrompt">;
  /** Thread and agent the turn belongs to; passed to every tool call. */
  context?: TurnContext;
  /** Guard against a model that never stops calling tools. */
  maxTurns?: number;
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
    text = "";
    const calls: ToolCall[] = [];
    for await (const event of options.provider.stream(history, defs)) {
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
      const tool = tools.find((t) => t.name === call.name);
      let result: string;
      try {
        result = tool
          ? await tool.run(JSON.parse(call.arguments || "{}"), options.context)
          : `unknown tool: ${call.name}`;
      } catch (e) {
        result = `error: ${e instanceof Error ? e.message : String(e)}`;
      }
      yield { type: "tool_result", id: call.id, name: call.name, result };
      history.push({ role: "tool", tool_call_id: call.id, content: result });
    }
  }

  yield { type: "final", text };
}
