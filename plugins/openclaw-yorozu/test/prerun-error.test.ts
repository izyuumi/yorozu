import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { test } from "node:test";
import "./genui-hooks.ts";
import { host } from "./genui-host.js";

const failure = `attachment lookup failed: ${"x".repeat(500)}`;
const stub = new URL("./genui-host.js", import.meta.url).href;
const moduleUrl = (source: string) => `data:text/javascript,${encodeURIComponent(source)}`;
const attachments = moduleUrl(`
  export * from ${JSON.stringify(stub)};
  export const uploadedFiles = async () => { throw new Error(${JSON.stringify(failure)}); };
`);
const relay = moduleUrl(`
  export * from ${JSON.stringify(stub)};
  export const activity = [];
  export const activityTurn = (convId, change) => activity.push({ convId, ...change });
`);
registerHooks({ resolve(specifier, context, next) {
  if (context.parentURL === new URL("../src/conversation.ts", import.meta.url).href) {
    if (specifier === "./attachments.js") return { url: attachments, shortCircuit: true };
    if (specifier === "./relay.js") return { url: relay, shortCircuit: true };
  }
  return next(specifier, context);
} });
const { handleMessage, liveTurn } = await import("../src/conversation.ts");
const { activity } = await import(relay);

for (const attempt of [0, 1]) {
  test(`pre-run failure reports to the app and ends failed (attempt ${attempt})`, async () => {
    host.sent.length = 0;
    activity.length = 0;
    host.run = () => assert.fail("agent must not run after attachment lookup fails");
    const warnings: string[] = [];
    const message = {
      convId: "33333333-3333-4333-8333-333333333333",
      messageId: "44444444-4444-4444-8444-444444444444",
      text: "Read this file",
      attachments: [{ id: "missing", name: "file.txt", mime: "text/plain", size: 1 }],
    };
    await assert.doesNotReject(handleMessage({
      cfg: {}, accountId: "default", agent: "main", mediaMaxBytes: 1,
      log: { warn: (line: string) => warnings.push(line) },
    } as never, message, attempt));
    assert.deepEqual(host.sent.filter((event: { kind: string }) => event.kind === "error"), [{
      kind: "error",
      data: {
        code: "run_failed", message: `Error: ${failure}`.slice(0, 500),
        convId: message.convId, messageId: message.messageId,
      },
    }]);
    assert.deepEqual(activity, [{ convId: message.convId, kind: "failed" }]);
    assert.equal(liveTurn(message.convId), undefined);
    assert.deepEqual(warnings, [`yorozu: run failed before start: Error: ${failure}`]);
  });
}
