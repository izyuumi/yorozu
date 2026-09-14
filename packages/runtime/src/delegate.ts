/**
 * `delegate(agent, task, background?)`: the main agent's one handle on the specialists.
 * Depth is 2 — a specialist never gets `delegate` itself, so it cannot delegate on.
 * Sync by default; `background: true` reports back later as a new turn in the same thread.
 * Every event a specialist emits carries its own `agentId` and `parentAgentId: "main"`.
 * See docs/spec-v1.html section 3.
 */

import { randomUUID } from "node:crypto";
import { join } from "node:path";
import type { EventPayload, ProgressStep, YorozuEvent } from "@yorozu/shared";
import { agentsDir, inherit, listAgents, MAIN_AGENT, type AgentConfig } from "./agents.js";
import type { AskFn, Rule, TaskGrants } from "./approval.js";
import { chainFromEnv } from "./chain.js";
import { eventPayload, runAgent, type Tool } from "./index.js";
import { memoryDir, memoryFor } from "./memory.js";
import type { Provider, ReasoningEffort } from "./provider.js";
import { currentThread } from "./threads.js";

export const DELEGATE_TOOL = "delegate";
/** Keeps one runtime from exhausting the machine with unbounded worker processes. */
export const MAX_CONCURRENT_DELEGATIONS = 4;

/** Shared by every turn in one sidecar, including turns started by background results. */
export class DelegationCapacity {
  #active = 0;

  acquire(): boolean {
    if (this.#active >= MAX_CONCURRENT_DELEGATIONS) return false;
    this.#active += 1;
    return true;
  }

  release(): void {
    this.#active -= 1;
  }
}

export interface DelegateOptions {
  /** The main agent's provider; a specialist inherits it unless it names its own model. */
  provider: Provider;
  /** The main agent's tools. The specialist gets these minus `delegate`, minus its allowlist. */
  tools: Tool[];
  /** The main agent's own config: what an absent frontmatter field inherits. */
  main: AgentConfig;
  /** Logs and forwards a specialist's event exactly as the main agent's own. */
  emit(event: YorozuEvent): void;
  /** The programmatic-turn path: how a background delegation reports its result back. */
  turn(threadId: string, text: string): Promise<void>;
  /** The main agent's approval channel: a specialist is gated exactly as its parent is. */
  ask?: AskFn;
  /**
   * The turn's bounded grants, shared with the parent: "Allow for this task" covers the whole
   * turn tree, so a specialist acts under a grant the user gave the main agent.
   */
  grants?: TaskGrants;
  /** Passed down so a specialist's repeated approvals count towards a proposal like any other. */
  onProposal?(rule: Rule, approvals: number, context?: { threadId: string; agentId: string }): void;
  /** Defaults to the state directory's agents folder. */
  dir?: string;
  /** Cancels this delegation with the rest of the tree. */
  signal?: AbortSignal;
  /** Thread-level reasoning depth inherited by specialists. */
  effort?: ReasoningEffort;
  /** Process-local worker ceiling shared across turns. */
  capacity?: DelegationCapacity;
}

/** One specialist turn, seeded with `task` as its only message. Returns its final text. */
async function runSpecialist(
  options: DelegateOptions,
  agent: AgentConfig,
  provider: Provider,
  task: string,
  threadId: string,
): Promise<string> {
  const emit = (payload: EventPayload): void =>
    options.emit({
      id: randomUUID(),
      threadId,
      ts: Date.now(),
      agentId: agent.name,
      parentAgentId: MAIN_AGENT,
      ...payload,
    });

  const tools = options.tools.filter(
    (tool) => tool.name !== DELEGATE_TOOL && (!agent.tools || agent.tools.includes(tool.name)),
  );

  let text = "";
  let reported = false;
  /** `done` is what closes the phone's inline card for this delegation. */
  const report = (): void => {
    reported = true;
    emit({ kind: "message", data: { role: "agent", text, done: true } });
  };

  try {
    for await (const event of runAgent({
      provider,
      system: agent.prompt,
      messages: [{ role: "user", content: task }],
      tools,
      memory: memoryFor(agent.memory ? join(memoryDir(), agent.memory) : memoryDir()),
      context: { threadId, agentId: agent.name },
      ...(options.ask ? { ask: options.ask } : {}),
      ...(options.grants ? { grants: options.grants } : {}),
      ...(options.onProposal ? { onProposal: options.onProposal } : {}),
      ...(options.signal ? { signal: options.signal } : {}),
      ...(options.effort ? { effort: options.effort } : {}),
    })) {
      const payload = eventPayload(event);
      if (payload) emit(payload);
      else if (event.type === "final") {
        text = event.text;
        report();
      }
    }
  } finally {
    // A specialist that threw or was cancelled must not leave the card spinning forever.
    if (!reported) report();
  }
  return text;
}

const describe = (agent: AgentConfig): string =>
  agent.description ? `${agent.name} (${agent.description})` : agent.name;

export function delegateTool(options: DelegateOptions): Tool {
  const dir = options.dir ?? agentsDir();
  const specialists = (): AgentConfig[] =>
    listAgents(dir).filter((agent) => agent.name !== MAIN_AGENT);
  const known = specialists();
  const capacity = options.capacity ?? new DelegationCapacity();

  return {
    name: DELEGATE_TOOL,
    description:
      "Hand execution to a worker agent and get its answer. Up to " +
      `${MAX_CONCURRENT_DELEGATIONS} workers run concurrently. Workers cannot delegate ` +
      `further: one needing another returns what it needs, and you re-delegate. Agents: ${
        known.map(describe).join(", ") || "none"
      }.`,
    parameters: {
      type: "object",
      properties: {
        agent: { type: "string", enum: known.map((agent) => agent.name) },
        task: { type: "string", description: "Everything the specialist needs, in full." },
        background: {
          type: "boolean",
          description:
            "Return immediately; the result arrives later as a new turn in this thread.",
        },
      },
      required: ["agent", "task"],
    },

    async run({ agent, task, background }, context) {
      const name = String(agent ?? "");
      const found = specialists().find((candidate) => candidate.name === name);
      if (!found) return `no such agent: ${name}`;
      if (!capacity.acquire()) {
        return `delegation capacity reached (${MAX_CONCURRENT_DELEGATIONS}); retry when a worker finishes`;
      }

      const config = inherit(found, options.main);
      // Resolved from the file's own field: inheriting means reusing the provider we hold.
      const provider = found.model ? chainFromEnv(found.model) : options.provider;
      const threadId = context?.threadId ?? currentThread();
      const text = String(task ?? "");
      if (!background) {
        try {
          const result = await runSpecialist(options, config, provider, text, threadId);
          return options.signal?.aborted ? `delegation to ${name} was interrupted` : result;
        } finally {
          capacity.release();
        }
      }

      const id = randomUUID();
      // Nobody is watching a background delegation finish, so it says where it has got to by
      // itself. The event id is the card id, so the state below replaces this card rather
      // than adding a second one — see `reportProgress` in serve.ts.
      const progress = (state: ProgressStep["state"]): void =>
        options.emit({
          id,
          threadId,
          ts: Date.now(),
          agentId: MAIN_AGENT,
          kind: "progress_card",
          data: {
            cardId: id,
            title: text,
            steps: [{ label: name, state }],
            ...(state === "running" ? {} : { percent: 100 }),
          },
        });
      progress("running");
      void runSpecialist(options, config, provider, text, threadId)
        // The worker slot is free before its result starts a new main-agent turn.
        .finally(() => capacity.release())
        .then((result) => {
          progress("done");
          return options.signal?.aborted
            ? undefined
            : options.turn(threadId, `delegation ${id} finished: ${result}`);
        })
        .catch((e: unknown) => {
          progress("failed");
          return options
            .turn(threadId, `delegation ${id} failed: ${e instanceof Error ? e.message : String(e)}`)
            .catch(() => {
              // Nothing left to report it to.
            });
        });
      return `delegation ${id} started: ${name} is working in the background`;
    },
  };
}
