/** Durable presentation/transport receipts. The harness owns decisions and execution. */
import { randomUUID } from "node:crypto";
import { closeSync, constants, fstatSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { harnessActionAcceptsAnswer, parseHarnessAction, parseHarnessActionAnswer, parseHarnessActionStatus,
  parseAgentExchange, parseAgentExchangeStatus, type HarnessActionData, type HarnessActionAnswerData,
  type HarnessActionStatusData, type HarnessOrigin, type AgentExchangeData, type AgentExchangeStatusData, type YorozuEvent } from "@yorozu/shared";
import { safeAgentPath } from "./agent-scope.js";
import { harnessDigest } from "./harness-ledger.js";
import { createThread } from "./threads.js";

type Action = { action: HarnessActionData; operations: Record<string, HarnessActionStatusData>; answers?: Record<string, string> };
type Exchange = { message: AgentExchangeData; receipt: AgentExchangeStatusData };
interface Journal { version: 1; actions: Record<string, Action>; messages: Record<string, Exchange> }
export type HarnessActionResponder = (answer: HarnessActionAnswerData) => Promise<{ status: "applied" | "requested" | "rejected" | "unknown"; reason?: string }>;
const MAX_BYTES = 8 * 1024 * 1024, MAX_ACTIONS = 512, MAX_MESSAGES = 1024;
const record = (v: unknown): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v);
const id = (v: unknown): v is string => typeof v === "string" && /^[\w.-]{1,128}$/.test(v);
export const exchangeThreadId = (exchangeId: string): string => `agent-exchange-${harnessDigest(exchangeId).slice(0, 48)}`;
const originKey = (origin: HarnessOrigin): unknown[] => [origin.version, origin.agentId, origin.pluginId, origin.conversationId, origin.sessionId, origin.workId ?? null, origin.bindingEpoch];
const actionKey = (action: Pick<HarnessActionData, "origin" | "requestId">): string => harnessDigest([originKey(action.origin), action.requestId]);
const answerKey = (answer: HarnessActionAnswerData): string => harnessDigest([originKey(answer.origin), answer.requestId, answer.choiceId ?? null, answer.text ?? null, answer.uiTargetId ?? null]);

export class HarnessPlatformStore {
  readonly root: string;
  private readonly file: string;
  private readonly journal: Journal;
  private emit?: (event: YorozuEvent) => void;
  private changed?: () => void;
  private broken = false;
  private responders = new Map<string, { respond: HarnessActionResponder; current(): boolean }>();
  constructor(readonly dir: string) {
    this.root = safeAgentPath(join(dir, "harness-platform-v1")); mkdirSync(this.root, { recursive: true, mode: 0o700 });
    this.file = join(this.root, "journal.json");
    let value: any;
    try {
      const fd = openSync(this.file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      try {
        const stat = fstatSync(fd);
        if (!stat.isFile() || stat.nlink !== 1 || stat.size > MAX_BYTES) throw new Error("Invalid harness platform journal");
        value = JSON.parse(readFileSync(fd, "utf8"));
      } finally { closeSync(fd); }
    } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    value ??= { version: 1, actions: {}, messages: {} };
    if (!record(value) || Object.keys(value).some(k => !["version", "actions", "messages"].includes(k)) || value.version !== 1
      || !record(value.actions) || !record(value.messages) || Object.keys(value.actions).length > MAX_ACTIONS || Object.keys(value.messages).length > MAX_MESSAGES)
      throw new Error("Damaged harness platform journal");
    for (const [key, entry] of Object.entries(value.actions) as [string, Action][]) {
      if (!record(entry) || Object.keys(entry).some(k => !["action", "operations", "answers"].includes(k)) || !record(entry.operations)
        || Object.keys(entry.operations).length > 32 || key !== actionKey(parseHarnessAction(entry.action))) throw new Error("Damaged harness action ownership");
      for (const [operation, value] of Object.entries(entry.operations)) {
        const receipt = parseHarnessActionStatus(value);
        if (!id(operation) || receipt.operationId !== operation || actionKey(receipt) !== key) throw new Error("Damaged harness action receipt ownership");
      }
      entry.operations = Object.assign(Object.create(null), entry.operations);
      entry.answers = Object.assign(Object.create(null), entry.answers ?? {});
      if (entry.answers !== undefined && (!record(entry.answers) || Object.entries(entry.answers).some(([operation, digest]) => !id(operation) || typeof digest !== "string" || !/^[a-f0-9]{64}$/.test(digest))))
        throw new Error("Damaged harness answer identity");
      // No retained callback survives a host restart. Never replay an approval/sign-in.
      if (entry.action.state === "pending") entry.action.state = "cancelled";
      for (const receipt of Object.values(entry.operations)) if (receipt.status === "requested") receipt.status = "unknown";
    }
    for (const [key, entry] of Object.entries(value.messages) as [string, Exchange][]) {
      if (!record(entry) || Object.keys(entry).some(k => !["message", "receipt"].includes(k)) || key !== parseAgentExchange(entry.message).messageId)
        throw new Error("Damaged agent message ownership");
      const receipt = parseAgentExchangeStatus(entry.receipt);
      if (receipt.messageId !== key || receipt.deliveryId !== entry.message.deliveryId || receipt.exchangeId !== entry.message.exchangeId)
        throw new Error("Damaged agent delivery receipt");
      if (receipt.attemptId && receipt.delivery === "accepted") { receipt.delivery = "unknown"; receipt.execution = "unknown"; receipt.reason = "Prior adapter inbox admission is unconfirmed; no automatic resend."; }
    }
    this.journal = value as unknown as Journal; this.save();
  }
  private save(): void {
    if (this.broken) throw new Error("Harness platform journal is unconfirmed; new actions and message admissions are held");
    try {
    safeAgentPath(this.root, true); safeAgentPath(this.file);
    const bytes = JSON.stringify(this.journal) + "\n";
    if (Buffer.byteLength(bytes) > MAX_BYTES) throw new Error("Harness transport retention budget exceeded; existing data is retained");
    const temporary = join(this.root, `.pending-${randomUUID()}`);
    const fd = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { writeFileSync(fd, bytes); fsyncSync(fd); } finally { closeSync(fd); }
    renameSync(temporary, this.file);
    const parent = openSync(this.root, constants.O_RDONLY | constants.O_NOFOLLOW);
    try { fsyncSync(parent); } finally { closeSync(parent); }
    } catch (error) { this.broken = true; throw error; }
  }
  get unconfirmed(): boolean { return this.broken; }
  hasUnconfirmedActions(agentId?: string, includeRequested = true): boolean {
    return this.broken || Object.values(this.journal.actions).some(entry => (!agentId || entry.action.origin.agentId === agentId)
      && Object.values(entry.operations).some(receipt => receipt.status === "unknown" || includeRequested && entry.action.state === "pending" && receipt.status === "requested"));
  }
  bind(emit: (event: YorozuEvent) => void, changed?: () => void): void {
    this.emit = emit; this.changed = changed;
    for (const entry of Object.values(this.journal.actions)) this.projectAction(entry);
    for (const entry of Object.values(this.journal.messages)) this.projectExchange(entry);
  }
  private projectAction(entry: Action): void {
    // Projection can be rebuilt from the durable journal. A display/transport error
    // must not turn an already persisted admission into a rejection or skip its handoff.
    try { this.projectActionEvents(entry); } catch { /* Reproject on the next bind/update. */ }
  }
  private projectActionEvents(entry: Action): void {
    const action = entry.action;
    this.emit?.({ id: `harness-action-${actionKey(action)}`, threadId: action.origin.conversationId, agentId: "main", ts: Date.now(), kind: "harness_action", data: structuredClone(action) });
    for (const receipt of Object.values(entry.operations)) this.emit?.({ id: `harness-action-status-${harnessDigest(receipt.operationId)}`,
      threadId: action.origin.conversationId, agentId: "main", ts: Date.now(), kind: "harness_action_status", data: structuredClone(receipt) });
    this.changed?.();
  }
  openAction(value: HarnessActionData, respond: HarnessActionResponder, current: () => boolean): void {
    if (this.broken) throw new Error("Harness action journal is unconfirmed");
    const action = parseHarnessAction(value), key = actionKey(action), old = this.journal.actions[key];
    if (old) {
      if (harnessDigest({ ...old.action, state: "pending" }) !== harnessDigest(action)) throw new Error("Harness request identity conflict");
      // A completed/recovered action never becomes actionable again by repetition.
      if (old.action.state !== "pending") return;
    } else {
      if (Object.keys(this.journal.actions).length >= MAX_ACTIONS) throw new Error("Harness action retention budget is full");
      this.journal.actions[key] = { action: structuredClone(action), operations: Object.create(null), answers: Object.create(null) }; this.save();
    }
    this.responders.set(key, { respond, current }); this.projectAction(this.journal.actions[key]);
  }
  cancelAction(origin: HarnessOrigin, requestId: string): void {
    const key = actionKey({ origin, requestId }), entry = this.journal.actions[key];
    this.responders.delete(key);
    if (entry?.action.state === "pending") {
      entry.action.state = "cancelled";
      for (const receipt of Object.values(entry.operations)) if (receipt.status === "requested") receipt.status = "no-longer-needed";
      this.save(); this.projectAction(entry);
    }
  }
  async answer(event: YorozuEvent): Promise<void> {
    if (this.broken) throw new Error("Harness action journal is unconfirmed");
    if (event.kind !== "harness_action_answer" || !id(event.id)) throw new Error("Invalid harness action operation");
    const answer = parseHarnessActionAnswer(event.data), key = actionKey(answer), entry = this.journal.actions[key];
    if (!entry || event.threadId !== answer.origin.conversationId) throw new Error("Unknown harness action");
    const old = entry.operations[event.id];
    if (old) { if (entry.answers?.[event.id] !== answerKey(answer)) throw new Error("Harness answer operation identity conflict"); this.projectAction(entry); return; }
    if (Object.keys(entry.operations).length >= 32) throw new Error("Harness action answer window is full");
    const responder = this.responders.get(key);
    const status: HarnessActionStatusData = { version: 1, operationId: event.id, requestId: answer.requestId, origin: structuredClone(answer.origin),
      status: !harnessActionAcceptsAnswer(entry.action, answer) ? "rejected" : Object.values(entry.operations).some(receipt => ["requested", "unknown"].includes(receipt.status)) ? "unknown"
        : !responder?.current() ? "no-longer-needed" : "requested" };
    (entry.answers ??= Object.create(null))[event.id] = answerKey(answer); entry.operations[event.id] = status; this.save(); this.projectAction(entry);
    if (status.status !== "requested") return;
    // Durable intent precedes exactly one native call. A lost result is never permission to retry.
    try { Object.assign(status, await responder!.respond(answer)); }
    catch { status.status = "unknown"; status.reason = "The harness answer outcome is unconfirmed. It will not be sent again automatically."; }
    const settled = parseHarnessActionStatus(status);
    if (settled.status === "applied") { entry.action.state = "resolved"; this.responders.delete(key); }
    if (settled.status === "unknown") this.responders.delete(key);
    this.save(); this.projectAction(entry);
  }
  acceptMessage(origin: HarnessOrigin, nativeMessageId: string, toAgentId: string, text: string, requestedExchangeId?: string): AgentExchangeData {
    if (this.broken) throw new Error("Agent message journal is unconfirmed");
    if (!id(nativeMessageId) || !id(toAgentId) || !text.trim() || text.length > 32_768 || text.includes("\0")) throw new Error("Invalid agent message");
    const messageId = `agent-message-${harnessDigest([origin.agentId, nativeMessageId]).slice(0, 48)}`;
    const prior = this.journal.messages[messageId];
    if (prior) {
      if (harnessDigest(originKey(prior.message.origin)) !== harnessDigest(originKey(origin)) || prior.message.toAgentId !== toAgentId || prior.message.text !== text
        || requestedExchangeId !== undefined && prior.message.exchangeId !== requestedExchangeId) throw new Error("Agent message identity conflict");
      return structuredClone(prior.message);
    }
    if (Object.keys(this.journal.messages).length >= MAX_MESSAGES) throw new Error("Agent mailbox is full; existing messages are retained");
    let exchangeId = `exchange-${harnessDigest([origin.agentId, nativeMessageId]).slice(0, 48)}`;
    if (requestedExchangeId !== undefined) {
      if (!id(requestedExchangeId) || !Object.values(this.journal.messages).some(({ message }) => message.exchangeId === requestedExchangeId
        && [message.fromAgentId, message.toAgentId].includes(origin.agentId) && [message.fromAgentId, message.toAgentId].includes(toAgentId))) throw new Error("Unknown peer exchange");
      exchangeId = requestedExchangeId;
    }
    const message = parseAgentExchange({ version: 1, exchangeId, messageId, deliveryId: `delivery-${harnessDigest(messageId).slice(0, 48)}`,
      origin, fromAgentId: origin.agentId, toAgentId, text, createdAt: Date.now() });
    this.journal.messages[messageId] = { message, receipt: { version: 1, exchangeId, messageId, deliveryId: message.deliveryId, delivery: "accepted", execution: "not-started" } };
    this.save(); this.projectExchange(this.journal.messages[messageId]); return structuredClone(message);
  }
  pendingFor(agentId: string): AgentExchangeData[] {
    return Object.values(this.journal.messages).filter(e => e.message.toAgentId === agentId && e.receipt.delivery === "accepted" && !e.receipt.attemptId).map(e => structuredClone(e.message));
  }
  beginDelivery(messageId: string): string {
    const entry = this.journal.messages[messageId];
    if (!entry || entry.receipt.delivery !== "accepted" || entry.receipt.attemptId) throw new Error("Message admission is already attempted or unconfirmed");
    delete entry.receipt.handoff; delete entry.receipt.reason;
    entry.receipt.attemptId = randomUUID(); parseAgentExchangeStatus(entry.receipt); this.save(); this.projectExchange(entry); return entry.receipt.attemptId;
  }
  settleDelivery(messageId: string, attemptId: string, delivery: "delivered" | "rejected" | "unknown" | "accepted", reason?: string, notSubmitted = false): void {
    const entry = this.journal.messages[messageId];
    if (!entry || entry.receipt.attemptId !== attemptId) throw new Error("Stale adapter inbox receipt");
    entry.receipt.delivery = delivery; entry.receipt.execution = delivery === "unknown" || delivery === "delivered" ? "unknown" : "not-started";
    delete entry.receipt.handoff; delete entry.receipt.reason;
    if (reason) entry.receipt.reason = reason.slice(0, 512);
    if (notSubmitted) { entry.receipt.handoff = "not-submitted"; if (delivery === "accepted") delete entry.receipt.attemptId; }
    parseAgentExchangeStatus(entry.receipt); this.save(); this.projectExchange(entry);
  }
  private projectExchange(entry: Exchange): void {
    try { this.projectExchangeEvents(entry); } catch { /* Durable custody remains authoritative. */ }
  }
  private projectExchangeEvents(entry: Exchange): void {
    const threadId = exchangeThreadId(entry.message.exchangeId);
    const historyRoot = safeAgentPath(join(this.root, "exchange-history")); mkdirSync(historyRoot, { recursive: true, mode: 0o700 });
    createThread("Agent exchange", this.dir, threadId, { agent: "harness", cwd: historyRoot });
    this.emit?.({ id: entry.message.messageId, threadId, agentId: "main", ts: entry.message.createdAt, kind: "agent_exchange", data: structuredClone(entry.message) });
    this.emit?.({ id: `agent-exchange-status-${harnessDigest(entry.message.deliveryId)}`, threadId, agentId: "main", ts: Date.now(), kind: "agent_exchange_status", data: structuredClone(entry.receipt) });
    this.changed?.();
  }
  exchangeSummary(threadId: string): { version: 1; exchangeId: string; fromAgentId: string; toAgentId: string } | undefined {
    const entry = Object.values(this.journal.messages).find(e => exchangeThreadId(e.message.exchangeId) === threadId);
    if (entry) return { version: 1, exchangeId: entry.message.exchangeId, fromAgentId: entry.message.fromAgentId, toAgentId: entry.message.toAgentId };
  }
  senderReceiptUnknown(origin: HarnessOrigin, nativeMessageId: string): void {
    const entry = this.journal.messages[`agent-message-${harnessDigest([origin.agentId, nativeMessageId]).slice(0, 48)}`];
    if (!entry || harnessDigest(originKey(entry.message.origin)) !== harnessDigest(originKey(origin))) return;
    entry.receipt.reason = "The originating harness did not confirm its send receipt. Recipient delivery is recorded independently.";
    this.save(); this.projectExchange(entry);
  }
}
