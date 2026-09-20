/**
 * The two tools that draw a card instead of returning a string the user never sees:
 * `ask_user` puts a choice in front of them and waits for it, `report_progress` shows a long
 * job moving. Both need a way out to the paired devices, so they are built per turn in
 * serve.ts the way `delegate` is, rather than sitting in `defaultTools` where the CLI — which
 * has nobody to ask and nowhere to draw — would pick them up.
 */

import { randomUUID } from "node:crypto";
import type { ProgressCardData, ProgressStep, QuestionCardData } from "@yorozu/shared";
import type { Tool, TurnContext } from "../index.js";

export const ASK_USER_TOOL = "ask_user";
export const REPORT_PROGRESS_TOOL = "report_progress";

/** An unanswered question is not a hung turn: it expires, and the agent is told so. */
export const QUESTION_TIMEOUT_MS = 10 * 60_000;
/** What `ask_user` returns when the card expired. Plain words: the model reads this. */
export const NO_ANSWER = "no answer";

/** Raises a question card and resolves with the answer text, or with "no answer" if it expires. */
export type AskUserFn = (
  question: string,
  options: string[],
  allowOther: boolean,
  context?: TurnContext,
) => Promise<string>;

/** Puts a progress card on screen, or replaces the one already there under this `cardId`. */
export type ReportProgressFn = (card: ProgressCardData, context?: TurnContext) => void;

/** The questions on screen somewhere, waiting to be answered. */
export interface QuestionDesk {
  /** What `ask_user` is built on: raises a card and blocks until it is answered or expires. */
  ask: AskUserFn;
  /** The user answered. Unknown ids are a no-op: a card answered twice, or after it expired. */
  answer(questionId: string, answer: string): void;
  /** Everything still waiting gives up, so an interrupt does not leave a turn parked on a card. */
  cancelAll(threadId?: string): void;
}

/**
 * Keeps track of the questions asked and matches answers back to the tool calls that are
 * suspended on them. Separate from the socket so the waiting, and its expiry, can be tested
 * without a sidecar and without waiting ten minutes.
 */
export function questionDesk(
  raise: (card: QuestionCardData, context?: TurnContext) => void,
  timeoutMs = QUESTION_TIMEOUT_MS,
): QuestionDesk {
  const waiting = new Map<string, (answer: string) => void>();
  const threads = new Map<string, string | undefined>();
  return {
    ask: (question, options, allowOther, context) => {
      const questionId = randomUUID();
      threads.set(questionId, context?.threadId);
      return new Promise<string>((resolve) => {
        const timer = setTimeout(() => {
          waiting.delete(questionId);
          threads.delete(questionId);
          resolve(NO_ANSWER);
        }, timeoutMs);
        timer.unref?.();
        waiting.set(questionId, (answer) => {
          clearTimeout(timer);
          waiting.delete(questionId);
          threads.delete(questionId);
          resolve(answer);
        });
        raise(
          { questionId, question, options, ...(allowOther ? { allowOther: true } : {}) },
          context,
        );
      });
    },
    answer: (questionId, answer) => waiting.get(questionId)?.(answer),
    cancelAll: (threadId) => {
      for (const [id, settle] of [...waiting]) if (!threadId || threads.get(id) === threadId) settle(NO_ANSWER);
    },
  };
}

const strings = (value: unknown): string[] =>
  Array.isArray(value) ? value.map((entry) => String(entry)).filter((entry) => entry !== "") : [];

export function askUserTool(ask: AskUserFn): Tool {
  return {
    name: ASK_USER_TOOL,
    description:
      "Ask the user to choose between options. They get a card with the options as buttons " +
      "and the answer comes back as this call's result. Use it whenever a choice is yours to " +
      "put and theirs to make, rather than asking in prose and hoping they reply.",
    parameters: {
      type: "object",
      properties: {
        question: { type: "string", description: "One line, as you would say it out loud." },
        options: {
          type: "array",
          items: { type: "string" },
          description: "The choices, shortest first. Two to five reads best.",
        },
        allowOther: {
          type: "boolean",
          description: "Also offer a free-text field, for answers the options do not cover.",
        },
      },
      required: ["question", "options"],
    },
    run: (args, context) =>
      ask(
        String(args.question ?? ""),
        strings(args.options),
        args.allowOther === true,
        context,
      ),
  };
}

/** The step states the card knows how to draw; anything else from the model is a pending step. */
const STATES: ReadonlySet<ProgressStep["state"]> = new Set<ProgressStep["state"]>([
  "pending",
  "running",
  "done",
  "failed",
]);

/** Model output, so every field is checked: a card that cannot be drawn is worse than none. */
export function progressCard(args: Record<string, unknown>): ProgressCardData {
  const steps = (Array.isArray(args.steps) ? args.steps : []).map((entry): ProgressStep => {
    const step = (typeof entry === "object" && entry !== null ? entry : {}) as Record<string, unknown>;
    const state = String(step.state ?? "") as ProgressStep["state"];
    return {
      label: String(step.label ?? ""),
      state: STATES.has(state) ? state : "pending",
    };
  });
  const percent = Number(args.percent);
  return {
    cardId: String(args.cardId ?? ""),
    title: String(args.title ?? ""),
    steps,
    ...(Number.isFinite(percent) ? { percent: Math.min(100, Math.max(0, percent)) } : {}),
  };
}

export function reportProgressTool(report: ReportProgressFn): Tool {
  return {
    name: REPORT_PROGRESS_TOOL,
    description:
      "Show the user where a long job has got to. Call it again with the same cardId to move " +
      "the same card along rather than stacking up new ones.",
    parameters: {
      type: "object",
      properties: {
        cardId: {
          type: "string",
          description: "Your own id for this job. Reuse it to update the card you already showed.",
        },
        title: { type: "string", description: "What the job is, in a few words." },
        steps: {
          type: "array",
          description: "The plan, in order, each with its state.",
          items: {
            type: "object",
            properties: {
              label: { type: "string" },
              state: { type: "string", enum: ["pending", "running", "done", "failed"] },
            },
            required: ["label", "state"],
          },
        },
        percent: { type: "number", description: "0–100, when the job can say." },
      },
      required: ["cardId", "title", "steps"],
    },
    run: (args, context) => {
      const card = progressCard(args);
      if (!card.cardId) return "error: report_progress needs a cardId";
      report(card, context);
      const done = card.steps.filter((step) => step.state === "done").length;
      return `showed "${card.title}" (${done}/${card.steps.length} steps done)`;
    },
  };
}
