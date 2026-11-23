import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { test } from "node:test";
import { setImmediate } from "node:timers/promises";
import "./genui-hooks.ts";
import { host } from "./genui-host.js";

const retry = new URL("../src/retry.ts", import.meta.url).href;
registerHooks({ resolve: (specifier, context, next) => (specifier === retry ? { url: retry, shortCircuit: true } : next(specifier, context)) });
const { park, runParked } = await import(retry) as typeof import("../src/retry.ts");

const settle = async () => {
  for (let i = 0; i < 20; i++) await setImmediate();
};

test("runParked runs a due row once and skips it when another tick took it", async (t) => {
  t.mock.timers.enable({ apis: ["setInterval", "Date"] });
  t.after(() => { host.delete = undefined; });
  const cases = [
    ["due", undefined, ["due"]],
    ["taken", async (_namespace: string, key: string) => { host.stores.get("retry")?.delete(key); }, []],
  ] as const;
  for (const [messageId, onDelete, expected] of cases) {
    const controller = new AbortController();
    const ran: string[] = [];
    runParked(controller.signal, (message) => ran.push(message.messageId));
    await park({ convId: "conv", messageId, text: "Parked" }, 0);
    host.delete = onDelete;
    t.mock.timers.tick(5_000);
    await settle();
    controller.abort();
    assert.deepEqual(ran, expected, messageId);
    assert.equal(host.stores.get("retry")?.has(messageId), false, messageId);
  }
});

test("an aborted tick leaves the rows it won't run and the replacement tick runs each due row exactly once", async (t) => {
  t.mock.timers.enable({ apis: ["setInterval", "Date"] });
  t.after(() => { host.delete = undefined; host.entries = undefined; });
  for (const [label, abortAt] of [["before any delete", "entries"], ["during the first delete", "delete"]] as const) {
    host.stores.get("retry")?.clear();
    const old = new AbortController();
    const ran: string[] = [];
    const ids = [`${label}-a`, `${label}-b`];
    runParked(old.signal, (message) => ran.push(message.messageId));
    for (const messageId of ids) await park({ convId: "conv", messageId, text: "Parked" }, 0);
    const parked = ids.map((id) => host.stores.get("retry")?.get(id));
    const abort = async () => {
      old.abort();
      host.entries = undefined;
      host.delete = undefined;
    };
    if (abortAt === "entries") host.entries = abort;
    else host.delete = abort;
    t.mock.timers.tick(5_000);
    await settle();
    assert.equal(old.signal.aborted, true, label);
    assert.deepEqual(ran, [], label);
    assert.deepEqual(ids.filter((id) => host.stores.get("retry")?.has(id)), ids, label);
    assert.deepEqual(ids.map((id) => host.stores.get("retry")?.get(id)), parked, label);
    const replacement = new AbortController();
    runParked(replacement.signal, (message) => ran.push(message.messageId));
    t.mock.timers.tick(5_000);
    await settle();
    replacement.abort();
    assert.deepEqual([...ran].sort(), ids, label);
    assert.deepEqual(ids.filter((id) => host.stores.get("retry")?.has(id)), [], label);
  }
});

test("park removes its row and reports not parked when the turn ended during the write", async (t) => {
  t.after(() => { host.register = undefined; });
  let live = true;
  host.register = async (namespace: string) => {
    if (namespace === "retry") live = false;
  };
  const parked = await park({ convId: "conv", messageId: "ended-while-parking", text: "Parked" }, 0, () => live);
  assert.equal(parked, false);
  assert.equal(host.stores.get("retry")?.has("ended-while-parking"), false);
});
