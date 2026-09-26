/**
 * Native Codex client over the official App Server protocol. The installed TS exec SDK is
 * one-way and has no approval/question callbacks; App Server is the documented client API.
 * Schema: `codex app-server generate-ts`; https://learn.chatgpt.com/docs/app-server.
 */
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { REASONING_EFFORTS, type ModelOption } from "@yorozu/shared";
import { childEnv, turnCwd } from "./native.js";
import type { NativeAgentRunner, NativeTurn } from "./native.js";

type ObjectValue = Record<string, unknown>;
const object = (value: unknown): ObjectValue => value !== null && typeof value === "object" && !Array.isArray(value) ? value as ObjectValue : {};
const string = (value: unknown): string => typeof value === "string" ? value : "";
const array = (value: unknown): unknown[] => Array.isArray(value) ? value : [];

export interface CodexHandlers {
  notify(method: string, params: ObjectValue): void;
  request(method: string, params: ObjectValue, signal?: AbortSignal): Promise<ObjectValue>;
  ended(error: Error): void;
}
export interface CodexConnection {
  request(method: string, params: ObjectValue): Promise<ObjectValue>;
  notify(method: string, params: ObjectValue): void;
  close(): void;
}
export type ConnectCodex = (handlers: CodexHandlers) => CodexConnection;

/**
 * Never forward CLI stderr: SDK diagnostics can contain private paths or auth material. The app
 * server gets an allowlisted env, not Yorozu's own, so its tools cannot read the sidecar's secrets.
 */
export const connectCodex: ConnectCodex = (handlers) => {
  const child = spawn("codex", ["app-server"], { stdio: ["pipe", "pipe", "ignore"], env: childEnv() });
  const lines = createInterface({ input: child.stdout });
  const pending = new Map<number, { resolve(value: ObjectValue): void; reject(error: Error): void; timer: ReturnType<typeof setTimeout> }>();
  const prompts = new Map<unknown, AbortController>();
  let nextId = 0;
  let closed = false;
  const write = (value: unknown): void => { if (!closed) child.stdin.write(`${JSON.stringify(value)}\n`); };
  const close = (error = new Error("Codex connection closed")): void => {
    if (closed) return;
    closed = true;
    for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(error); }
    pending.clear();
    for (const prompt of prompts.values()) prompt.abort();
    prompts.clear();
    lines.close();
    child.stdin.destroy();
    child.kill();
    handlers.ended(error);
  };
  child.once("error", () => close(new Error("Could not start Codex app server")));
  child.stdin.on("error", () => close(new Error("Codex input closed")));
  child.once("exit", (code) => close(new Error(`Codex app server exited (${code ?? "signal"})`)));
  lines.on("line", (line) => {
    try {
      const frame = object(JSON.parse(line));
      const method = string(frame.method);
      if (method && frame.id !== undefined) {
        const controller = new AbortController();
        prompts.set(frame.id, controller);
        void handlers.request(method, object(frame.params), controller.signal).then(
          (result) => write({ id: frame.id, result }),
          () => write({ id: frame.id, error: { code: -32601, message: "Request not supported or cancelled" } }),
        ).finally(() => prompts.delete(frame.id));
      } else if (method) {
        if (method === "serverRequest/resolved") prompts.get(object(frame.params).requestId)?.abort();
        handlers.notify(method, object(frame.params));
      }
      else if (typeof frame.id === "number") {
        const entry = pending.get(frame.id);
        if (!entry) return;
        clearTimeout(entry.timer);
        pending.delete(frame.id);
        if (frame.error) entry.reject(new Error("Codex protocol request failed"));
        else entry.resolve(object(frame.result));
      }
    } catch { close(new Error("Invalid Codex protocol frame")); }
  });
  return {
    request(method, params) {
      if (closed) return Promise.reject(new Error("Codex connection closed"));
      const id = ++nextId;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Codex ${method} timed out`)); }, 30_000);
        timer.unref();
        pending.set(id, { resolve, reject, timer });
        write({ id, method, params });
      });
    },
    notify: (method, params) => write({ method, params }),
    close: () => close(),
  };
};

async function initialize(client: CodexConnection): Promise<void> {
  await client.request("initialize", { clientInfo: { name: "yorozu", version: "1" }, capabilities: { experimentalApi: true } });
  client.notify("initialized", {});
}

export function codexNativeRunner(connect: ConnectCodex = connectCodex): NativeAgentRunner {
  return {
    async models() {
      const client = connect({ notify() {}, request: async () => { throw new Error("No active turn"); }, ended() {} });
      try {
        await initialize(client);
        const models: ModelOption[] = [];
        let defaultId: string | undefined;
        let cursor: string | undefined;
        do {
          const result = await client.request("model/list", { limit: 100, includeHidden: false, ...(cursor ? { cursor } : {}) });
          for (const value of array(result.data)) {
            const model = object(value);
            const efforts = array(model.supportedReasoningEfforts).map((e) => string(object(e).reasoningEffort));
            const id = string(model.model);
            if (model.isDefault) defaultId = id;
            if (id && !model.hidden) models.push({ id, label: string(model.displayName) || id, providerLabel: "Codex",
              efforts: REASONING_EFFORTS.filter((effort) => efforts.includes(effort)) });
          }
          cursor = string(result.nextCursor) || undefined;
        } while (cursor);
        return models.sort((a, b) => Number(b.id === defaultId) - Number(a.id === defaultId));
      } finally { client.close(); }
    },
    async run(turn) {
      if (turn.signal.aborted) return { text: "", sessionId: turn.sessionId };
      // Refuse before the app server is spawned: a turn with no folder must not run where the sidecar does.
      const cwd = turnCwd(turn);
      let sessionId = turn.sessionId;
      let turnId: string | undefined;
      let text = "";
      let lastStreamed = "";
      const streamed = new Map<string, string>();
      const cancel = new AbortController();
      const signal = AbortSignal.any([turn.signal, cancel.signal]);
      let resolve!: () => void;
      let reject!: (error: Error) => void;
      const completion = new Promise<void>((yes, no) => { resolve = yes; reject = no; });
      // Early process exits can precede awaiting completion during initialize/start.
      void completion.catch(() => {});
      const client = connect({
        ended: reject,
        request: (method, params, requestSignal) => answerRequest(method, params, turn, requestSignal ? AbortSignal.any([signal, requestSignal]) : signal),
        notify(method, params) {
          if (params.threadId && params.threadId !== sessionId) return;
          if (method === "turn/started") turnId = string(object(params.turn).id);
          if (method === "item/agentMessage/delta" && !turn.signal.aborted) {
            const id = string(params.itemId);
            const next = (streamed.get(id) ?? "") + string(params.delta);
            streamed.set(id, next);
            lastStreamed = next;
            turn.onUpdate?.(next);
          } else if ((method === "item/started" || method === "item/completed") && !turn.signal.aborted) {
            const item = object(params.item);
            const id = `${turnId ?? "turn"}:${string(item.id)}`;
            const type = string(item.type);
            const complete = method === "item/completed";
            if (type === "agentMessage") {
              if (complete) text = string(item.text) || text;
            } else if (type === "reasoning" || type === "plan") {
              const thought = type === "plan" ? string(item.text) : [...array(item.summary), ...array(item.content)].map(string).join("\n");
              if (thought) turn.onActivity?.(`thought:${id}`, { kind: "thought", data: { text: thought } });
            } else if (["commandExecution", "fileChange", "mcpToolCall", "webSearch", "dynamicToolCall", "collabAgentToolCall"].includes(type)) {
              // Call arguments and results are separate; large output follows shared truncation.
              if (!complete) {
                const args = Object.fromEntries(Object.entries(item).filter(([key]) => !["aggregatedOutput", "result", "contentItems"].includes(key)));
                turn.onActivity?.(`call:${id}`, { kind: "tool_call", data: { callId: id, name: string(item.tool) || type, args } });
              } else {
                const output = typeof item.aggregatedOutput === "string" ? item.aggregatedOutput : JSON.stringify(item.result ?? item.changes ?? item.contentItems ?? item);
                turn.onActivity?.(`result:${id}`, { kind: "tool_result", data: { callId: id,
                  ok: !["failed", "declined"].includes(string(item.status)) && item.success !== false && !item.error, output } });
              }
            }
          } else if (method === "turn/completed") {
            const done = object(params.turn);
            if (done.status === "failed") reject(new Error(string(object(done.error).message) || "Codex turn failed"));
            else resolve();
          }
        },
      });
      let abortTimer: ReturnType<typeof setTimeout> | undefined;
      const abort = (): void => {
        if (sessionId && turnId) {
          abortTimer = setTimeout(() => client.close(), 2_000);
          void client.request("turn/interrupt", { threadId: sessionId, turnId }).catch(() => client.close());
        } else client.close();
      };
      turn.signal.addEventListener("abort", abort, { once: true });
      try {
        await initialize(client);
        const home = await client.request(sessionId ? "thread/resume" : "thread/start", {
          ...(sessionId ? { threadId: sessionId, excludeTurns: true } : {}),
          cwd, model: turn.model ?? null,
          approvalPolicy: turn.bypass ? "never" : "on-request", approvalsReviewer: "user",
          sandbox: turn.bypass ? "danger-full-access" : "workspace-write",
        });
        sessionId = string(object(home.thread).id);
        if (!sessionId) throw new Error("Codex did not return a thread id");
        turn.onSession?.(sessionId);
        if (turn.signal.aborted) return { text: "", sessionId };
        const started = await client.request("turn/start", { threadId: sessionId,
          input: [{ type: "text", text: turn.text, text_elements: [] }], model: turn.model ?? null, effort: turn.effort ?? null });
        turnId = string(object(started.turn).id) || turnId;
        if (turn.signal.aborted) abort();
        await completion;
      } catch (error) {
        if (!turn.signal.aborted) throw error;
      } finally {
        cancel.abort();
        turn.signal.removeEventListener("abort", abort);
        clearTimeout(abortTimer);
        client.close();
      }
      return { text: turn.signal.aborted ? lastStreamed || text : text, ...(sessionId ? { sessionId } : {}) };
    },
  };
}

async function answerRequest(method: string, params: ObjectValue, turn: NativeTurn, signal: AbortSignal): Promise<ObjectValue> {
  if (method === "item/tool/requestUserInput") {
    const answers: Record<string, { answers: string[] }> = {};
    for (const value of array(params.questions)) {
      const question = object(value);
      // Secrets belong in the agent's local credential flow, never in chat history.
      if (question.isSecret) throw new Error("Secret input requires the local agent");
      const answer = await turn.ask?.(string(question.question), array(question.options).map((o) => string(object(o).label)), signal);
      if (answer === undefined || signal.aborted) return { answers: {} };
      answers[string(question.id)] = { answers: [answer] };
    }
    return { answers };
  }
  if (["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"].includes(method)) {
    const allowed = !signal.aborted && (turn.bypass || await turn.approve?.(method.split("/")[1]!, Object.fromEntries(Object.entries(params).filter(([key]) => !["threadId", "turnId", "itemId"].includes(key))), signal));
    if (method === "item/permissions/requestApproval") return { permissions: allowed && !signal.aborted ? object(params.permissions) : {}, scope: "turn" };
    return { decision: allowed && !signal.aborted ? "accept" : "decline" };
  }
  throw new Error("Unsupported Codex request");
}
