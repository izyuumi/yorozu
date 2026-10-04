import { expect, test, vi } from "vitest";
import { serveSecretary } from "../dist/secretary-serve.js";

const { start, ordinary, registered, unavailable, closed } = vi.hoisted(() => ({
  start: vi.fn(), ordinary: vi.fn(async () => ({ text: "ordinary history remains usable" })),
  registered: {} as Record<string, any>, unavailable: { reason: "" }, closed: vi.fn(async () => {}),
}));
vi.mock("../dist/serve.js", () => ({ secretaryRunnerDecorator: true, serve: (options: any) => {
  start();
  Object.assign(registered, options.decorateNativeRunners({ codex: { run: ordinary } }, {}));
  unavailable.reason = options.secretaryUnavailable();
  return { close: closed };
} }));
vi.mock("../dist/harness-runner.js", () => ({
  harnessConfiguration: () => ({ pluginId: "hermes" }),
  SecretaryHarness: class { constructor() { throw new Error("Invalid secretary workspace"); } },
}));

test("a refused harness can register an unavailable secretary without crashing or replacing ordinary execution", async () => {
  const sidecar = serveSecretary({ stateDir: "/unused-selected-harness-fixture" });
  expect(start).toHaveBeenCalledOnce();
  expect(registered.harness.descriptor).toMatchObject({ id: "harness", label: "Yorozu", needsFolder: true });
  expect(unavailable.reason).toBe("Harness unavailable: Invalid secretary workspace");
  expect(await registered.codex.run({ threadId: "yorozu-secretary-v1" })).toMatchObject({
    failed: true, text: unavailable.reason,
  });
  expect(ordinary).not.toHaveBeenCalled();
  expect(await registered.codex.run({ threadId: "saved-ordinary" })).toEqual({ text: "ordinary history remains usable" });
  expect(ordinary).toHaveBeenCalledOnce();
  await sidecar.close();
  expect(closed).toHaveBeenCalledOnce();
});
