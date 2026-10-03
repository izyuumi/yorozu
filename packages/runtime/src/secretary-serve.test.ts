import { expect, test, vi } from "vitest";
import { serveSecretary } from "../dist/secretary-serve.js";

const { start } = vi.hoisted(() => ({ start: vi.fn() }));
// An older runtime lacks the capability marker and must never be started.
vi.mock("../dist/serve.js", () => ({ serve: start }));

test("an unpatched runtime is refused before service or profile startup", () => {
  expect(() => serveSecretary({ stateDir: "/unused-secretary-fixture" })).toThrow("missing its secretary decorator patch");
  expect(start).not.toHaveBeenCalled();
});
