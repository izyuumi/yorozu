import type { QuestionCardData } from "@yorozu/shared";
import { expect, test } from "vitest";
import { defaultTools } from "../index.js";
import {
  ASK_USER_TOOL,
  askUserTool,
  NO_ANSWER,
  progressCard,
  questionDesk,
  REPORT_PROGRESS_TOOL,
  reportProgressTool,
} from "./cards.js";

/** A desk that hands back the card it raised, which is what the tool call is waiting on. */
function desk(timeoutMs?: number) {
  const raised: QuestionCardData[] = [];
  const retired: Array<{ questionId: string; reason: "expired" | "cancelled" }> = [];
  const questions = questionDesk((card) => raised.push(card), timeoutMs,
    (questionId, _threadId, reason) => retired.push({ questionId, reason }));
  return { raised, retired, questions, tool: askUserTool(questions.ask) };
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
  const { raised, retired, tool } = desk(10);
  expect(await tool.run({ question: "Which one?", options: ["a", "b"] })).toBe(NO_ANSWER);
  expect(retired).toEqual([{ questionId: raised[0].questionId, reason: "expired" }]);
});

test("an interrupt releases every question still on screen", async () => {
  const { raised, retired, questions, tool } = desk();
  const first = tool.run({ question: "Which one?", options: ["a"] });
  const second = tool.run({ question: "And this?", options: ["b"] });
  questions.cancelAll();
  expect(await Promise.all([first, second])).toEqual([NO_ANSWER, NO_ANSWER]);
  expect(retired).toEqual(raised.map((card) => ({ questionId: card.questionId, reason: "cancelled" })));
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

test("options the model got wrong are cleaned up before the card is drawn", () => {
  const { raised, tool } = desk();

  void tool.run({ question: "Which?", options: ["keep", "", 7, null, "also keep"] });
  // A blank is not a button anyone could read; anything else becomes its own text.
  expect(raised[0].options).toEqual(["keep", "7", "null", "also keep"]);

  // Options that are not a list at all are no options: `allowOther` is what makes it answerable.
  void tool.run({ question: "Say anything", options: "surprise me", allowOther: true });
  expect(raised[1]).toMatchObject({ question: "Say anything", options: [], allowOther: true });
});

test("an answer arriving after the question expired is dropped, not thrown", async () => {
  const { raised, questions, tool } = desk(10);
  expect(await tool.run({ question: "Which?", options: ["a"] })).toBe(NO_ANSWER);

  // The card is still on the user's screen: tapping it now must not throw or resolve twice.
  questions.answer(raised[0].questionId, "a");
  questions.cancelAll();
});

test("report_progress counts only the steps actually finished", () => {
  const shown: ReturnType<typeof progressCard>[] = [];
  const tool = reportProgressTool((card) => shown.push(card));

  expect(
    tool.run({
      cardId: "job-1",
      title: "Tidying 🧹",
      steps: [
        { label: "one", state: "done" },
        { label: "two", state: "failed" },
        { label: "three", state: "running" },
      ],
    }),
  ).toBe('showed "Tidying 🧹" (1/3 steps done)');

  // Steps that are not a list are no steps, rather than a card nobody can draw.
  expect(tool.run({ cardId: "job-1", title: "Empty", steps: "soon" })).toBe(
    'showed "Empty" (0/0 steps done)',
  );
  expect(shown[1]!.steps).toEqual([]);
});

test("both card tools name themselves and what they cannot work without", () => {
  const ask = askUserTool(async () => "x");
  const report = reportProgressTool(() => {});

  expect(ask.name).toBe(ASK_USER_TOOL);
  expect(report.name).toBe(REPORT_PROGRESS_TOOL);
  expect(ask.parameters).toMatchObject({ type: "object", required: ["question", "options"] });
  expect(report.parameters).toMatchObject({
    type: "object",
    required: ["cardId", "title", "steps"],
  });
});

test("the card tools are built per turn, not shared, and a call by name reaches them", async () => {
  // Both draw on a paired device, so the list the CLI shares must not carry them.
  const shared = defaultTools.map((tool) => tool.name);
  expect(shared).not.toContain(ASK_USER_TOOL);
  expect(shared).not.toContain(REPORT_PROGRESS_TOOL);

  // A turn's registry is that shared list plus these two, as serve.ts builds it.
  const { raised, questions } = desk();
  const shown: ReturnType<typeof progressCard>[] = [];
  const tools = [
    ...defaultTools,
    askUserTool(questions.ask),
    reportProgressTool((card) => shown.push(card)),
  ];

  const progress = tools.find((tool) => tool.name === REPORT_PROGRESS_TOOL)!;
  expect(progress.run({ cardId: "job-1", title: "Going", steps: [] })).toMatch(/^showed "Going"/);
  expect(shown).toHaveLength(1);

  const question = tools.find((tool) => tool.name === ASK_USER_TOOL)!;
  const call = question.run({ question: "Which?", options: ["a"] });
  questions.answer(raised[0].questionId, "a");
  expect(await call).toBe("a");
});
