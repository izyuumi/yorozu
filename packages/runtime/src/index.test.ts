import { expect, test } from "vitest";
import { describeEvent } from "./index.js";

test("describes an event", () => {
  expect(describeEvent({ id: "e1", threadId: "home", kind: "thought" })).toBe(
    "[home] thought",
  );
});
