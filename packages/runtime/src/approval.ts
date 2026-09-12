/**
 * The approval engine. Technically unrestricted: the model decides whether it wants to act,
 * and this file decides whether it may. Two things stand in the way — the floor the user set
 * at onboarding, which no rule can override, and the decision log, which learns.
 * See docs/spec-v1.html section 6.
 */

import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { isAbsolute, join, relative, resolve } from "node:path";
import type { ApprovalAnswerData } from "@yorozu/shared";
import type { Tool, TurnContext } from "./index.js";
import { stateDir } from "./memory.js";
import { expandHome } from "./tools/shell.js";

/** Every external effect a tool can have. The spec's list, verbatim. */
export const ACTION_CLASSES = [
  "send-message",
  "purchase",
  "delete-file",
  "book",
  "transfer-money",
  "run-command",
  "edit-file",
] as const;

export type ActionClass = (typeof ACTION_CLASSES)[number];

/** One thing the agent is about to do, as the engine sees it. */
export interface Action {
  actionClass: ActionClass;
  /** Who or what it lands on: a recipient, a path, a command, a merchant. */
  target: string;
  /** Money involved, when the class carries any. */
  amount?: number;
}

/** A permanent decision. Class-level unless the user named a target. */
export interface Rule {
  actionClass: string;
  target?: string;
  /** The card only ever writes `always`; a `never` is honoured but has to be hand-written. */
  decision: "never" | "always";
}

export interface Settings {
  /** Ask about any action at or above this amount. */
  moneyThreshold: number;
  /** Ask before deleting anything outside the state directory. */
  confirmIrreversibleDeletes: boolean;
  rules: Rule[];
}

/** One row of the append-only decision log. */
export interface LogRow {
  ts: number;
  actionClass: string;
  target: string;
  decision: string;
}

export type Answer = ApprovalAnswerData["answer"];

/** What the user said, plus the target they named if they typed one. */
export interface AskResult {
  answer: Answer;
  /** Set only when the user named a target, which narrows an `always` to that target. */
  target?: string;
}

/** Presents the card and waits for the answer. Supplied by the sidecar. */
export type AskFn = (action: Action, context?: TurnContext) => Promise<AskResult>;

export type Verdict = "allow" | "ask" | "deny";

/** How many consistent past answers it takes to stop asking. */
export const PRECEDENT = 3;

export const DEFAULT_SETTINGS: Settings = {
  moneyThreshold: 0,
  confirmIrreversibleDeletes: true,
  rules: [],
};

const settingsFile = (dir: string): string => join(dir, "approval.json");
const logFile = (dir: string): string => join(dir, "approvals.jsonl");

/** Hand-editable, like every other file the runtime keeps: unknown keys and bad types default. */
export function loadSettings(dir = stateDir()): Settings {
  try {
    const stored = JSON.parse(readFileSync(settingsFile(dir), "utf8")) as Partial<Settings>;
    return {
      moneyThreshold:
        typeof stored.moneyThreshold === "number"
          ? stored.moneyThreshold
          : DEFAULT_SETTINGS.moneyThreshold,
      confirmIrreversibleDeletes:
        typeof stored.confirmIrreversibleDeletes === "boolean"
          ? stored.confirmIrreversibleDeletes
          : DEFAULT_SETTINGS.confirmIrreversibleDeletes,
      rules: Array.isArray(stored.rules) ? stored.rules : [],
    };
  } catch {
    // No file yet, or one someone broke by hand: the safe floor is the default one.
    return { ...DEFAULT_SETTINGS, rules: [] };
  }
}

export function saveSettings(settings: Settings, dir = stateDir()): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(settingsFile(dir), `${JSON.stringify(settings, null, 2)}\n`);
}

export function addRule(rule: Rule, dir = stateDir()): void {
  const settings = loadSettings(dir);
  saveSettings({ ...settings, rules: [...settings.rules, rule] }, dir);
}

export function appendLog(row: LogRow, dir = stateDir()): void {
  mkdirSync(dir, { recursive: true });
  appendFileSync(logFile(dir), `${JSON.stringify(row)}\n`);
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
 * The two onboarding settings. Code-enforced and deliberately unreachable by a rule: the
 * point of the floor is that "never ask me again" cannot spend the user's money or delete
 * their files for them.
 */
export function hitsFloor(action: Action, settings: Settings, dir = stateDir()): boolean {
  if (action.amount !== undefined && action.amount >= settings.moneyThreshold) return true;
  return (
    settings.confirmIrreversibleDeletes &&
    action.actionClass === "delete-file" &&
    !insideDir(action.target, dir)
  );
}

const matches = (rule: Rule, action: Action): boolean =>
  rule.actionClass === action.actionClass &&
  (rule.target === undefined || rule.target === action.target);

/**
 * Floor first, then the permanent rules, then precedent: `PRECEDENT` consistent yeses for the
 * class and the agent acts without asking. Mixed answers or none means ask.
 */
export function decide(
  action: Action,
  settings: Settings,
  log: LogRow[],
  dir = stateDir(),
): Verdict {
  if (hitsFloor(action, settings, dir)) return "ask";

  // A rule naming this target beats the class-level one: it is the more specific promise.
  const rule = settings.rules
    .filter((candidate) => matches(candidate, action))
    .sort((a, b) => (b.target ? 1 : 0) - (a.target ? 1 : 0))[0];
  if (rule) return rule.decision === "never" ? "deny" : "allow";

  const recent = log
    .filter((row) => row.actionClass === action.actionClass)
    .slice(-PRECEDENT);
  return recent.length === PRECEDENT && recent.every((row) => row.decision === "yes")
    ? "allow"
    : "ask";
}

export const decideFromDisk = (action: Action, dir = stateDir()): Verdict =>
  decide(action, loadSettings(dir), readLog(dir), dir);

/** Arguments the common tools carry their target in, when a tool declares no extractor. */
export const defaultAction = (
  args: Record<string, unknown>,
): { target: string; amount?: number } => ({
  target: String(args.target ?? args.path ?? args.cmd ?? args.to ?? ""),
});

const refusal = (action: Action): string =>
  `not allowed: the user declined this ${action.actionClass} on ${action.target}. ` +
  "Do not retry it. Tell them what you were about to do and continue without it.";

const discussNote = (action: Action): string =>
  `The user chose Discuss for this ${action.actionClass} on ${action.target}, so it is still ` +
  "pending and has not run. Explain in plain language what it would do, why you want to take " +
  "it, and what the alternatives are. Then call the tool again to present the card once more.";

/**
 * The gate every tool call with an `actionClass` passes through. Returns null to let the call
 * proceed, or the text to hand the model in place of the tool's result.
 */
export async function checkApproval(
  tool: Tool,
  args: Record<string, unknown>,
  ask: AskFn,
  context?: TurnContext,
  dir = stateDir(),
): Promise<string | null> {
  if (!tool.actionClass) return null;
  const action: Action = {
    actionClass: tool.actionClass,
    ...(tool.action ?? defaultAction)(args),
  };

  const verdict = decideFromDisk(action, dir);
  if (verdict === "allow") return null;
  // A `never` rule left on disk by hand: asking again would break the promise it made.
  if (verdict === "deny") return refusal(action);

  const { answer, target } = await ask(action, context);
  // Discuss decides nothing, so nothing is logged: the card comes back after the explanation.
  if (answer === "discuss") return discussNote(action);

  appendLog(
    { ts: Date.now(), actionClass: action.actionClass, target: action.target, decision: answer },
    dir,
  );
  // `always` is a yes that also settles the question: the action runs and the class stops asking.
  if (answer === "always") {
    addRule(
      { actionClass: action.actionClass, decision: "always", ...(target ? { target } : {}) },
      dir,
    );
  }
  if (answer === "yes" || answer === "always") return null;
  return refusal(action);
}
