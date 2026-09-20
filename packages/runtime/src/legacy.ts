/** Legacy provider loop, loaded only by explicit ServeOptions.provider / --direct-provider. */
import { randomUUID } from "node:crypto";
import type { YorozuEvent } from "@yorozu/shared";
import { agentsDir, installAgents, loadAgent, MAIN_AGENT } from "./agents.js";
import { TaskGrants, type AskFn, type Rule } from "./approval.js";
import { chainWithPrimary } from "./chain.js";
import { DelegationCapacity, delegateTool } from "./delegate.js";
import { defaultTools, eventPayload, runAgent, type TurnContext } from "./index.js";
import type { Provider } from "./provider.js";
import { loadProviders, modelOptions } from "./providers.js";
import { startScheduler } from "./scheduler.js";
import { listSkills, skillsDir, skillsPrompt } from "./skills.js";
import { contextFor, updateSummary } from "./summary.js";
import { listThreads, renameThread, threadEffort, threadHistory, threadModel } from "./threads.js";
import { closeBrowser } from "./tools/browser.js";
import { askUserTool, reportProgressTool, type AskUserFn, type ReportProgressFn } from "./tools/cards.js";
import { useProviderSearch } from "./tools/search.js";

/** A title is a nicety: past this the thread keeps its placeholder rather than the phone waiting. */
const TITLE_TIMEOUT_MS = 5_000;
const TITLE_SYSTEM =
  "Reply with a 3-5 word title for this conversation, no quotes, no trailing period";
/** How much of the opening exchange the titler is shown. */
const TITLE_CONTEXT_CHARS = 500;

interface LegacyOptions {
  provider: Provider;
  dir: string;
  emit(event: YorozuEvent): void;
  ask: AskFn;
  askUser: AskUserFn;
  reportProgress: ReportProgressFn;
  proposeRule(rule: Rule, approvals: number, context?: TurnContext): void;
  turn(threadId: string, text: string): Promise<void>;
  enqueue(threadId: string, text: string): Promise<void>;
  state(name: string): void;
  changed(): void;
  cleanTitle(raw: string): string;
}

export function createLegacyRunner(options: LegacyOptions) {
  const { provider, dir, emit, ask, reportProgress, proposeRule, state } = options;
  useProviderSearch(provider);
  const agents = installAgents(agentsDir(dir));
  const main = loadAgent(MAIN_AGENT, agents) ?? { name: MAIN_AGENT, prompt: "You are Yorozu, a personal assistant running on the user's Mac." };
  const system = [main.prompt, skillsPrompt(listSkills(skillsDir(dir)))].filter(Boolean).join("\n\n");
  const delegationCapacity = new DelegationCapacity();
  const scheduler = startScheduler((job) => {
    void options.enqueue(job.threadId, job.instruction).catch((error: unknown) => state(`job-error ${job.id} ${String(error)}`));
  }, { dir });

  async function run(threadId: string, signal: AbortSignal, onUpdate: (text: string) => void, onDone: (text: string) => void): Promise<void> {
    if (signal.aborted) return;
    // A thread put on a model of its own leads with it and keeps the configured chain behind
    // it, so one unreachable provider is a slower turn rather than a thread that cannot answer.
    // Resolved per turn: the picker may have been used since the last one. A spec naming a
    // provider the user has since deleted cannot be built at all — that thread falls all the
    // way back to the default chain, because an answer from the wrong model beats none.
    const spec = threadModel(threadId, dir);
    const effort = threadEffort(threadId, dir);
    let turnProvider = provider;
    if (spec) {
      try {
        turnProvider = chainWithPrimary(spec, provider, dir);
      } catch (e) {
        state(`model-error ${e instanceof Error ? e.message : String(e)}`);
      }
    }

    let reply = "";
    /**
     * What the deltas have already put on the wire. Streaming runs one delta behind on
     * purpose: the frame carrying the whole reply is the finished one, which is sent below
     * whatever happens, so sending a delta identical to it first would put the same reply on
     * the socket twice — which is exactly what a non-streaming provider did, one text event
     * and then the final, two identical agent messages for one turn.
     */
    let sent = "";
    let sentAt = 0;
    // Built per turn: `delegate` carries this turn's abort signal down to its children.
    // One per turn, shared with everything this turn delegates to, and dropped with the
    // turn: that is exactly the life "Allow for this task" promises.
    const grants = new TaskGrants();
    const tools = [
      ...defaultTools,
      // Both draw on the paired devices, so they only exist where there is somebody to draw
      // for: a turn, rather than the tool list the CLI shares.
      askUserTool(options.askUser),
      reportProgressTool(reportProgress),
      delegateTool({
        provider: turnProvider,
        tools: [...defaultTools, reportProgressTool(reportProgress)],
        main,
        emit,
        turn: options.turn,
        ask,
        grants,
        onProposal: proposeRule,
        dir: agents,
        signal,
        ...(effort ? { effort } : {}),
        capacity: delegationCapacity,
      }),
    ];
    for await (const event of runAgent({
      provider: turnProvider,
      system,
      // The rolling summary of what has scrolled out, then the recent window.
      messages: contextFor(threadId, dir, turnProvider.vision === true),
      tools,
      context: { threadId, agentId: MAIN_AGENT },
      ask,
      grants,
      onProposal: proposeRule,
      signal,
      ...(effort ? { effort } : {}),
    })) {
      if (event.type === "text") {
        // Every delta carries the whole reply, so per token it is sealed, signed and
        // redrawn in full; a long reply stutters. A frame every ~80ms reads the same.
        if (reply !== sent && Date.now() - sentAt >= 80) {
          onUpdate(reply);
          sent = reply;
          sentAt = Date.now();
        }
        reply += event.text;
      } else if (event.type === "final") {
        reply = event.text;
      } else {
        // The main agent's own tool calls and results, tagged like a specialist's so the
        // phone can draw the same trace for both. Its own id: only the reply streams.
        const payload = eventPayload(event);
        if (payload) {
          emit({ id: randomUUID(), threadId, ts: Date.now(), agentId: MAIN_AGENT, ...payload });
        }
      }
    }
    // An interrupted turn says nothing: the user already knows they stopped it.
    if (signal.aborted) return;
    // The finished reply is always logged, and always sent: unlike the deltas it carries
    // `done`, so even a reply whose text matches the last delta exactly is still news.
    onDone(reply);
    // Deliberately not awaited: titling is a second completion and must never delay a reply.
    void autoTitle(threadId).catch((e: unknown) => state(`title-error ${String(e)}`));
    // Nor is the summary: it is only ever needed by the *next* turn, and a thread that has not
    // outgrown its window does no work here at all. A failure leaves the summary as it was.
    void updateSummary(threadId, turnProvider, dir).catch((e: unknown) =>
      state(`summary-error ${String(e)}`),
    );
  }

  /**
   * Names a thread from its opening exchange, once. Only a thread whose title is still empty is
   * titled, which is also what keeps a rename the user typed: that title is not empty, so no
   * later turn overwrites it.
   */
  async function autoTitle(threadId: string): Promise<void> {
    const untitled = (): boolean =>
      listThreads(dir).find((thread) => thread.id === threadId)?.title === "";
    if (!untitled()) return;

    const history = threadHistory(threadId, dir);
    const opening = [
      history.find((m) => m.role === "user")?.content,
      history.find((m) => m.role === "assistant")?.content,
    ]
      .filter(Boolean)
      .join("\n\n")
      .slice(0, TITLE_CONTEXT_CHARS);
    if (!opening) return;

    const ask = async (): Promise<string> => {
      let text = "";
      for await (const event of provider.stream(
        [
          { role: "system", content: TITLE_SYSTEM },
          { role: "user", content: opening },
        ],
        [],
      )) {
        if (event.type === "text") text += event.text;
      }
      return text;
    };
    const title = options.cleanTitle(
      await Promise.race([
        ask(),
        new Promise<string>((resolve) => {
          setTimeout(() => resolve(""), TITLE_TIMEOUT_MS).unref?.();
        }),
      ]),
    );

    // Re-checked: a rename may have landed while the titler was thinking.
    if (!title || !untitled()) return;
    if (renameThread(threadId, title, dir)) options.changed();
  }

  return {
    run,
    models: () => modelOptions(loadProviders(dir)),
    close: async () => { scheduler.stop(); await closeBrowser(); },
  };
}
