import { randomUUID } from "node:crypto";
import type { EventPayload, ThreadAgent, YorozuEvent } from "@yorozu/shared";

/** SDK prompts have no Yorozu rules, floors, task grants or proposals. */
export class NativeCards {
  private waiting = new Map<string, { threadId: string; kind: "approval_answer" | "question_answer"; settle: (answer?: string) => void }>();

  constructor(private emit: (event: YorozuEvent) => void) {}

  quickApprovable(actionId: string): boolean {
    return this.waiting.get(actionId)?.kind === "approval_answer";
  }

  answer(event: YorozuEvent): boolean {
    if (event.kind !== "approval_answer" && event.kind !== "question_answer") return false;
    const id = event.kind === "approval_answer" ? event.data.actionId : event.data.questionId;
    const pending = this.waiting.get(id);
    if (!pending || pending.threadId !== event.threadId || pending.kind !== event.kind) return false;
    pending.settle(event.data.answer);
    return true;
  }

  async approve(threadId: string, agent: Exclude<ThreadAgent, "yorozu">, tool: string, input: Record<string, unknown>, signal: AbortSignal): Promise<boolean> {
    const actionId = randomUUID();
    const answer = await this.request(threadId, actionId, "approval_answer", {
      kind: "approval_card", data: { actionId, nativeAgent: agent, actionClass: tool, target: JSON.stringify(input, null, 2) },
    }, signal);
    return answer === "yes";
  }

  ask(threadId: string, question: string, options: string[], signal: AbortSignal): Promise<string | undefined> {
    const questionId = randomUUID();
    return this.request(threadId, questionId, "question_answer", {
      kind: "question_card", data: { questionId, question, options, allowOther: true },
    }, signal);
  }

  private request(threadId: string, id: string, kind: "approval_answer" | "question_answer", payload: EventPayload, signal: AbortSignal): Promise<string | undefined> {
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
      this.waiting.set(id, { threadId, kind, settle });
      signal.addEventListener("abort", cancel, { once: true });
      this.emit({ id: randomUUID(), threadId, ts: Date.now(), agentId: "main", ...payload });
    });
  }
}
