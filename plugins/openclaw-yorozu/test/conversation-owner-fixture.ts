import assert from "node:assert/strict";
import type { Message } from "../src/envelope.ts";

export function deferred<T = void>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}
type Dispatch = {
  ctx: { MessageSid: string };
  replyOptions: { onToolStart: (tool: { toolCallId: string; name: string; phase: string }) => void };
  dispatcher: { sendFinalReply: (payload: { text: string }) => unknown };
};

// Real conversation/runtime modules; only runtime services are synthetic.
export async function ownerRuntime(source: URL) {
  const conversation = await import(new URL("conversation.ts", source).href);
  const { yorozuRuntime } = await import(new URL("runtime.ts", source).href);
  const stores = new Map<string, Map<string, unknown>>();
  const turns = new Map<string, { entered: ReturnType<typeof deferred<Dispatch>>; exit: ReturnType<typeof deferred<void>>; error?: Error }>();
  const lookups = new Map<string, () => Promise<unknown>>();
  const runtime = {
    state: { openKeyedStore({ namespace }: { namespace: string }) {
      if (!stores.has(namespace)) stores.set(namespace, new Map());
      const rows = stores.get(namespace)!;
      const lookup = async (key: string) => lookups.has(key) ? lookups.get(key)!() : rows.get(key);
      const register = async (key: string, value: unknown) => { rows.set(key, value); };
      return { lookup, get: lookup, register, set: register,
        entries: async () => [...rows].map(([key, value]) => ({ key, value })), delete: async (key: string) => rows.delete(key) };
    } },
    channel: { reply: { dispatchReplyFromConfig: async (params: Dispatch) => {
      const turn = turns.get(params.ctx.MessageSid);
      assert.ok(turn, "dispatch must use the real inbound message id");
      turn.entered.resolve(params);
      await turn.exit.promise;
      if (turn.error) throw turn.error;
      return { queuedFinal: false, counts: { tool: 0, block: 0, final: 0 } };
    } } },
  };
  yorozuRuntime.setRuntime(runtime);
  const ctx = { cfg: { agents: { list: [{ id: "main", default: true }] } }, accountId: "default", agent: "main", mediaMaxBytes: 1024, log: { warn: () => {}, info: () => {}, error: () => {}, debug: () => {} } };
  const pending = new Set<Promise<void>>();
  function launch(message: Message, attempt = 0) {
    const turn = { entered: deferred<Dispatch>(), exit: deferred<void>(), error: undefined as Error | undefined };
    turns.set(message.messageId, turn);
    const done = conversation.handleMessage(ctx, message, attempt) as Promise<void>;
    pending.add(done);
    void done.catch(() => {});
    return { ...turn, done, fail(error: Error) { turn.error = error; turn.exit.resolve(); } };
  }
  return { conversation, stores, lookups, launch, async close() {
    for (const turn of turns.values()) turn.exit.resolve();
    await Promise.allSettled(pending);
  } };
}
