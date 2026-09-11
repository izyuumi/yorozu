import { expect, test } from "vitest";
import type { YorozuEvent } from "./index.js";

test("an event carries a thread and a kind", () => {
  const event: YorozuEvent = { id: "e1", threadId: "home", kind: "message" };
  expect(event.kind).toBe("message");
});
