import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { beforeEach, expect, test, vi } from "vitest";
import {
  checkApproval,
  decide,
  decideFromDisk,
  DEFAULT_SETTINGS,
  hitsFloor,
  loadSettings,
  readLog,
  saveSettings,
  type Action,
  type AskResult,
  type LogRow,
  type Settings,
  type Verdict,
} from "./approval.js";
import type { Tool } from "./index.js";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-approval-"));
});

const settings = (over: Partial<Settings> = {}): Settings => ({
  ...DEFAULT_SETTINGS,
  rules: [],
  ...over,
});

/** A log of past answers for one class, oldest first. */
const log = (decisions: string[], actionClass = "send-message"): LogRow[] =>
  decisions.map((decision, i) => ({ ts: i, actionClass, target: "bob@example.com", decision }));

const send: Action = { actionClass: "send-message", target: "bob@example.com" };

test.each<[string, Action, Settings, LogRow[], Verdict]>([
  ["nothing known asks", send, settings(), [], "ask"],
  [
    "a never rule denies",
    send,
    settings({ rules: [{ actionClass: "send-message", decision: "never" }] }),
    [],
    "deny",
  ],
  [
    "an always rule allows",
    send,
    settings({ rules: [{ actionClass: "send-message", decision: "always" }] }),
    [],
    "allow",
  ],
  [
    "a rule naming the target beats the class rule",
    send,
    settings({
      rules: [
        { actionClass: "send-message", decision: "never" },
        { actionClass: "send-message", target: "bob@example.com", decision: "always" },
      ],
    }),
    [],
    "allow",
  ],
  [
    "a rule for another target does not match",
    send,
    settings({ rules: [{ actionClass: "send-message", target: "eve@example.com", decision: "never" }] }),
    [],
    "ask",
  ],
  ["three consistent yeses are precedent", send, settings(), log(["yes", "yes", "yes"]), "allow"],
  ["two yeses are not enough", send, settings(), log(["yes", "yes"]), "ask"],
  ["mixed precedent asks", send, settings(), log(["yes", "no", "yes"]), "ask"],
  ["a later no breaks the precedent", send, settings(), log(["yes", "yes", "yes", "no"]), "ask"],
  ["precedent does not cross classes", send, settings(), log(["yes", "yes", "yes"], "purchase"), "ask"],
])("decide: %s", (_name, action, stored, rows, expected) => {
  expect(decide(action, stored, rows, dir)).toBe(expected);
});

test("the money floor asks even though a never rule would have denied", () => {
  const buy: Action = { actionClass: "purchase", target: "the corner shop", amount: 50 };
  const stored = settings({
    moneyThreshold: 20,
    rules: [{ actionClass: "purchase", decision: "never" }],
  });

  expect(hitsFloor(buy, stored, dir)).toBe(true);
  expect(decide(buy, stored, [], dir)).toBe("ask");
  // Under the threshold the floor is silent and the rule decides again.
  expect(decide({ ...buy, amount: 19 }, stored, [], dir)).toBe("deny");
});

test("the delete floor covers anything outside the state directory", () => {
  const rules: Settings["rules"] = [{ actionClass: "delete-file", decision: "never" }];
  const stored = settings({ rules });

  expect(decide({ actionClass: "delete-file", target: "/etc/hosts" }, stored, [], dir)).toBe("ask");
  // Yorozu's own files are the runtime's business, so the rule still applies to them.
  expect(decide({ actionClass: "delete-file", target: join(dir, "cache", "x") }, stored, [], dir)).toBe(
    "deny",
  );
  // Switched off at onboarding, the rule decides wherever the file lives.
  expect(
    decide(
      { actionClass: "delete-file", target: "/etc/hosts" },
      settings({ confirmIrreversibleDeletes: false, rules }),
      [],
      dir,
    ),
  ).toBe("deny");
});

test("settings round-trip, and a file broken by hand falls back to the safe floor", () => {
  saveSettings(settings({ moneyThreshold: 25, confirmIrreversibleDeletes: false }), dir);
  expect(loadSettings(dir)).toMatchObject({ moneyThreshold: 25, confirmIrreversibleDeletes: false });

  writeFileSync(join(dir, "approval.json"), "{ not json");
  expect(loadSettings(dir)).toEqual(DEFAULT_SETTINGS);
});

/** Stands in for a tool with an external effect; `run` is never reached in these tests. */
const mailer: Tool = {
  name: "mail_send",
  description: "",
  parameters: {},
  actionClass: "send-message",
  action: ({ to }) => ({ target: String(to ?? "") }),
  run: () => "sent",
};

test("never writes a class rule, and the next action of that class is denied without asking", async () => {
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "never" }));

  expect(await checkApproval(mailer, { to: "bob" }, ask, undefined, dir)).toMatch(/not allowed/);
  // A different recipient, same class: the promise not to ask again has to hold.
  expect(await checkApproval(mailer, { to: "carol" }, ask, undefined, dir)).toMatch(/not allowed/);

  expect(ask).toHaveBeenCalledTimes(1);
  expect(loadSettings(dir).rules).toEqual([{ actionClass: "send-message", decision: "never" }]);
  expect(readLog(dir).map((row) => row.decision)).toEqual(["never"]);
});

test("a target the user named narrows the never rule to it", async () => {
  await checkApproval(mailer, { to: "bob" }, async () => ({ answer: "never", target: "bob" }), undefined, dir);

  expect(loadSettings(dir).rules).toEqual([
    { actionClass: "send-message", target: "bob", decision: "never" },
  ]);
  expect(decideFromDisk({ actionClass: "send-message", target: "carol" }, dir)).toBe("ask");
});

test("discuss settles nothing: no rule, no log row, and the action stays pending", async () => {
  const note = await checkApproval(mailer, { to: "bob" }, async () => ({ answer: "discuss" }), undefined, dir);

  expect(note).toMatch(/pending/);
  expect(readLog(dir)).toEqual([]);
  expect(loadSettings(dir).rules).toEqual([]);
});

test("three yeses stop the asking", async () => {
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "yes" }));

  for (let i = 0; i < 3; i++) {
    expect(await checkApproval(mailer, { to: "bob" }, ask, undefined, dir)).toBeNull();
  }
  expect(ask).toHaveBeenCalledTimes(3);

  expect(await checkApproval(mailer, { to: "bob" }, ask, undefined, dir)).toBeNull();
  expect(ask).toHaveBeenCalledTimes(3);
});

test("the floor asks again even once a never rule is on disk", async () => {
  saveSettings(
    { moneyThreshold: 10, confirmIrreversibleDeletes: true, rules: [{ actionClass: "purchase", decision: "never" }] },
    dir,
  );
  const shop: Tool = {
    name: "buy",
    description: "",
    parameters: {},
    actionClass: "purchase",
    action: ({ item, price }) => ({ target: String(item ?? ""), amount: Number(price) }),
    run: () => "bought",
  };
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "no" }));

  expect(await checkApproval(shop, { item: "a book", price: 30 }, ask, undefined, dir)).toMatch(
    /not allowed/,
  );
  expect(ask).toHaveBeenCalledTimes(1);
});

test("a tool that only reads is never gated", async () => {
  const reader: Tool = { name: "fs_read", description: "", parameters: {}, run: () => "contents" };
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "yes" }));

  expect(await checkApproval(reader, { path: "/etc/hosts" }, ask, undefined, dir)).toBeNull();
  expect(ask).not.toHaveBeenCalled();
});
