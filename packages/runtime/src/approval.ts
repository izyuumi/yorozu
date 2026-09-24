/**
 * The approval engine. Technically unrestricted: the model decides whether it wants to act,
 * and this file decides whether it may. When the user explicitly enables YOLO mode, it bypasses
 * ordinary approval policy but never the hard financial floor. Otherwise three things stand in
 * the way — the floor set at onboarding;
 * the classes of action that always need a fresh answer; and the rules themselves, which are the
 * user's own standing decisions rather than anything inferred. See docs/spec-v1.html section 6
 * and docs/spec-v1.5.md.
 */

import { createHash, randomUUID } from "node:crypto";
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { isAbsolute, join, relative, resolve } from "node:path";
import {
  APPROVAL_SCOPE_FIELDS,
  CONTENT_SUMMARY_MAX,
  type ApprovalAnswerData,
  type ApprovalCardData,
  type ApprovalRule,
  type ApprovalRuleField,
  type ApprovalScope,
  type ApprovalScopeField,
  type BatchItem,
} from "@yorozu/shared";
import type { Tool, TurnContext } from "./index.js";
import { stateDir } from "./memory.js";
import { expandHome } from "./tools/shell.js";

/** Every external effect a tool can have, split so unrelated standing rules cannot overlap. */
export const ACTION_CLASSES = [
  "send-message",
  "purchase",
  "delete-file",
  "book",
  "transfer-money",
  "run-command",
  "edit-file",
  "interact-web",
  "interact-app",
  "edit-calendar",
  "edit-reminder",
  "visit-url",
] as const;

export type ActionClass = (typeof ACTION_CLASSES)[number];

/**
 * Classes that are allowed unless a rule says otherwise. Every other class asks. Reading a
 * URL is the one: gating it makes "every network write is gated" true and lets a `never`
 * rule fence off a host, without a card on every page the agent reads.
 */
export const DEFAULT_ALLOW_CLASSES: readonly ActionClass[] = ["visit-url"];

/**
 * A URL that looks like it commits on arrival: a magic-link login, a one-click unsubscribe,
 * a confirmation endpoint. A GET like this is an action the server takes on the agent's
 * behalf, so it is always asked about fresh, whatever the default and whatever rule stands.
 */
const COMMITTING_URL =
  /[?&](token|key|code|auth|otp|sig|signature|nonce|ticket)=|\/(confirm|verify|unsubscribe|activate|reset|magic|login|auth)(\/|\?|#|$)/i;

export const looksCommitting = (url: string): boolean => COMMITTING_URL.test(url);

/** What is being done, independent of which tool does it. */
export const OPERATIONS = [
  "send",
  "purchase",
  "transfer",
  "book",
  "delete",
  "edit",
  "run",
  "subscribe",
  "trade",
] as const;

export type Operation = (typeof OPERATIONS)[number];

export type { ApprovalScope, BatchItem };
export { APPROVAL_SCOPE_FIELDS as SCOPE_FIELDS, CONTENT_SUMMARY_MAX };
export type ScopeField = ApprovalScopeField;

/**
 * One thing the agent is about to do, as the engine sees it: the class, the subject line, and
 * whichever of the structured fields the tool could fill in. The structured fields are what a
 * rule matches on and what the card shows, so a tool that fills in more is a tool the user can
 * write a narrower rule about.
 */
export interface Action extends ApprovalScope {
  actionClass: ActionClass;
  /** Who or what it lands on: a recipient, a path, a command, a merchant. */
  target: string;
  /** Money involved, when the class carries any. */
  amount?: number;
  /** ISO 4217 transaction currency, never inferred from device locale. */
  currency?: string;
  /** The exact items one decision covers, when the tool declared a batch. */
  items?: BatchItem[];
  /** Full-content commitment kept inside the runtime; cards show only `contentSummary`. */
  contentHash?: string;
}

/** What a tool's extractor returns: everything about an action but its class. */
export type ActionDetail = Omit<Action, "actionClass">;

/** A standing decision, global across agents. The wire type is the stored type. */
export type Rule = ApprovalRule;
export type RuleField = ApprovalRuleField;

export interface Settings {
  /** Skip ordinary approval policy, but not hard financial confirmation floors. */
  yolo: boolean;
  /**
   * Epoch milliseconds when `yolo` switches itself off. YOLO is never granted for good: the
   * runtime sets this whenever it turns it on, and `loadSettings` reads a passed one as off.
   */
  yoloUntil?: number;
  /** Ask about any action at or above this amount. */
  moneyThreshold: number;
  /** Ask before deleting anything outside the state directory. */
  confirmIrreversibleDeletes: boolean;
  rules: Rule[];
}

/**
 * One row of the append-only decision log: who did what, under which authority, and how it
 * was scoped. `ruleId` on an automatic allow is the whole of the audit trail — it is how the
 * user finds out which rule authorized something and what to revoke to stop it.
 */
export interface LogRow {
  ts: number;
  actionClass: string;
  target: string;
  decision: string;
  /** The structured scope the decision was made against. */
  scope?: ApprovalScope & { amount?: number; currency?: string };
  /** Set when a rule decided this without asking. */
  ruleId?: string;
  /** Who was acting. Recorded, but never matched on: rules are global. */
  agentId?: string;
  threadId?: string;
}

export type Answer = ApprovalAnswerData["answer"];

/** What the user said, and what came back with it. */
export interface AskResult {
  answer: Answer;
  /** The rule the card's editor produced, sent with `always`. */
  rule?: Rule;
  /** Legacy: a target the user named in prose, which narrows an `always` to it. */
  target?: string;
}

/** Presents the card and waits for the answer. Supplied by the sidecar. */
export type AskFn = (action: Action, context?: TurnContext) => Promise<AskResult>;

export type Verdict = "allow" | "ask" | "deny";

/** A verdict and the authority behind it, which is what the log records. */
export interface Decision {
  verdict: Verdict;
  /** The rule that decided, when one did. */
  ruleId?: string;
}

/** How many matching approvals it takes before a rule is *proposed*. It is never applied. */
export const PRECEDENT = 3;

/** How far back those approvals are counted. */
export const PROPOSAL_WINDOW_MS = 30 * 24 * 60 * 60 * 1000;

/** What a prefilled cap allows over the amount in front of the user. */
export const CAP_HEADROOM = 1.5;

/**
 * Operations no stored rule may stand in for: the money is gone, committed or recurring the
 * moment they run, so each one gets a fresh answer however many times it has been allowed.
 */
export const ALWAYS_CONFIRM_OPERATIONS: readonly Operation[] = ["subscribe", "transfer", "trade"];

/** Categories under the same standing rule, whatever operation carries them. */
export const ALWAYS_CONFIRM_CATEGORIES = ["crypto"];

export const DEFAULT_SETTINGS: Settings = {
  yolo: false,
  moneyThreshold: 0,
  confirmIrreversibleDeletes: true,
  rules: [],
};

/** How long YOLO stays on when nobody says: one working day, not a week of forgetting. */
export const YOLO_DEFAULT_HOURS = 8;
/** The most any one grant can ask for. Longer is turning it on again tomorrow. */
export const YOLO_MAX_HOURS = 24;

/**
 * The hours a YOLO grant asked for, as granted: default 8, capped at 24, whole hours (the
 * devices carry an integer), nonsense is the default.
 */
export function yoloHours(hours?: number): number {
  const asked = typeof hours === "number" && Number.isFinite(hours) && hours > 0 ? hours : YOLO_DEFAULT_HOURS;
  return Math.min(Math.ceil(asked), YOLO_MAX_HOURS);
}

/** When a YOLO grant of `hours` ends. */
export function yoloExpiry(hours?: number, now = Date.now()): number {
  return now + yoloHours(hours) * 3_600_000;
}

const settingsFile = (dir: string): string => join(dir, "approval.json");
const logFile = (dir: string): string => join(dir, "approvals.jsonl");

/**
 * Rules older than the structured scope are `{ actionClass, target?, decision }` with no id.
 * Read forward into the current shape rather than migrated on disk: the file stays the
 * hand-editable thing it was, and a rule written by hand today still works without an id.
 */
export function normalizeRule(stored: Partial<Rule> & { target?: string }, index = 0): Rule | null {
  if (typeof stored.actionClass !== "string") return null;
  if (stored.decision !== "never" && stored.decision !== "always") return null;
  if (stored.scope && Object.keys(stored.scope).some(
    (field) => !(APPROVAL_SCOPE_FIELDS as readonly string[]).includes(field),
  )) return null;
  const scope: Partial<Record<ScopeField, RuleField>> = {};
  for (const field of APPROVAL_SCOPE_FIELDS) {
    const pattern = stored.scope?.[field];
    if (pattern && typeof pattern.value === "string" && pattern.value.trim() !== "") {
      scope[field] = {
        mode: pattern.mode === "prefix" || pattern.mode === "glob" ? pattern.mode : "exact",
        value: pattern.value,
      };
    }
  }
  // The old class-plus-target rule is exactly a rule whose only pattern is on `target`.
  if (!scope.target && typeof stored.target === "string" && stored.target !== "") {
    scope.target = { mode: "exact", value: stored.target };
  }
  return {
    id: typeof stored.id === "string" && stored.id ? stored.id : `legacy-${index}`,
    actionClass: stored.actionClass,
    decision: stored.decision,
    ...(Object.keys(scope).length ? { scope } : {}),
    ...(typeof stored.maxAmount === "number" && Number.isFinite(stored.maxAmount) && stored.maxAmount >= 0
      ? { maxAmount: stored.maxAmount }
      : {}),
    ...(typeof stored.currency === "string" ? { currency: stored.currency } : {}),
    ...(stored.enabled === false ? { enabled: false } : {}),
    ...(typeof stored.createdAt === "number" ? { createdAt: stored.createdAt } : {}),
    ...(typeof stored.lastUsed === "number" ? { lastUsed: stored.lastUsed } : {}),
    ...(typeof stored.useCount === "number" ? { useCount: stored.useCount } : {}),
  };
}

/**
 * Hand-editable, like every other file the runtime keeps: unknown keys and bad types default.
 * A YOLO grant whose `yoloUntil` has passed, or that has none, is reported off, whatever the
 * file says.
 */
export function loadSettings(dir = stateDir(), now = Date.now()): Settings {
  try {
    const stored = JSON.parse(readFileSync(settingsFile(dir), "utf8")) as Partial<Settings>;
    const until = typeof stored.yoloUntil === "number" && Number.isFinite(stored.yoloUntil)
      ? stored.yoloUntil
      : undefined;
    // No expiry, no grant: a `yolo: true` written by hand or by an older runtime is not
    // carried over for good, it has to be granted again and given an end.
    const yolo = stored.yolo === true && until !== undefined && until > now;
    return {
      yolo,
      ...(yolo && until !== undefined ? { yoloUntil: until } : {}),
      moneyThreshold:
        typeof stored.moneyThreshold === "number"
          ? stored.moneyThreshold
          : DEFAULT_SETTINGS.moneyThreshold,
      confirmIrreversibleDeletes:
        typeof stored.confirmIrreversibleDeletes === "boolean"
          ? stored.confirmIrreversibleDeletes
          : DEFAULT_SETTINGS.confirmIrreversibleDeletes,
      rules: Array.isArray(stored.rules)
        ? stored.rules.map((rule, i) => normalizeRule(rule, i)).filter((r): r is Rule => r !== null)
        : [],
    };
  } catch {
    // No file yet, or one someone broke by hand: the safe floor is the default one.
    return { ...DEFAULT_SETTINGS, rules: [] };
  }
}

export function saveSettings(settings: Settings, dir = stateDir()): void {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  writeFileSync(settingsFile(dir), `${JSON.stringify(settings, null, 2)}\n`, { mode: 0o600 });
}

export const listRules = (dir = stateDir()): Rule[] => loadSettings(dir).rules;

/** Saves a rule: a new one, or the edited form of the one with the same id. */
export function addRule(rule: Rule, dir = stateDir()): void {
  const settings = loadSettings(dir);
  const rules = settings.rules.filter((existing) => existing.id !== rule.id);
  saveSettings({ ...settings, rules: [...rules, rule] }, dir);
}

/** True when a rule with that id was there to revoke. */
export function deleteRule(ruleId: string, dir = stateDir()): boolean {
  const settings = loadSettings(dir);
  const rules = settings.rules.filter((rule) => rule.id !== ruleId);
  if (rules.length === settings.rules.length) return false;
  saveSettings({ ...settings, rules }, dir);
  return true;
}

/** What Settings shows about a rule: when it last authorized something, and how often. */
export function markRuleUsed(ruleId: string, dir = stateDir(), now = Date.now()): void {
  const settings = loadSettings(dir);
  const rule = settings.rules.find((candidate) => candidate.id === ruleId);
  if (!rule) return;
  rule.lastUsed = now;
  rule.useCount = (rule.useCount ?? 0) + 1;
  saveSettings(settings, dir);
}

export function appendLog(row: LogRow, dir = stateDir()): void {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  appendFileSync(logFile(dir), `${JSON.stringify(row)}\n`, { mode: 0o600 });
}

/** The whole log, oldest first. Unreadable lines are skipped, as in the transcripts. */
export function readLog(dir = stateDir()): LogRow[] {
  let text: string;
  try {
    text = readFileSync(logFile(dir), "utf8");
  } catch {
    return [];
  }
  const rows: LogRow[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      rows.push(JSON.parse(line) as LogRow);
    } catch {
      // A half-written last line must not lose the history before it.
    }
  }
  return rows;
}

/** True when `target` is the state directory or something inside it. */
function insideDir(target: string, dir: string): boolean {
  const rel = relative(resolve(dir), resolve(expandHome(target)));
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

/**
 * Actions that always get a fresh answer, whatever is stored: subscriptions, transfers,
 * securities trades and crypto. A rule can make routine shopping unattended; it cannot make
 * a recurring charge or a movement of money unattended, because those are the ones a wrong
 * scope is expensive on and the ones the user would want to have seen.
 */
export function needsFreshConfirmation(
  action: Pick<Action, "actionClass" | "operation" | "category"> & Partial<Pick<Action, "target">>,
): boolean {
  // Generic browser mechanics cannot prove which real-world commit a page will perform. They
  // therefore never inherit standing authority or YOLO mode: each interaction is approved once.
  if (action.actionClass === "interact-web" || action.actionClass === "interact-app") return true;
  if (action.actionClass === "transfer-money") return true;
  // Reading a page is routine; a URL that commits on arrival is not, whatever rule stands.
  if (action.actionClass === "visit-url" && looksCommitting(action.target ?? "")) return true;
  if (action.operation && ALWAYS_CONFIRM_OPERATIONS.includes(action.operation)) return true;
  return ALWAYS_CONFIRM_CATEGORIES.includes((action.category ?? "").toLowerCase());
}

/**
 * The two onboarding settings, plus the always-confirm classes. Code-enforced and deliberately
 * unreachable by a rule: the point of the floor is that "never ask me again" cannot spend the
 * user's money or delete their files for them.
 */
export function hitsFloor(action: Action, settings: Settings, dir = stateDir()): boolean {
  if (needsFreshConfirmation(action)) return true;
  if (action.amount !== undefined && action.amount >= settings.moneyThreshold) return true;
  return (
    settings.confirmIrreversibleDeletes &&
    action.actionClass === "delete-file" &&
    !insideDir(action.target, dir)
  );
}

/**
 * Classes that commit something outside this Mac: a message somebody receives, money that
 * moves, a reservation held. Answering one of these deserves the card, not a lock-screen
 * button that shows two lines of it.
 */
const EXTERNAL_CLASSES: readonly ActionClass[] = ["send-message", "purchase", "book", "transfer-money"];

/**
 * Whether an approval may be answered from the notification itself, without opening the app.
 * Only an action below every floor and with no external commitment qualifies: a local file
 * edit, a command, a calendar change, a page read. Everything else gets a Review button.
 */
export function quickApprovable(action: Action, settings: Settings, dir = stateDir()): boolean {
  return !hitsFloor(action, settings, dir) && !EXTERNAL_CLASSES.includes(action.actionClass);
}

/** The value of one scope field on an action, as a string. `target` lives on the action itself. */
export const scopeValue = (action: Action, field: ScopeField): string | undefined => {
  const value = action[field];
  return value === undefined || value === "" ? undefined : String(value);
};

/** `*` for any run of characters, `?` for one. Everything else is literal. */
const globToRegExp = (pattern: string): RegExp =>
  new RegExp(
    `^${pattern.replace(/[.*+?^${}()|[\]\\]/g, (c) => (c === "*" ? "[\\s\\S]*" : c === "?" ? "[\\s\\S]" : `\\${c}`))}$`,
  );

/**
 * One field against one pattern. Case-insensitive throughout: an address, a merchant name and
 * a macOS path are all things the user would be surprised to see a rule miss on capitalisation.
 */
export function matchField(pattern: RuleField, value: string): boolean {
  const [p, v] = [pattern.value.toLowerCase(), value.toLowerCase()];
  if (pattern.mode === "prefix") return v.startsWith(p);
  if (pattern.mode === "glob") return globToRegExp(p).test(v);
  return v === p;
}

/**
 * Whether a rule covers an action. The agent taking it is not consulted: rules are global, so
 * delegating work does not change what is authorized. A field the rule constrains but the
 * action does not carry is a miss — a rule about a recipient says nothing about an action that
 * has none.
 */
export function matchesRule(rule: Rule, action: Action): boolean {
  if (rule.enabled === false) return false;
  if (rule.actionClass !== action.actionClass) return false;
  for (const field of APPROVAL_SCOPE_FIELDS) {
    const pattern = rule.scope?.[field];
    if (!pattern) continue;
    const value = scopeValue(action, field);
    if (value === undefined || !matchField(pattern, value)) return false;
  }
  // Caps compare amounts only in the same units. Legacy unspecified caps remain unspecified.
  // A legacy denial must not disappear and expose a broader allowance after an upgrade.
  const legacyDenial = rule.decision === "never" && rule.currency === undefined;
  if (!legacyDenial && (rule.currency !== undefined || rule.maxAmount !== undefined)
    && rule.currency !== action.currency) return false;
  if (rule.maxAmount !== undefined && !(action.amount !== undefined && action.amount <= rule.maxAmount)) {
    return false;
  }
  return true;
}

/** How many things a rule pins down. */
export const specificity = (rule: Rule): number =>
  Object.keys(rule.scope ?? {}).length + (rule.maxAmount === undefined ? 0 : 1);

/**
 * Floor first, then the most-specific matching rules. A deny wins only when tied with an allow
 * at that specificity. Nothing is inferred from history here — repeated approvals produce a
 * *proposal* (see `proposalFor`), never an automatic allow.
 */
export function decide(action: Action, settings: Settings, dir = stateDir()): Decision {
  if (hitsFloor(action, settings, dir)) return { verdict: "ask" };

  const matching = settings.rules.filter((rule) => matchesRule(rule, action));
  const top = Math.max(...matching.map(specificity), -1);
  const mostSpecific = matching.filter((rule) => specificity(rule) === top);
  const denied = mostSpecific.find((rule) => rule.decision === "never");
  if (denied) return { verdict: "deny", ruleId: denied.id };
  const allowed = mostSpecific.find((rule) => rule.decision === "always");
  if (allowed) return { verdict: "allow", ruleId: allowed.id };
  return { verdict: DEFAULT_ALLOW_CLASSES.includes(action.actionClass) ? "allow" : "ask" };
}

export const decideFromDisk = (action: Action, dir = stateDir()): Decision =>
  decide(action, loadSettings(dir), dir);

/**
 * The fields that say *who* an action lands on. `target` is left out when any of these is
 * present, because the target of a purchase is the item and the target of a message is its
 * subject — pinning those makes a rule that covers one action and never fires again.
 *
 * `operation` is not among them on purpose: it says what kind of thing this is, not which one,
 * so a rule scoped on it alone would authorize every command or every payment. It is added as
 * an extra constraint below, never as the only one.
 */
const IDENTIFYING: ScopeField[] = ["recipient", "account", "merchant", "category"];

/**
 * The narrowest rule that would cover this action: what "Always allow" opens its editor with,
 * and what a proposal offers. Deliberately the narrow end — the editor lets the user widen a
 * field to "any", which is a decision they take rather than one taken for them.
 */
export function narrowestRule(action: Action, headroom = CAP_HEADROOM, now = Date.now()): Rule {
  const scope: Partial<Record<ScopeField, RuleField>> = {};
  for (const field of IDENTIFYING) {
    const value = scopeValue(action, field);
    if (value !== undefined) scope[field] = { mode: "exact", value };
  }
  // Nothing identifying: the target is all the action has to be narrow about.
  if (!Object.keys(scope).length) {
    const target = scopeValue(action, "target");
    if (target !== undefined) scope.target = { mode: "exact", value: target };
  }
  const operation = scopeValue(action, "operation");
  if (operation !== undefined) scope.operation = { mode: "exact", value: operation };
  return {
    id: randomUUID(),
    actionClass: action.actionClass,
    decision: "always",
    ...(Object.keys(scope).length ? { scope } : {}),
    ...(action.amount !== undefined
      ? { maxAmount: Math.ceil(action.amount * headroom * 100) / 100 }
      : {}),
    ...(action.currency !== undefined ? { currency: action.currency } : {}),
    createdAt: now,
  };
}

/** Two rules cover the same ground: same class, same patterns, same cap. */
const sameScope = (a: Rule, b: Rule): boolean =>
  a.actionClass === b.actionClass &&
  a.currency === b.currency &&
  JSON.stringify(a.scope ?? {}) === JSON.stringify(b.scope ?? {});

/**
 * Repeated approvals, offered back as a rule. `PRECEDENT` explicit yeses whose scope the
 * proposed rule covers, inside `PROPOSAL_WINDOW_MS`, and no stored rule covering it already.
 * Returns the rule to propose, or null. Nothing here writes anything: a proposal is a card.
 */
export function proposalFor(
  action: Action,
  settings: Settings,
  log: LogRow[],
  now = Date.now(),
): Rule | null {
  const rule = narrowestRule(action, CAP_HEADROOM, now);
  // Already covered — by this rule or a wider one — so there is nothing to propose.
  if (settings.rules.some((stored) => matchesRule(stored, action) || sameScope(stored, rule))) {
    return null;
  }
  const matching = log.filter((row) => {
    if (row.ts < now - PROPOSAL_WINDOW_MS) return false;
    if (row.decision !== "yes" && row.decision !== "task") return false;
    return matchesRule(rule, {
      actionClass: row.actionClass as ActionClass,
      target: row.target,
      ...row.scope,
    });
  });
  return matching.length >= PRECEDENT ? rule : null;
}

/**
 * A grant that lasts one turn: the same class and scope, for the rest of this turn tree
 * including everything it delegates to, and gone when the turn ends because the object does.
 * Held in memory on purpose — a bounded grant that outlived its turn would be a rule, and
 * writing rules is something only the editor does.
 */
export class TaskGrants {
  private readonly granted: Rule[] = [];

  /** Grants the action's own scope exactly: no headroom, so a larger amount asks again. */
  grant(action: Action): void {
    this.granted.push(narrowestRule(action, 1));
  }

  covers(action: Action): boolean {
    return this.granted.some((rule) => matchesRule(rule, action));
  }

  get size(): number {
    return this.granted.length;
  }
}

/** The exact item list, as one short string. Any addition or edit changes it. */
export const batchHash = (items: BatchItem[]): string =>
  createHash("sha256")
    .update(JSON.stringify(items.map((item) => [item.label, item.detail ?? ""])))
    .digest("hex")
    .slice(0, 16);

/**
 * The fields that describe the transaction rather than the intent. A change to any of them
 * between the card and the moment of execution means the user approved something else.
 */
const COMMITTED_FIELDS = [
  "target",
  "operation",
  "amount",
  "currency",
  "quantity",
  "recipient",
  "account",
  "contentSummary",
  "contentHash",
] as const;

interface Approved {
  action: Action;
  itemsHash?: string;
}

/**
 * What has actually been approved, by action id, for the life of the process. A tool calls
 * `verifyApproved` with the values it is about to commit; anything that moved since the card
 * was answered invalidates the approval rather than being committed under it.
 */
const approved = new Map<string, Approved>();

export function recordApproval(actionId: string, action: Action): void {
  approved.set(actionId, {
    action,
    ...(action.items ? { itemsHash: batchHash(action.items) } : {}),
  });
}

/** Test seam: the registry is process-wide, so a test that fills it has to be able to empty it. */
export const forgetApprovals = (): void => approved.clear();

/**
 * The check a tool makes before it commits. Returns null when the approval still stands, or
 * the text to hand the model instead of committing — which sends it back through the gate
 * with the values it actually means to use.
 */
export function verifyApproved(
  actionId: string,
  final: Partial<Action> & { items?: BatchItem[] },
): string | null {
  const record = approved.get(actionId);
  if (!record) {
    return (
      "not allowed: this action has no live approval, so it must not be committed. " +
      "Present it for approval again before retrying."
    );
  }
  const changed: string[] = [];
  for (const field of COMMITTED_FIELDS) {
    const value = final[field];
    // A final amount is meaningful only in its approved units; other partial checks may
    // omit both amount and currency without claiming that the denomination changed.
    const provided = field === "currency"
      ? Object.hasOwn(final, field) || final.amount !== undefined
      : value !== undefined;
    if (provided && value !== record.action[field]) {
      changed.push(`${field} is now ${String(value)}, not ${String(record.action[field])}`);
    }
  }
  if (final.items && batchHash(final.items) !== record.itemsHash) {
    changed.push("the list of items is not the one that was approved");
  }
  if (!changed.length) return null;
  // Spent: the next attempt has to be a fresh card, not this id again.
  approved.delete(actionId);
  return (
    `not allowed: what was approved has changed — ${changed.join("; ")}. ` +
    "The approval does not cover it. Present the action again with the final values."
  );
}

/** Arguments the common tools carry their target in, when a tool declares no extractor. */
export const defaultAction = (args: Record<string, unknown>): ActionDetail => ({
  target: String(args.target ?? args.path ?? args.cmd ?? args.to ?? ""),
});

/** Truncated display value. Exact commit verification uses `hashContent`. */
export const summarize = (text: string): string => text.slice(0, CONTENT_SUMMARY_MAX);

/** Opaque full-content commitment: detects changes beyond the card's display limit. */
export const hashContent = (text: string): string =>
  createHash("sha256").update(text).digest("hex");

const refusal = (action: Action): string =>
  `not allowed: the user declined this ${action.actionClass} on ${action.target}. ` +
  "Do not retry it. Tell them what you were about to do and continue without it.";

const discussNote = (action: Action): string =>
  `The user chose Discuss for this ${action.actionClass} on ${action.target}, so it is still ` +
  "pending and has not run. Explain in plain language what it would do, why you want to take " +
  "it, and what the alternatives are. Then call the tool again to present the card once more.";

/** Builds the card for an action, prefilled editor and all. Shared with the sidecar's `ask`. */
export function cardFor(actionId: string, action: Action): ApprovalCardData {
  const { actionClass, target, amount, currency, items, contentHash: _contentHash, ...scope } = action;
  const hasScope = Object.values(scope).some((value) => value !== undefined && value !== "");
  return {
    actionId,
    actionClass,
    target,
    ...(amount !== undefined ? { amount } : {}),
    ...(currency !== undefined ? { currency } : {}),
    ...(hasScope ? { scope } : {}),
    ...(items?.length ? { items } : {}),
    ...(needsFreshConfirmation(action) ? { mustConfirm: true } : {}),
    // No rule is offered for a batch. A decision on a batch is a decision about exactly these
    // items, and no standing rule can mean that — the narrowest one that would cover it either
    // pins the list, and so fires once and never again, or drops it and quietly authorises
    // every future batch. The card offers the two grants that can honestly be scoped instead.
    ...(items?.length || needsFreshConfirmation(action) ? {} : { suggestedRule: narrowestRule(action) }),
  };
}

/** What the gate decided, and the handle a tool needs to prove it before committing. */
export interface ApprovalOutcome {
  /** Text to hand the model in place of the tool's result, or null to let the call proceed. */
  refusal: string | null;
  /** The id the approval was recorded under; what the tool passes to `verifyApproved`. */
  actionId?: string;
}

/** Everything `checkApproval` needs beyond the tool call itself. */
export interface GateOptions {
  ask: AskFn;
  context?: TurnContext;
  /** This turn's bounded grants. Absent means "Allow for this task" was never used. */
  grants?: TaskGrants;
  /** Raised when repeated approvals add up to a rule worth offering. Never applies it. */
  onProposal?(rule: Rule, approvals: number, context?: TurnContext): void;
  dir?: string;
}

/**
 * The gate every tool call with an `actionClass` passes through. Returns the text to hand the
 * model in place of the tool's result, or a null refusal and the action id the tool proves its
 * approval with.
 */
export async function checkApproval(
  tool: Tool,
  args: Record<string, unknown>,
  options: GateOptions,
): Promise<ApprovalOutcome> {
  if (!tool.actionClass) return { refusal: null };
  const dir = options.dir ?? stateDir();
  const action: Action = {
    actionClass: tool.actionClass,
    ...(tool.action ?? defaultAction)(args),
    ...(tool.batch ? { items: tool.batch(args) } : {}),
  };
  const actionId = randomUUID();
  const log = (decision: string, ruleId?: string): void => {
    const { actionClass, target, items, contentHash: _contentHash, ...scope } = action;
    appendLog(
      {
        ts: Date.now(),
        actionClass,
        target,
        decision,
        ...(Object.keys(scope).length ? { scope } : {}),
        ...(ruleId ? { ruleId } : {}),
        ...(options.context ? { agentId: options.context.agentId, threadId: options.context.threadId } : {}),
      },
      dir,
    );
  };
  const allow = (): ApprovalOutcome => {
    recordApproval(actionId, action);
    return { refusal: null, actionId };
  };

  const settings = loadSettings(dir);
  const floored = hitsFloor(action, settings, dir);
  if (settings.yolo && !floored) {
    log("yolo");
    return allow();
  }

  // A bounded grant is this turn's own answer to this exact scope, so it stands in for the
  // card — but not for the floor, which is the one thing no grant and no rule reaches past.
  if (!floored && options.grants?.covers(action)) {
    log("task-grant");
    return allow();
  }

  const { verdict, ruleId } = decide(action, settings, dir);
  if (verdict === "allow") {
    // The audit trail's whole point: the row says which rule authorized this, so the user can
    // find it in Settings and revoke it.
    log("auto", ruleId);
    if (ruleId) markRuleUsed(ruleId, dir);
    return allow();
  }
  if (verdict === "deny") {
    log("denied", ruleId);
    return { refusal: refusal(action) };
  }

  const { answer, rule } = await options.ask(action, options.context);
  // Discuss decides nothing, so nothing is logged: the card comes back after the explanation.
  if (answer === "discuss") return { refusal: discussNote(action) };

  log(answer);

  if (answer === "task") options.grants?.grant(action);
  if (answer === "always") {
    const keys = Object.keys(rule?.scope ?? {});
    const recognized = keys.filter((key): key is ScopeField =>
      (APPROVAL_SCOPE_FIELDS as readonly string[]).includes(key),
    );
    const scoped =
      rule &&
      keys.length === recognized.length &&
      recognized.some((key) => {
        const field = rule.scope?.[key];
        return field && field.value.trim() !== "";
      });
    if (
      floored ||
      action.items?.length ||
      !scoped ||
      rule.actionClass !== action.actionClass ||
      (rule.decision !== "always" && rule.decision !== "never") ||
      !matchesRule(rule, action)
    ) {
      return {
        refusal:
          "not allowed: permanent authority requires you to review and save a scoped rule. " +
          "This action has not run; use Allow once or open Always allow and choose its scope.",
      };
    }
    addRule(rule, dir);
    if (rule.decision === "never") return { refusal: refusal(action) };
  }
  if (answer !== "yes" && answer !== "task" && answer !== "always") return { refusal: refusal(action) };

  // A plain yes three times over is worth offering as a rule, and never worth applying as one.
  if (answer === "yes" && options.onProposal) {
    const proposal = proposalFor(action, loadSettings(dir), readLog(dir));
    if (proposal) options.onProposal(proposal, PRECEDENT, options.context);
  }
  return allow();
}
