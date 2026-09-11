import { expect, test } from "vitest";
import { roomId } from "./index.js";

test("room id normalises the public key", () => {
  expect(roomId("  ABC  ")).toBe("abc");
});
