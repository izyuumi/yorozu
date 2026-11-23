import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import { sendDurableMessageBatch } from "openclaw/plugin-sdk/channel-outbound";
import { resolveThreadSessionKeys } from "openclaw/plugin-sdk/routing";
import type { HermesBackend, HermesState, KeyRecord } from "./backends.js";
import { errorTag, type Keyed } from "./cards.js";
import { externalTurn, handleMessage, resolveOwnerRoute, type ConversationContext, type ExternalTurn } from "./conversation.js";
import type { Message } from "./envelope.js";
import { createHermesClient, HermesError, mapRunUsage, type HermesClient, type RunEvent, type RunStatus } from "./hermes-client.js";
import { liveSessionId } from "./history.js";
import { isTemporary } from "./retry.js";
import { currentLedger } from "./runs.js";
import { PEER } from "./target.js";

const CHANNEL_ID = "yorozu";
type Log = ChannelGatewayContext["log"];

export type TurnOutcome = "completed" | "failed" | "interrupted" | "cancelled" | "unresolved" | "unreachable" | "refused"
  | "rejected" | "lost" | "capped" | "approval" | "empty" | "unsent" | "mirror_timeout" | "store" | "off" | "crashed";

export type HermesDeps = {
  client: HermesClient;
  apiKey: string;
  state: HermesState;
  keys: Keyed<KeyRecord>;
  turn: ConversationContext;
  park: (message: Message, retryAttempt: number, keep?: () => boolean) => Promise<boolean>;
  log?: Log;
};

export const hermesClients = { create: (backend: HermesBackend): HermesClient => createHermesClient(backend) };

export const INSTRUCTIONS = "You are answering in Yorozu, a chat app on the owner's iPhone, iPad and Mac. Write plain Markdown; tables are fine. Your reply text is the message: don't use a message tool and don't use a card format.";

const OPTED_IN = "This conversation now uses Hermes (test). Hermes doesn't see the earlier messages.";
const SEND_FIRST = "Send one message first, then /backend hermes.";
const ALREADY = "This conversation already uses Hermes.";
const RESET_OFF = "Hermes is off for this conversation; /backend hermes turns it back on.";
const NOT_DROPPED = "Hermes couldn't be turned off for this conversation; nothing was reset.";
const BACKEND_OFF = "The Hermes test backend is off; this message wasn't rerun.";
const BACK_ON_OPENCLAW = "This conversation is back on OpenClaw; this message wasn't rerun.";
const KEY_NOT_READ = "The Hermes request key couldn't be read; this message wasn't rerun.";
const NEW_SESSION = "This conversation started a new Hermes session; this message wasn't rerun.";
const CRASHED = "The Hermes test turn failed.";
const KEY_NOT_STORED = "The Hermes request key couldn't be stored.";
const MIRROR_TIMED_OUT = "The Hermes test couldn't record your message in history; it wasn't sent to Hermes.";
const UNREACHABLE = "The Hermes test backend isn't answering.";
const REFUSED = "The Hermes test backend refused the API key.";
const UNRESOLVED = "The Hermes run couldn't be resolved.";
const LOST = "Lost contact with the Hermes run.";
const CAPPED = "The Hermes run took over 30 minutes.";
const EMPTY = "Hermes finished with an empty reply.";
const APPROVAL_FAILED = "Hermes asked for an approval that could not be answered.";

const TERMINAL = new Set(["completed", "failed", "interrupted", "cancelled"]);
const APPROVAL_KIND = "approval";
const MIRROR_MS = 10_000;
const EARLIER_MS = 60_000;
const CAP_MS = 30 * 60 * 1000;
const POLL_MS = 5_000;
const CAP = Symbol("cap");
const ignoredEvents = new Set<string>();
const queued = new Map<string, number>();

const isOptIn = (text: string) => text.trim().replace(/\s+/g, " ").toLowerCase() === "/backend hermes";
const isReset = (text: string) => /^\/(new|reset)$/i.test(text.trim().split(/\s+/)[0] ?? "");
const kindOf = (error: unknown) => (error instanceof HermesError ? error.kind : undefined);
const tagOf = (error: unknown) => kindOf(error) ?? errorTag(error);
const string = (value: unknown) => (typeof value === "string" ? value : undefined);
const redact = (text: string, key: string) => (key ? text.replaceAll(key, "[redacted]") : text);
const oneLine = (text: string) => text.replace(/[\r\n]+/g, " ");

function redacted(deps: HermesDeps): HermesDeps {
  const { log, apiKey } = deps;
  if (!log || !apiKey) return deps;
  const safe = (level: "info" | "warn" | "error" | "debug") => (line: string) => log[level]?.(redact(line, apiKey));
  return { ...deps, log: { ...log, info: safe("info"), warn: safe("warn"), error: safe("error"), ...(log.debug && { debug: safe("debug") }) } };
}

type Tally = { runId?: string; usage?: RunStatus["usage"] };

function turnEndLine(log: Log | undefined, messageId: string, tally: Tally, outcome: TurnOutcome): void {
  const { usage } = tally;
  const line = `yorozu: hermes turn end ${messageId} run=${tally.runId ?? "-"} outcome=${outcome}`
    + ` tokens_in=${usage?.inputTokens ?? null} tokens_out=${usage?.outputTokens ?? null} tokens_total=${usage?.totalTokens ?? null}`;
  if (outcome === "completed") log?.info(line);
  else log?.warn(line);
}

function end(log: Log | undefined, messageId: string, t: ExternalTurn, tally: Tally, outcome: TurnOutcome, failText?: string): boolean {
  const ended = failText === undefined ? t.done() : t.fail(failText);
  if (ended) turnEndLine(log, messageId, tally, outcome);
  return ended;
}

function crashed(turn: ConversationContext, log: Log | undefined, message: Message, attempt: number, error: unknown, t?: ExternalTurn, tally: Tally = {}): void {
  log?.warn(`yorozu: hermes turn failed: ${errorTag(error)}`);
  end(log, message.messageId, t ?? externalTurn(turn, message, attempt), tally, "crashed", CRASHED);
}

function enqueue(state: HermesState, convId: string, fn: () => Promise<void>): Promise<void> {
  queued.set(convId, (queued.get(convId) ?? 0) + 1);
  return state.serial(convId, fn).finally(() => {
    const left = (queued.get(convId) ?? 1) - 1;
    if (left) queued.set(convId, left);
    else queued.delete(convId);
  });
}

function threadSession(ctx: ConversationContext, convId: string) {
  const route = resolveOwnerRoute(ctx.cfg, ctx.agent, ctx.accountId);
  const { sessionKey } = resolveThreadSessionKeys({ baseSessionKey: route.sessionKey, threadId: convId });
  return { agentId: route.agentId, sessionKey };
}

async function sendText(ctx: ConversationContext, convId: string, text: string, mirror: boolean): Promise<string> {
  const { agentId, sessionKey } = threadSession(ctx, convId);
  try {
    const sent = await sendDurableMessageBatch({
      cfg: ctx.cfg,
      channel: CHANNEL_ID,
      to: PEER,
      accountId: ctx.accountId,
      threadId: convId,
      payloads: [{ text }],
      durability: "best_effort",
      ...(mirror && { mirror: { sessionKey, agentId, text } }),
    });
    return sent.status;
  } catch (error) {
    return errorTag(error);
  }
}

async function mirrorUser(ctx: ConversationContext, message: Message): Promise<"done" | "failed" | "timeout" | "skipped"> {
  const { agentId, sessionKey } = threadSession(ctx, message.convId);
  const sessionId = liveSessionId(agentId, sessionKey);
  if (!sessionId) return "skipped";
  const now = Date.now();
  const append = (async () => {
    const { appendSessionTranscriptMessageByIdentity } = await import("openclaw/plugin-sdk/session-transcript-runtime");
    await appendSessionTranscriptMessageByIdentity({
      agentId,
      sessionKey,
      sessionId,
      config: ctx.cfg,
      now,
      message: {
        role: "user",
        content: [{ type: "text", text: message.text }],
        timestamp: now,
        provenance: { kind: "external_user" },
        __openclaw: { transport: { messageId: message.messageId } },
      },
    });
  })();
  const timeout = timer(MIRROR_MS, "timeout" as const);
  try {
    return await Promise.race([
      append.then(() => "done" as const, (error: unknown) => {
        ctx.log?.warn(`yorozu: hermes mirror failed ${message.messageId}: ${errorTag(error)}`);
        return "failed" as const;
      }),
      timeout.promise,
    ]);
  } finally {
    timeout.cancel();
  }
}

function timer<T>(ms: number, value: T) {
  let fired = false;
  let handle: ReturnType<typeof setTimeout> | undefined;
  const promise = new Promise<T>((resolve) => {
    handle = setTimeout(() => {
      fired = true;
      resolve(value);
    }, ms);
  });
  return {
    promise,
    get fired() {
      return fired;
    },
    cancel() {
      if (!fired && handle) clearTimeout(handle);
    },
  };
}

async function notice(deps: HermesDeps, message: Message, text: string, opts: { user: boolean; ledger: boolean }): Promise<void> {
  const { convId, messageId } = message;
  const { agentId, sessionKey } = threadSession(deps.turn, convId);
  const entry = liveSessionId(agentId, sessionKey) !== undefined;
  if (entry && opts.user && (await mirrorUser(deps.turn, message)) === "timeout") {
    deps.log?.warn(`yorozu: hermes mirror timed out ${messageId}`);
  }
  const status = await sendText(deps.turn, convId, text, entry);
  if (status !== "sent") deps.log?.warn(`yorozu: hermes notice not sent: ${status}`);
  if (opts.ledger) currentLedger()?.turnEnded(messageId, convId, { parked: false, queued: false });
}

async function endEarlierRuns(deps: HermesDeps, convId: string, messageId?: string): Promise<void> {
  const { client, state, log } = deps;
  const ids = state.unsettled(convId, messageId);
  if (!ids.length) return;
  const STOP = Symbol("stop");
  let failed: "unavailable" | undefined;
  const deadline = timer(EARLIER_MS, STOP);
  const stopped = () => (deadline.fired ? "timeout" : failed);
  const call = async <T>(start: () => Promise<T>): Promise<T> => {
    if (stopped()) throw STOP;
    const settled = start().then((value) => ({ value }), (error: unknown) => ({ error }));
    const result = await Promise.race([settled, deadline.promise]);
    if (result === STOP || stopped()) throw STOP;
    if ("error" in result) {
      if (kindOf(result.error) === "unavailable") failed = "unavailable";
      throw result.error;
    }
    return result.value;
  };
  const remove = (id: string) => call(() => state.removeUnsettled(convId, id)).catch((error: unknown) => {
    if (error !== STOP) log?.warn(`yorozu: hermes run not removed ${id}: ${errorTag(error)}`);
  });
  let reason: "timeout" | "unavailable" | undefined;
  try {
    for (const id of ids) {
      if (stopped()) break;
      try {
        let run = await call(() => client.status(id));
        if (run.status === "unknown" && run.admissionId !== undefined && run.generation !== undefined) {
          const { admissionId, generation } = run;
          await call(() => client.resolveUnknown(id, admissionId, generation));
          run = await call(() => client.status(id));
        }
        if (!TERMINAL.has(run.status)) {
          await call(() => client.stop(id));
          run = await call(() => client.status(id));
        }
        if (TERMINAL.has(run.status)) await remove(id);
        else log?.warn(`yorozu: hermes earlier run not ended ${id} ${oneLine(redact(run.status, deps.apiKey)).slice(0, 64)}`);
      } catch (error) {
        if (stopped()) break;
        if (kindOf(error) === "not_found") await remove(id);
        else log?.warn(`yorozu: hermes earlier run not ended ${id} ${tagOf(error)}`);
      }
    }
  } finally {
    reason = stopped();
    deadline.cancel();
  }
  if (reason) {
    log?.warn(`yorozu: hermes earlier runs check stopped ${convId}: ${reason}, ${state.unsettled(convId, messageId).length} ids kept`);
  }
}

export function requestBody(message: Message, session: string): string {
  const parts: string[] = [];
  if (message.replyTo) {
    const quote = message.replyTo.text?.replace(/\s+/g, " ").trim().slice(0, 500);
    parts.push(quote ? `> ${quote}` : "> (an earlier message)");
  }
  if (message.text) parts.push(message.text);
  const attachments = message.attachments?.length ?? 0;
  if (attachments) parts.push(`[${attachments} attachment(s) not sent to the Hermes test]`);
  return JSON.stringify({ input: parts.join("\n\n"), session_id: session, instructions: INSTRUCTIONS });
}

type Run = {
  deps: HermesDeps;
  message: Message;
  t: ExternalTurn;
  tally: Tally;
  runId: string;
  keyAttempt: number;
  session: string;
  replayed: boolean;
  nextSeq: number;
  gap: boolean;
  toolSeen: boolean;
  lost: boolean;
  cap?: { readonly fired: boolean };
  denied: string[];
  deniedIds: Set<string>;
  openTools: { callId: string; name: string }[];
  end(outcome: TurnOutcome, failText?: string): boolean;
  retryLater(reason: string, outcome: TurnOutcome, failText: string, keep?: () => boolean): Promise<void>;
};

const hang = <T>() => new Promise<T>(() => {});

function live<T>(r: Run, start: () => Promise<T>): Promise<T> {
  const over = () => r.cap?.fired === true;
  if (over()) return hang();
  return start().then(
    (value) => (over() ? hang<T>() : value),
    (error: unknown) => (over() ? hang<T>() : Promise.reject(error)),
  );
}

function failureText(key: string, data: Record<string, unknown> | undefined, run?: RunStatus): string {
  const raw = () => {
    if (!data) return run?.output ?? "";
    const { error } = data;
    if (typeof error === "string") return error;
    const message = string((error as { message?: unknown } | undefined)?.message) ?? string(data.message);
    return message ?? JSON.stringify(error ?? data);
  };
  return redact(raw(), key);
}

async function deliver(r: Run, output: string | undefined, readUsage: boolean): Promise<void> {
  const { deps, message, t, tally } = r;
  if (!output?.trim()) {
    r.end("empty", EMPTY);
    return;
  }
  if (r.cap?.fired) return;
  const status = await sendText(deps.turn, message.convId, [redact(output, deps.apiKey), ...r.denied].join("\n\n"), true);
  if (status !== "sent") {
    r.end("unsent", `The Hermes reply couldn't be sent: ${status}.`);
    return;
  }
  if (r.cap?.fired || !t.done()) return;
  if (readUsage) tally.usage = (await deps.client.status(r.runId).catch(() => undefined))?.usage;
  turnEndLine(deps.log, message.messageId, tally, "completed");
}

async function byStatus(
  r: Run,
  status: string,
  source: "replay" | "poll" | "event",
  run?: RunStatus,
  data?: Record<string, unknown>,
  resolved = false,
): Promise<"ended" | "open"> {
  const { deps, message, runId } = r;
  const { client, state, keys, log } = deps;
  if (TERMINAL.has(status)) {
    await live(r, () => state.removeUnsettled(message.convId, runId)
      .catch((error: unknown) => log?.warn(`yorozu: hermes run not removed ${runId}: ${errorTag(error)}`)));
  }
  switch (status) {
    case "completed": {
      let output = string(data?.output) ?? run?.output;
      const usage = mapRunUsage(data?.usage);
      let readUsage = source === "event" && usage === undefined;
      if (usage !== undefined) r.tally.usage = usage;
      if (output === undefined && source === "event") {
        const final = await live(r, () => client.status(runId)).catch(() => undefined);
        output = final?.output;
        r.tally.usage = usage ?? final?.usage;
        readUsage = false;
      }
      await deliver(r, output, readUsage);
      return "ended";
    }
    case "failed": {
      const text = failureText(deps.apiKey, data, run);
      const failText = `Hermes: ${text.slice(0, 500)}`;
      const whole = source === "event" && !r.replayed && !r.gap && !r.lost && !r.toolSeen;
      if (whole && isTemporary(text)) {
        try {
          await live(r, () => keys.register(message.messageId, { keyAttempt: r.keyAttempt + 1, session: r.session }));
        } catch (error) {
          log?.warn(`yorozu: hermes request key not stored: ${errorTag(error)}`);
          r.end("store", failText);
          return "ended";
        }
        await r.retryLater(oneLine(text).slice(0, 200), "failed", failText, () => r.cap?.fired !== true);
        return "ended";
      }
      r.end("failed", failText);
      return "ended";
    }
    case "interrupted":
      r.end("interrupted", "Hermes interrupted this run.");
      return "ended";
    case "cancelled":
      r.end("cancelled", "Hermes cancelled this run.");
      return "ended";
    case "unknown": {
      if (resolved) {
        r.end("unresolved", UNRESOLVED);
        return "ended";
      }
      try {
        const current = run ?? (await live(r, () => client.status(runId)));
        if (current.admissionId === undefined || current.generation === undefined) throw new Error("no admission");
        const { admissionId, generation } = current;
        await live(r, () => client.resolveUnknown(runId, admissionId, generation));
        const next = await live(r, () => client.status(runId));
        r.tally.usage = next.usage;
        return await byStatus(r, next.status, source, next, undefined, true);
      } catch (error) {
        log?.warn(`yorozu: hermes run not resolved ${runId}: ${tagOf(error)}`);
        r.end("unresolved", UNRESOLVED);
        return "ended";
      }
    }
    default:
      return "open";
  }
}

function deniedLabel(label: string | undefined, apiKey: string): string {
  const text = redact(label ?? "", apiKey).replace(/\s+/g, " ").trim();
  return text.length > 120 ? `${text.slice(0, 119)}…` : text || "a tool";
}

async function approve(r: Run, run?: RunStatus): Promise<"ended" | "open"> {
  const { client, log } = r.deps;
  const failed = async () => {
    await live(r, () => client.stop(r.runId)).catch(() => {});
    r.end("approval", APPROVAL_FAILED);
    return "ended" as const;
  };
  let current = run;
  try {
    current ??= await live(r, () => client.status(r.runId));
    r.tally.usage = current.usage ?? r.tally.usage;
  } catch (error) {
    log?.warn(`yorozu: hermes approval not read ${r.runId}: ${tagOf(error)}`);
    return failed();
  }
  const controls = current.pendingControls.filter((control) => control.kind === APPROVAL_KIND);
  const fresh = controls.filter((control) => !r.deniedIds.has(control.id));
  if (!fresh.length) return run && controls.length ? "open" : failed();
  for (const control of fresh) {
    try {
      const generation = current.generation ?? 0;
      await live(r, () => client.deny(r.runId, control.id, generation));
    } catch (error) {
      log?.warn(`yorozu: hermes approval not denied ${r.runId}: ${tagOf(error)}`);
      return failed();
    }
    r.deniedIds.add(control.id);
    r.denied.push(`Denied: ${deniedLabel(control.tool, r.deps.apiKey)} needed an approval Yorozu can't show yet.`);
  }
  return "open";
}

function toolEvent(r: Run, event: RunEvent): void {
  const { data } = event;
  r.toolSeen = true;
  const key = r.deps.apiKey;
  const id = string(data.tool_call_id);
  const found = [data.tool, data.name].map(string).find((value) => value?.trim());
  const name = found === undefined ? undefined : redact(found, key);
  const callIdOf = (part: string | number | undefined) => redact(`hermes:${r.runId}:${part}`, key);
  if (event.event === "tool.started") {
    const callId = callIdOf(id ?? event.seq);
    const entry = { callId, name: name ?? "tool" };
    r.openTools.push(entry);
    r.t.tool(callId, entry.name, "running");
    return;
  }
  let index = id !== undefined
    ? r.openTools.findIndex((open) => open.callId === callIdOf(id))
    : r.openTools.findIndex((open) => open.name === name);
  if (index < 0 && id === undefined) index = 0;
  const [open] = index >= 0 ? r.openTools.splice(index, 1) : [];
  const callId = open?.callId ?? callIdOf(id ?? event.seq);
  r.t.tool(callId, name ?? open?.name ?? "tool", data.error === true || data.success === false ? "failed" : "done");
}

async function onEvent(r: Run, event: RunEvent): Promise<"ended" | "open"> {
  switch (event.event) {
    case "tool.started":
    case "tool.completed":
      toolEvent(r, event);
      return "open";
    case "approval.request":
      return approve(r);
    case "run.completed":
    case "run.failed":
    case "run.interrupted":
    case "run.cancelled":
      return byStatus(r, event.event.slice(4), "event", undefined, event.data);
    default:
      if (!ignoredEvents.has(event.event)) {
        ignoredEvents.add(event.event);
        r.deps.log?.info(`yorozu: hermes event ignored: ${oneLine(redact(event.event, r.deps.apiKey)).slice(0, 64)}`);
      }
      return "open";
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function attach(r: Run): Promise<void> {
  const { client, log } = r.deps;
  r.t.started();
  const abort = new AbortController();
  const cap = timer(CAP_MS, CAP);
  r.cap = cap;
  const within = <T>(work: Promise<T>) => Promise.race([work, cap.promise]);
  const capped = async () => {
    abort.abort();
    await client.stop(r.runId).catch(() => {});
    await r.deps.keys.register(r.message.messageId, { keyAttempt: r.keyAttempt, session: r.session, ended: true })
      .catch((error: unknown) => log?.warn(`yorozu: hermes request key not stored: ${errorTag(error)}`));
    r.end("capped", CAPPED);
  };
  const stream = client.events(r.runId, abort.signal)[Symbol.asyncIterator]();
  try {
    try {
      for (;;) {
        const next = await within(stream.next());
        if (next === CAP) return await capped();
        if (next.done) {
          log?.info(`yorozu: hermes stream lost ${r.runId}: ended`);
          break;
        }
        r.gap ||= next.value.seq !== r.nextSeq++;
        const handled = await within(onEvent(r, next.value));
        if (handled === CAP) return await capped();
        if (handled === "ended") return;
      }
    } catch (error) {
      if (!(error instanceof HermesError)) throw error;
      log?.info(`yorozu: hermes stream lost ${r.runId}: ${error.kind}`);
    }
    r.lost = true;
    for (;;) {
      if ((await within(sleep(POLL_MS))) === CAP) return await capped();
      let run: RunStatus | typeof CAP;
      try {
        run = await within(client.status(r.runId));
      } catch (error) {
        if (!(error instanceof HermesError)) throw error;
        if (error.kind === "unavailable") continue;
        log?.warn(`yorozu: hermes run status failed ${r.runId}: ${error.kind}`);
        r.end("lost", LOST);
        return;
      }
      if (run === CAP) return await capped();
      r.tally.usage = run.usage ?? r.tally.usage;
      const approvals = run.pendingControls.some((control) => control.kind === APPROVAL_KIND && !r.deniedIds.has(control.id));
      const approved = approvals ? await within(approve(r, run)) : "open";
      if (approved === CAP) return await capped();
      if (approved === "ended") return;
      const handled = await within(byStatus(r, run.status, "poll", run));
      if (handled === CAP) return await capped();
      if (handled === "ended") return;
    }
  } finally {
    cap.cancel();
    abort.abort();
    void stream.return?.(undefined).catch(() => {});
  }
}

async function delegate(deps: HermesDeps, message: Message, retryAttempt: number, t: ExternalTurn, tally: Tally): Promise<void> {
  const { client, state, keys, log } = deps;
  const { convId, messageId } = message;
  const finish = (outcome: TurnOutcome, failText?: string) => end(log, messageId, t, tally, outcome, failText);
  const session = state.session(convId);
  if (!session) {
    finish("off", BACK_ON_OPENCLAW);
    return;
  }
  await endEarlierRuns(deps, convId, messageId);

  let record: KeyRecord | undefined;
  try {
    record = await keys.lookup(messageId);
  } catch (error) {
    log?.warn(`yorozu: hermes request key not read: ${errorTag(error)}`);
    finish("store", "The Hermes request key couldn't be read.");
    return;
  }
  if (record?.session !== undefined && record.session !== session) {
    finish("off", NEW_SESSION);
    return;
  }
  if (!record) {
    record = { keyAttempt: 0, session };
    try {
      await keys.register(messageId, record);
    } catch (error) {
      log?.warn(`yorozu: hermes request key not stored: ${errorTag(error)}`);
      finish("store", KEY_NOT_STORED);
      return;
    }
    if ((await mirrorUser(deps.turn, message)) === "timeout") {
      log?.warn(`yorozu: hermes mirror timed out ${messageId}`);
      finish("mirror_timeout", MIRROR_TIMED_OUT);
      return;
    }
  }

  const key = `${messageId}:${record.keyAttempt}`;
  const pinned = record.session ?? session;
  const body = requestBody(message, pinned);
  const retryLater = async (reason: string, outcome: TurnOutcome, failText: string, keep?: () => boolean) => {
    if (await deps.park(message, retryAttempt, keep).catch(() => false)) {
      t.parked();
      log?.info(`yorozu: hermes run parked (retry ${retryAttempt + 1} queued): ${reason}`);
      return;
    }
    if (keep?.() !== false) finish(outcome, failText);
  };
  const refused = (error: HermesError) => {
    if (error.kind === "auth") return finish("refused", REFUSED);
    const answer = [error.status, error.code].filter((part) => part !== undefined).join(" ");
    log?.warn(`yorozu: hermes answered ${answer} (${error.kind})`);
    return finish("rejected", `Hermes answered ${answer}.`);
  };

  await t.handing();
  let created;
  try {
    created = await client.createRun({ key, body });
  } catch (error) {
    if (!(error instanceof HermesError)) throw error;
    log?.warn(`yorozu: hermes createRun ${key} run=- replayed=- error=${error.kind}`);
    if (error.kind === "unavailable") return retryLater("isn't answering", "unreachable", UNREACHABLE);
    refused(error);
    return;
  }
  log?.info(`yorozu: hermes createRun ${key} run=${created.runId} replayed=${created.replayed} error=-`);
  const { runId } = created;
  tally.runId = runId;
  await state.addUnsettled(convId, runId, messageId)
    .catch((error: unknown) => log?.warn(`yorozu: hermes run not stored ${runId}: ${errorTag(error)}`));

  const r: Run = {
    deps, message, t, tally, runId, keyAttempt: record.keyAttempt, session: pinned, replayed: created.replayed,
    nextSeq: 0, gap: false, toolSeen: false, lost: false,
    denied: [], deniedIds: new Set(), openTools: [],
    end: (outcome, failText) => (outcome !== "capped" && r.cap?.fired === true ? false : finish(outcome, failText)),
    retryLater,
  };
  if (created.replayed) {
    let run: RunStatus;
    try {
      run = await client.status(runId);
    } catch (error) {
      if (!(error instanceof HermesError)) throw error;
      if (error.kind === "unavailable") return retryLater("isn't answering", "unreachable", UNREACHABLE);
      refused(error);
      return;
    }
    tally.usage = run.usage;
    if ((await byStatus(r, run.status, "replay", run)) === "ended") return;
  }
  await attach(r);
}

export async function hermesTurn(raw: HermesDeps, message: Message, retryAttempt = 0): Promise<void> {
  const deps = redacted(raw);
  const tally: Tally = {};
  let t: ExternalTurn | undefined;
  try {
    t = externalTurn(deps.turn, message, retryAttempt);
    await delegate(deps, message, retryAttempt, t, tally);
  } catch (error) {
    crashed(deps.turn, deps.log, message, retryAttempt, error, t, tally);
  }
}

async function optIn(deps: HermesDeps, message: Message): Promise<void> {
  const { convId, messageId } = message;
  const opts = { user: true, ledger: true };
  if (deps.state.routedToHermes(convId)) return notice(deps, message, ALREADY, opts);
  const { agentId, sessionKey } = threadSession(deps.turn, convId);
  if (liveSessionId(agentId, sessionKey) === undefined) return notice(deps, message, SEND_FIRST, opts);
  await deps.state.setRoute(convId, messageId);
  deps.log?.info(`yorozu: hermes route set ${convId}`);
  await notice(deps, message, OPTED_IN, opts);
}

async function resetRoute(raw: HermesDeps, message: Message): Promise<void> {
  const deps = redacted(raw);
  const { convId } = message;
  await endEarlierRuns(deps, convId);
  try {
    await deps.state.dropRoute(convId);
  } catch (error) {
    deps.log?.warn(`yorozu: hermes route not dropped: ${errorTag(error)}`);
    await notice(deps, message, NOT_DROPPED, { user: true, ledger: true });
    return;
  }
  deps.log?.info(`yorozu: hermes route dropped ${convId}`);
  await handleMessage(deps.turn, message);
  await notice(deps, message, RESET_OFF, { user: false, ledger: false });
}

async function routed(deps: HermesDeps, message: Message): Promise<void> {
  try {
    if (isOptIn(message.text)) return await optIn(deps, message);
    if (!deps.state.routedToHermes(message.convId)) return await handleMessage(deps.turn, message);
    if (isReset(message.text)) return await resetRoute(deps, message);
    await hermesTurn(deps, message);
  } catch (error) {
    crashed(deps.turn, deps.log, message, 0, error);
  }
}

export async function routeMessage(deps: HermesDeps, message: Message): Promise<void> {
  try {
    const { convId } = message;
    if (!isOptIn(message.text) && !deps.state.routedToHermes(convId) && !queued.has(convId)) {
      return await handleMessage(deps.turn, message);
    }
    await enqueue(deps.state, convId, () => routed(deps, message));
  } catch (error) {
    crashed(deps.turn, deps.log, message, 0, error);
  }
}

export async function routedRerun(
  r: { keys: Keyed<KeyRecord>; turn: ConversationContext; deps?: HermesDeps; log?: Log },
  message: Message,
  retryAttempt: number,
): Promise<void> {
  const { convId, messageId } = message;
  try {
    let record: KeyRecord | undefined;
    try {
      record = await r.keys.lookup(messageId);
    } catch (error) {
      r.log?.warn(`yorozu: hermes request key not read: ${errorTag(error)}`);
      end(r.log, messageId, externalTurn(r.turn, message, retryAttempt), {}, "store", KEY_NOT_READ);
      return;
    }
    if (!record) return await handleMessage(r.turn, message, retryAttempt);
    if (record.ended) return;
    const { deps } = r;
    if (!deps) {
      end(r.log, messageId, externalTurn(r.turn, message, retryAttempt), {}, "off", BACKEND_OFF);
      return;
    }
    await enqueue(deps.state, convId, async () => {
      if (deps.state.routedToHermes(convId)) return hermesTurn(deps, message, retryAttempt);
      end(deps.log, messageId, externalTurn(deps.turn, message, retryAttempt), {}, "off", BACK_ON_OPENCLAW);
    });
  } catch (error) {
    crashed(r.turn, r.log, message, retryAttempt, error);
  }
}
