import { randomUUID } from "node:crypto";
import type { EventPayload, ThreadAgent, YorozuEvent } from "@yorozu/shared";

/**
 * Whether a native agent's tool may be allowed from a lock-screen button. The agent's own tools
 * run in the thread's folder as the user — a command, an edit, a read — and are the local,
 * uncommitted kind an approval-card `quickApprovable` also passes. An MCP tool is someone
 * else's integration: the runtime cannot tell a search from a payment by its name, so it is
 * reviewed in the app, whatever buttons a push happened to draw.
 */
export const nativeQuickApprovable = (tool: string): boolean => !tool.startsWith("mcp__");

/** SDK prompts have no Yorozu rules, floors, task grants or proposals. */
export class NativeCards {
  private waiting = new Map<string, { threadId: string; kind: "approval_answer" | "question_answer"; quick: boolean; settle: (answer?: string) => void }>();

  constructor(private emit: (event: YorozuEvent) => void) {}

  /** Whether a waiting approval card was judged answerable from a notification when raised. */
  quickApprovable(actionId: string): boolean {
    const pending = this.waiting.get(actionId);
    return pending?.kind === "approval_answer" && pending.quick;
  }

  answer(event: YorozuEvent): boolean {
    if (event.kind !== "approval_answer" && event.kind !== "question_answer") return false;
    const id = event.kind === "approval_answer" ? event.data.actionId : event.data.questionId;
    const pending = this.waiting.get(id);
    if (!pending || pending.threadId !== event.threadId || pending.kind !== event.kind) return false;
    pending.settle(event.data.answer);
    return true;
  }

  /** Allows every waiting approval card: YOLO was switched on while they waited. */
  approveAll(): void {
    for (const pending of [...this.waiting.values()]) if (pending.kind === "approval_answer") pending.settle("yes");
  }

  async approve(threadId: string, agent: Exclude<ThreadAgent, "yorozu">, tool: string, input: Record<string, unknown>, signal: AbortSignal): Promise<boolean> {
    const actionId = randomUUID();
    const answer = await this.request(threadId, actionId, "approval_answer", {
      kind: "approval_card", data: { actionId, nativeAgent: agent, actionClass: tool, target: JSON.stringify(input, null, 2) },
    }, signal, nativeQuickApprovable(tool));
    return answer === "yes";
  }

  ask(threadId: string, question: string, options: string[], signal: AbortSignal): Promise<string | undefined> {
    const questionId = randomUUID();
    return this.request(threadId, questionId, "question_answer", {
      kind: "question_card", data: { questionId, question, options, allowOther: true },
    }, signal);
  }

  private request(threadId: string, id: string, kind: "approval_answer" | "question_answer", payload: EventPayload, signal: AbortSignal, quick = false): Promise<string | undefined> {
    if (signal.aborted) return Promise.resolve(undefined);
    return new Promise((resolve) => {
      const cancel = (): void => settle();
      const settle = (answer?: string): void => {
        if (!this.waiting.delete(id)) return;
        signal.removeEventListener("abort", cancel);
        // Echo decisions, including cancellation, so every device retires the card.
        this.emit({ id: randomUUID(), threadId, ts: Date.now(), agentId: "main", ...(kind === "approval_answer"
          ? { kind, data: { actionId: id, answer: answer === "yes" ? "yes" as const : "no" as const } }
          : { kind, data: { questionId: id, answer: answer ?? "Cancelled" } }) });
        resolve(answer);
      };
      this.waiting.set(id, { threadId, kind, quick, settle });
      signal.addEventListener("abort", cancel, { once: true });
      this.emit({ id: randomUUID(), threadId, ts: Date.now(), agentId: "main", ...payload });
    });
  }
}
