import type { EventPayload, YorozuEvent } from "@yorozu/shared";
import {
  checkApproval,
  verifyApproved,
  type ActionClass,
  type ActionDetail,
  type AskFn,
  type BatchItem,
  type Rule,
  type TaskGrants,
} from "./approval.js";
import { autoAssignTool } from "./assign.js";
import type { Memory } from "./memory.js";
import { rememberTool } from "./memory.js";
import { resolveToolName, type Message, type Provider, type ToolCall, type ToolDef } from "./provider.js";
import { listScheduleTool, scheduleTool, unscheduleTool } from "./scheduler.js";
import { skillTool } from "./skills.js";
import { appleTools } from "./tools/apple.js";
import { browserTools } from "./tools/browser.js";
import { fetchTool } from "./tools/fetch.js";
import { fsListTool, fsReadTool, fsWriteTool } from "./tools/fs.js";
import { webSearchTool } from "./tools/search.js";
import {
  inputClickTool,
  inputKeyTool,
  inputTypeTool,
  screenCaptureTool,
  screenReadTool,
} from "./tools/native.js";
import { requestPermissionTool } from "./tools/permissions.js";
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
export * from "./threads.js";
export * from "./chain.js";
export * from "./catalog.js";
export * from "./assign.js";
export * from "./claude.js";
export * from "./codex.js";
export * from "./probe.js";
export * from "./providers.js";
export * from "./tools/browser.js";
export * from "./tools/shell.js";
export * from "./tools/fs.js";
export * from "./tools/native.js";
export * from "./tools/apple.js";
export * from "./tools/fetch.js";
export * from "./tools/search.js";
export * from "./tools/cards.js";

/** One line per event, as the agent loop will emit them. */
export function describeEvent(event: YorozuEvent): string {
  return `[${event.threadId}] ${event.kind}`;
}

/** Who is running the current turn. Tools that record provenance or schedule work need it. */
export interface TurnContext {
  threadId: string;
  agentId: string;
  /**
   * Set for the duration of one approved tool call: the id the approval was recorded under.
   * A tool that commits money or messages passes it to `verifyApproved` with the values it is
   * actually about to use, so an approval cannot be spent on a different transaction.
   */
  actionId?: string;
}

export interface Tool extends ToolDef {
  /**
   * Set when the tool has an effect outside the runtime. Declaring it puts every call
   * through the approval engine; leaving it off means the tool only reads.
   */
  actionClass?: ActionClass;
  /**
   * Derives what the approval card shows, from this call's arguments: the target, and as many
   * of the structured scope fields as the tool can honestly fill in. The more it fills in, the
   * narrower a rule the user can write about it.
   */
  action?(args: Record<string, unknown>): ActionDetail;
  /**
   * Set when one call acts on many things at once. The card lists exactly these items and the
   * decision covers exactly these items: adding or changing one needs a new card.
   */
  batch?(args: Record<string, unknown>): BatchItem[];
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
  ...appleTools,
  requestPermissionTool,
  fetchTool,
  webSearchTool,
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
  /** Reasoning depth requested for every model call in this turn. */
  effort?: import("./provider.js").ReasoningEffort;
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
  /**
   * This turn's "Allow for this task" grants. One object for the whole turn tree, passed down
   * to delegated agents, so a grant given to the main agent covers its specialists too — and
   * expires with the turn, because nothing keeps it afterwards.
   */
  grants?: TaskGrants;
  /** Raised when repeated approvals add up to a rule worth offering. Never applies it. */
  onProposal?(rule: Rule, approvals: number, context?: TurnContext): void;
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
  const lifetime = new AbortController();
  const signal = options.signal
    ? AbortSignal.any([options.signal, lifetime.signal])
    : lifetime.signal;
  try {
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
    let finished = false;
    for (let turn = 0; turn < (options.maxTurns ?? 10); turn++) {
      if (options.signal?.aborted) break;
      text = "";
      const calls: ToolCall[] = [];
      for await (const event of options.provider.stream(history, defs, { effort: options.effort, signal })) {
        if (options.signal?.aborted) break;
        if (event.type === "text") {
          text += event.text;
          yield event;
        } else if (event.type === "tool_call") {
          const call = { ...event.call, name: resolveToolName(event.call.name, defs) };
          calls.push(call);
          yield { ...event, call };
        }
      }

      history.push({
        role: "assistant",
        content: text,
        ...(calls.length ? { tool_calls: calls } : {}),
      });
      if (!calls.length) {
        finished = true;
        break;
      }

      /** One call, gate and all. Never throws: a thrown tool is a result the model can read. */
      const dispatch = async (call: ToolCall): Promise<string> => {
        const tool = tools.find((t) => t.name === call.name);
        if (!tool) return `error: unknown tool: ${call.name}`;
        try {
          const args = JSON.parse(call.arguments || "{}") as Record<string, unknown>;
          // The gate runs before the tool does: a refusal is what the model gets back.
          const gate = options.ask
            ? await checkApproval(tool, args, {
                ask: options.ask,
                ...(options.context ? { context: options.context } : {}),
                ...(options.grants ? { grants: options.grants } : {}),
                ...(options.onProposal ? { onProposal: options.onProposal } : {}),
              })
            : { refusal: null as string | null };
          if (gate.refusal !== null) return gate.refusal;
          const context =
            gate.actionId && options.context
              ? { ...options.context, actionId: gate.actionId }
              : options.context;
          if (gate.actionId && tool.action) {
            const stale = verifyApproved(gate.actionId, {
              ...tool.action(args),
              ...(tool.batch ? { items: tool.batch(args) } : {}),
            });
            if (stale) return stale;
          }
          return await tool.run(args, context);
        } catch (e) {
          return `error: ${e instanceof Error ? e.message : String(e)}`;
        }
      };

      // One after another, in the order the model asked. A call parked on an approval card
      // holds the rest: when Yorozu asks, everything is waiting on the answer, so nothing
      // lands while the card is being read. (Until 2026-09-18 the calls started together and
      // only the gated one waited; with approvals answerable from the lock screen the wait is
      // seconds, and a paused world is the easier one to trust.) An interrupt stops the lot
      // at the next boundary.
      for (const call of calls) {
        if (options.signal?.aborted) break;
        const result = await dispatch(call);
        if (options.signal?.aborted) break;
        yield { type: "tool_result", id: call.id, name: call.name, result };
        history.push({ role: "tool", tool_call_id: call.id, content: result });
      }
    }

    if (!finished && !options.signal?.aborted) {
      text = "I couldn't finish because the tool-call limit was reached.";
    }
    yield { type: "final", text };
  } finally {
    lifetime.abort();
  }
}
