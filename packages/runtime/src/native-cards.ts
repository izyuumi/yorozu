import { randomUUID } from "node:crypto";
import type { EventPayload, ThreadAgent, YorozuEvent } from "@yorozu/shared";
import { syncHostResult } from "./rust-sync.js";

/** SDK tools keep the existing notification policy; MCP integrations require app review. */
export const nativeQuickApprovable = (tool: string): boolean => !tool.startsWith("mcp__");
export interface NativeApprovalScope { eventId: string; turnId: string; attemptId: string }
interface PendingCard {
  threadId: string;
  kind: "approval_answer" | "question_answer";
  quick: boolean;
  settle: (answer?: string, alreadyLogged?: boolean) => void;
  unconfirmed?: () => void;
}

/** SDK prompts install no Yorozu rules, floors, task grants or proposals. */
export class NativeCards {
  private waiting = new Map<string, PendingCard>();

  constructor(private emit: (event: YorozuEvent) => void,
    private root: { dir: string; publish: (event: YorozuEvent) => void }) {}

  quickApprovable(actionId: string): boolean {
    const pending = this.waiting.get(actionId);
    return pending?.kind === "approval_answer" && pending.quick;
  }
  has(actionId: string, threadId: string): boolean {
    const pending = this.waiting.get(actionId);
    return pending?.kind === "approval_answer" && pending.threadId === threadId;
  }
  waitingThreads(): Set<string> {
    return new Set([...this.waiting.values()].map((item) => item.threadId));
  }
  answer(event: YorozuEvent): boolean {
    if (event.kind !== "question_answer") return false;
    const pending = this.waiting.get(event.data.questionId);
    if (!pending || pending.threadId !== event.threadId || pending.kind !== event.kind) return false;
    pending.settle(event.data.answer);
    return true;
  }

  /** Rust commits the original answer/status before any captured SDK promise can settle. */
  admitApproval(event: YorozuEvent): YorozuEvent | undefined {
    if (event.kind !== "approval_answer") return;
    const pending = this.waiting.get(event.data.actionId);
    const live = pending?.kind === "approval_answer" && pending.threadId === event.threadId;
    try {
      const proof = syncHostResult(this.root.dir, { op: "native_approval_decide", event, live });
      const status = proof.status as YorozuEvent | undefined;
      const events = proof.events as YorozuEvent[] | undefined;
      if (proof.stored !== true || status?.kind !== "approval_status" || status.threadId !== event.threadId ||
          status.data.requestId !== event.id || status.data.actionId !== event.data.actionId ||
          !["applied", "no-longer-needed", "expired", "rejected"].includes(status.data.status) ||
          !Array.isArray(events) || events.length < 1 || events.length > 2 ||
          events.some((saved) => saved.threadId !== event.threadId ||
            !(saved.kind === "approval_status" && saved.data.requestId === event.id && saved.data.actionId === event.data.actionId ||
              saved.kind === "approval_answer" && saved.id === event.id && saved.data.actionId === event.data.actionId)))
        throw new Error("Native permission remains unconfirmed");
      if (live && status.data.status !== "rejected") {
        // An acknowledged journal replay proves history, never another SDK execution.
        pending.settle(proof.execute === true && proof.replayed === false && status.data.status === "applied"
          ? event.data.answer : undefined, true);
      }
      for (const saved of events) this.root.publish(saved);
      return status;
    } catch {
      if (live) {
        pending.unconfirmed?.();
        pending.settle(undefined, true);
      }
      return;
    }
  }

  /** Late YOLO uses the same registered, scoped admission as a device answer. */
  approveAll(): void {
    for (const [actionId, pending] of [...this.waiting]) if (pending.kind === "approval_answer") {
      this.admitApproval({ id: randomUUID(), threadId: pending.threadId, ts: Date.now(), agentId: "main",
        kind: "approval_answer", data: { actionId, answer: "yes" } });
    }
  }
  cancelAll(threadId: string): void {
    for (const pending of [...this.waiting.values()]) if (pending.threadId === threadId) pending.settle();
  }

  async approve(threadId: string, agent: Exclude<ThreadAgent, "yorozu">, tool: string,
    input: Record<string, unknown>, signal: AbortSignal, scope: NativeApprovalScope,
    unconfirmed: () => void, bypass = false): Promise<boolean> {
    const actionId = randomUUID();
    const answer = await this.request(threadId, actionId, "approval_answer", {
      kind: "approval_card", data: { actionId, nativeAgent: agent, actionClass: tool, target: JSON.stringify(input, null, 2) },
    }, signal, nativeQuickApprovable(tool), scope, unconfirmed, bypass);
    return answer === "yes";
  }
  ask(threadId: string, agent: ThreadAgent, question: string, options: string[], signal: AbortSignal): Promise<string | undefined> {
    const questionId = randomUUID();
    return this.request(threadId, questionId, "question_answer", {
      kind: "question_card", data: { questionId, nativeAgent: agent, question, options, allowOther: true },
    }, signal);
  }

  private request(threadId: string, id: string, kind: "approval_answer" | "question_answer", payload: EventPayload,
    signal: AbortSignal, quick = false, scope?: NativeApprovalScope, unconfirmed?: () => void, bypass = false): Promise<string | undefined> {
    if (signal.aborted) return Promise.resolve(undefined);
    return new Promise((resolve, reject) => {
      const cancel = (): void => settle();
      const settle = (answer?: string, alreadyLogged = false): void => {
        if (!this.waiting.delete(id)) return;
        signal.removeEventListener("abort", cancel);
        // Cancellation is a denial, never permission to continue after an aborted signal.
        try {
          if (!alreadyLogged) this.emit({ id: randomUUID(), threadId, ts: Date.now(), agentId: "main", ...(kind === "approval_answer"
            ? { kind, data: { actionId: id, answer: answer === "yes" ? "yes" as const : "no" as const } }
            : { kind, data: { questionId: id, answer: answer ?? "Cancelled" } }) });
        } catch { /* An aborted SDK signal still receives denial when history is unavailable. */ }
        finally { resolve(answer); }
      };
      let event: YorozuEvent = { id: randomUUID(), threadId, ts: Date.now(), agentId: "main", ...payload };
      if (kind === "approval_answer") {
        try {
          const proof = syncHostResult(this.root.dir, { op: "native_approval_raise", event, scope });
          const saved = proof.event as YorozuEvent | undefined;
          if (proof.stored !== true || saved?.kind !== "approval_card" || saved.threadId !== threadId ||
              saved.data.actionId !== id || !scope || saved.data.nativeRun?.eventId !== scope.eventId ||
              saved.data.nativeRun.turnId !== scope.turnId || saved.data.nativeRun.attemptId !== scope.attemptId)
            throw new Error("Native permission remains unconfirmed");
          event = saved;
        } catch (error) { unconfirmed?.(); reject(error); return; }
      }
      this.waiting.set(id, { threadId, kind, quick, settle, unconfirmed });
      signal.addEventListener("abort", cancel, { once: true });
      if (kind === "approval_answer") {
        if (bypass) this.admitApproval({ id: randomUUID(), threadId, ts: Date.now(), agentId: "main",
          kind: "approval_answer", data: { actionId: id, answer: "yes" } });
        else this.root.publish(event);
      } else this.emit(event);
    });
  }
}
