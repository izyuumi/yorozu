import type { QuestionCardData } from "@yorozu/shared";
import { expect, test } from "vitest";
import {
  askUserTool,
  NO_ANSWER,
  progressCard,
  questionDesk,
  reportProgressTool,
} from "./cards.js";

/** A desk that hands back the card it raised, which is what the tool call is waiting on. */
function desk(timeoutMs?: number) {
  const raised: QuestionCardData[] = [];
  const questions = questionDesk((card) => raised.push(card), timeoutMs);
  return { raised, questions, tool: askUserTool(questions.ask) };
}

test("ask_user raises a card and the answer is what the tool call returns", async () => {
  const { raised, questions, tool } = desk();
  const call = tool.run(
    { question: "Which one?", options: ["the blue one", "the red one"], allowOther: true },
    { threadId: "t1", agentId: "main" },
  );

  // The card is up before the answer: the tool call is suspended on it, not polling for it.
  expect(raised).toHaveLength(1);
  expect(raised[0]).toMatchObject({
    question: "Which one?",
    options: ["the blue one", "the red one"],
    allowOther: true,
  });

  questions.answer(raised[0].questionId, "the red one");
  expect(await call).toBe("the red one");

  // Answering again is a card tapped twice, not an error.
  questions.answer(raised[0].questionId, "the blue one");
  questions.answer("never-asked", "hello");
});

/** `allowOther` is absent rather than false when the card offers no free-text field. */
test("a card that offers only its options says nothing about free text", () => {
  const { raised, tool } = desk();
  void tool.run({ question: "Tea or coffee?", options: ["tea", "coffee"] });
  expect(raised[0].allowOther).toBeUndefined();
  expect("allowOther" in raised[0]).toBe(false);
});

test("a question nobody answers expires rather than parking the turn forever", async () => {
  const { tool } = desk(10);
  expect(await tool.run({ question: "Which one?", options: ["a", "b"] })).toBe(NO_ANSWER);
});

test("an interrupt releases every question still on screen", async () => {
  const { questions, tool } = desk();
  const first = tool.run({ question: "Which one?", options: ["a"] });
  const second = tool.run({ question: "And this?", options: ["b"] });
  questions.cancelAll();
  expect(await Promise.all([first, second])).toEqual([NO_ANSWER, NO_ANSWER]);
});

test("report_progress shows a card and re-reports it under the same card id", () => {
  const shown: ReturnType<typeof progressCard>[] = [];
  const tool = reportProgressTool((card) => shown.push(card));

  const args = {
    cardId: "job-1",
    title: "Booking the table",
    steps: [
      { label: "find a restaurant", state: "done" },
      { label: "call them", state: "running" },
    ],
    percent: 50,
  };
  expect(tool.run(args)).toBe('showed "Booking the table" (1/2 steps done)');
  tool.run({ ...args, steps: args.steps.map((step) => ({ ...step, state: "done" })), percent: 100 });

  // Two reports, one card: the id is what the client replaces on, so the card moves in place.
  expect(shown.map((card) => card.cardId)).toEqual(["job-1", "job-1"]);
  expect(shown[1].steps.every((step) => step.state === "done")).toBe(true);
  expect(shown[1].percent).toBe(100);
});

/** Without a card id there is nothing to update in place, so it is the one hard requirement. */
test("report_progress refuses a card it could never move", () => {
  const shown: unknown[] = [];
  const tool = reportProgressTool((card) => shown.push(card));
  expect(tool.run({ title: "Nowhere", steps: [] })).toMatch(/^error:/);
  expect(shown).toEqual([]);
});

test("a progress card from the model is normalised before anyone tries to draw it", () => {
  // Every field is model output: a state nobody has heard of is a step not started yet, and a
  // percent out of range is clamped rather than drawn as a bar running off the card.
  expect(
    progressCard({
      cardId: "job-1",
      title: "Tidying",
      steps: [{ label: "sweep", state: "in-progress" }, "nonsense", { state: "done" }],
      percent: 140,
    }),
  ).toEqual({
    cardId: "job-1",
    title: "Tidying",
    steps: [
      { label: "sweep", state: "pending" },
      { label: "", state: "pending" },
      { label: "", state: "done" },
    ],
    percent: 100,
  });

  // A job that cannot say how far along it is says nothing, rather than claiming zero.
  expect(progressCard({ cardId: "job-2", title: "Thinking", steps: [] }).percent).toBeUndefined();
  expect(progressCard({ cardId: "job-2", title: "Thinking", steps: [], percent: -5 }).percent).toBe(0);
});
