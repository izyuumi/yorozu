import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { beforeEach, expect, test, vi } from "vitest";
import {
  addRule,
  appendLog,
  batchHash,
  cardFor,
  checkApproval,
  deleteRule,
  decide,
  decideFromDisk,
  DEFAULT_SETTINGS,
  forgetApprovals,
  hitsFloor,
  hashContent,
  listRules,
  loadSettings,
  markRuleUsed,
  matchesRule,
  narrowestRule,
  needsFreshConfirmation,
  PRECEDENT,
  PROPOSAL_WINDOW_MS,
  proposalFor,
  readLog,
  recordApproval,
  saveSettings,
  TaskGrants,
  verifyApproved,
  type Action,
  type AskResult,
  type LogRow,
  type Rule,
  type Settings,
  type Verdict,
} from "./approval.js";
import type { Tool } from "./index.js";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-approval-"));
  forgetApprovals();
});

const settings = (over: Partial<Settings> = {}): Settings => ({
  ...DEFAULT_SETTINGS,
  rules: [],
  ...over,
});

/** A rule with only the fields a case is about; the rest are what a saved rule always has. */
const rule = (over: Partial<Rule> & Pick<Rule, "actionClass" | "decision">): Rule => ({
  id: `r-${over.actionClass}-${over.decision}-${JSON.stringify(over.scope ?? {})}`,
  ...over,
});

const exact = (value: string) => ({ mode: "exact" as const, value });

const send: Action = {
  actionClass: "send-message",
  target: "bob@example.com",
  operation: "send",
  recipient: "bob@example.com",
};

// ---------------------------------------------------------------- 17, 20, 24, 31: structured scope

test.each<[string, Action, Settings, Verdict]>([
  ["nothing known asks", send, settings(), "ask"],
  [
    "a never rule on the class denies",
    send,
    settings({ rules: [rule({ actionClass: "send-message", decision: "never" })] }),
    "deny",
  ],
  [
    "an always rule on the class allows",
    send,
    settings({ rules: [rule({ actionClass: "send-message", decision: "always" })] }),
    "allow",
  ],
  [
    "a rule matching the recipient allows",
    send,
    settings({
      rules: [
        rule({
          actionClass: "send-message",
          decision: "always",
          scope: { recipient: exact("bob@example.com") },
        }),
      ],
    }),
    "allow",
  ],
  [
    "a rule naming another recipient does not match",
    send,
    settings({
      rules: [
        rule({
          actionClass: "send-message",
          decision: "always",
          scope: { recipient: exact("eve@example.com") },
        }),
      ],
    }),
    "ask",
  ],
  [
    "a rule constraining a field the action does not carry misses",
    send,
    settings({
      rules: [
        rule({
          actionClass: "send-message",
          decision: "always",
          scope: { merchant: exact("bob@example.com") },
        }),
      ],
    }),
    "ask",
  ],
  [
    "a prefix pattern covers everything under it",
    { actionClass: "edit-file", target: "/Users/yumi/Projects/app/main.ts", operation: "edit" },
    settings({
      rules: [
        rule({
          actionClass: "edit-file",
          decision: "always",
          scope: { target: { mode: "prefix", value: "/Users/yumi/Projects/" } },
        }),
      ],
    }),
    "allow",
  ],
  [
    "a prefix pattern stops where it stops",
    { actionClass: "edit-file", target: "/etc/hosts", operation: "edit" },
    settings({
      rules: [
        rule({
          actionClass: "edit-file",
          decision: "always",
          scope: { target: { mode: "prefix", value: "/Users/yumi/Projects/" } },
        }),
      ],
    }),
    "ask",
  ],
  [
    "a glob pattern matches a whole domain",
    send,
    settings({
      rules: [
        rule({
          actionClass: "send-message",
          decision: "always",
          scope: { recipient: { mode: "glob", value: "*@example.com" } },
        }),
      ],
    }),
    "allow",
  ],
  [
    "a glob pattern does not leak past the domain",
    { ...send, target: "bob@evil.com", recipient: "bob@evil.com" },
    settings({
      rules: [
        rule({
          actionClass: "send-message",
          decision: "always",
          scope: { recipient: { mode: "glob", value: "*@example.com" } },
        }),
      ],
    }),
    "ask",
  ],
  [
    "a rule switched off in Settings stops matching",
    send,
    settings({
      rules: [rule({ actionClass: "send-message", decision: "always", enabled: false })],
    }),
    "ask",
  ],
  [
    "matching ignores capitalisation, which no rule should turn on",
    { ...send, recipient: "Bob@Example.com" },
    settings({
      rules: [
        rule({
          actionClass: "send-message",
          decision: "always",
          scope: { recipient: exact("bob@example.com") },
        }),
      ],
    }),
    "allow",
  ],
])("decide: %s", (_name, action, stored, expected) => {
  expect(decide(action, stored, dir).verdict).toBe(expected);
});

test("24: a more-specific allow wins; deny wins only at equal specificity", () => {
  const stored = settings({
    rules: [
      // As broad as a deny gets: the whole class.
      rule({ actionClass: "send-message", decision: "never" }),
      // As narrow as an allow gets: this one recipient and nothing else.
      rule({
        actionClass: "send-message",
        decision: "always",
        scope: { recipient: exact("bob@example.com"), operation: exact("send") },
      }),
    ],
  });
  expect(decide(send, stored, dir).verdict).toBe("allow");

  stored.rules.push(rule({
    actionClass: "send-message",
    decision: "never",
    scope: { recipient: exact("bob@example.com"), operation: exact("send") },
  }));
  expect(decide(send, stored, dir).verdict).toBe("deny");
});

test("the most specific allow is the one that authorises, and the log says which", () => {
  const broad = rule({ actionClass: "purchase", decision: "always", maxAmount: 500 });
  const narrow = rule({
    actionClass: "purchase",
    decision: "always",
    scope: { merchant: exact("the corner shop") },
    maxAmount: 500,
  });
  const buy: Action = {
    actionClass: "purchase",
    target: "a loaf",
    operation: "purchase",
    merchant: "the corner shop",
    amount: 4,
  };
  expect(decide(buy, settings({ moneyThreshold: 200, rules: [broad, narrow] }), dir)).toEqual({
    verdict: "allow",
    ruleId: narrow.id,
  });
});

test("20: rules are global — the agent taking the action is recorded but never matched on", async () => {
  addRule(
    rule({
      actionClass: "send-message",
      decision: "always",
      scope: { recipient: exact("bob@example.com") },
    }),
    dir,
  );
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "no" }));

  for (const agentId of ["main", "email"]) {
    const gate = await checkApproval(mailer, { to: "bob@example.com" }, {
      ask,
      context: { threadId: "t1", agentId },
      dir,
    });
    expect(gate.refusal).toBeNull();
  }
  expect(ask).not.toHaveBeenCalled();
  // Both were authorised by the same rule, and both rows say so along with who was acting.
  expect(readLog(dir).map(({ decision, ruleId, agentId }) => ({ decision, ruleId, agentId }))).toEqual([
    { decision: "auto", ruleId: listRules(dir)[0].id, agentId: "main" },
    { decision: "auto", ruleId: listRules(dir)[0].id, agentId: "email" },
  ]);
});

test("31: an automatic allow names the rule, and Settings can see it working", async () => {
  const stored = rule({
    actionClass: "send-message",
    decision: "always",
    scope: { recipient: exact("bob@example.com") },
  });
  addRule(stored, dir);

  await checkApproval(mailer, { to: "bob@example.com" }, { ask: never, dir });
  await checkApproval(mailer, { to: "bob@example.com" }, { ask: never, dir });

  expect(readLog(dir).every((row) => row.ruleId === stored.id)).toBe(true);
  expect(listRules(dir)[0]).toMatchObject({ useCount: 2 });
  expect(listRules(dir)[0].lastUsed).toBeGreaterThan(0);
  // And the row carries the scope it was judged against, not just the class.
  expect(readLog(dir)[0].scope).toMatchObject({ recipient: "bob@example.com", operation: "send" });
});

test("17: the card carries the structured scope the tool declared", () => {
  const card = cardFor("a1", {
    actionClass: "purchase",
    target: "a kilo of coffee",
    operation: "purchase",
    merchant: "Kurasu",
    category: "groceries",
    account: "Visa ••4242",
    quantity: 1,
    amount: 32,
    contentSummary: "Ethiopia Guji, whole bean",
    consequence: "Charges the Visa and ships to the home address.",
  });
  expect(card).toMatchObject({
    actionId: "a1",
    actionClass: "purchase",
    amount: 32,
    scope: {
      operation: "purchase",
      merchant: "Kurasu",
      category: "groceries",
      account: "Visa ••4242",
      quantity: 1,
      consequence: "Charges the Visa and ships to the home address.",
    },
  });
  // And the editor's prefill: the merchant and the account, capped half again over the price.
  expect(card.suggestedRule).toMatchObject({
    actionClass: "purchase",
    decision: "always",
    scope: {
      merchant: exact("Kurasu"),
      account: exact("Visa ••4242"),
      category: exact("groceries"),
      operation: exact("purchase"),
    },
    maxAmount: 48,
  });
});

test("a prefilled rule is never scoped on the operation alone: that would authorise the class", () => {
  const prefill = narrowestRule({
    actionClass: "run-command",
    target: "rm -rf ~/Desktop/old",
    operation: "run",
  });
  expect(prefill.scope).toEqual({
    target: exact("rm -rf ~/Desktop/old"),
    operation: exact("run"),
  });
  // Which is to say a different command is not covered by it.
  expect(matchesRule(prefill, { actionClass: "run-command", target: "rm -rf /", operation: "run" })).toBe(
    false,
  );
});

// ------------------------------------------------------------------------------- the floor

test("the money floor asks even though a never rule would have denied", () => {
  const buy: Action = { actionClass: "purchase", target: "the corner shop", amount: 50 };
  const stored = settings({
    moneyThreshold: 20,
    rules: [rule({ actionClass: "purchase", decision: "never" })],
  });

  expect(hitsFloor(buy, stored, dir)).toBe(true);
  expect(decide(buy, stored, dir).verdict).toBe("ask");
  // Under the threshold the floor is silent and the rule decides again.
  expect(decide({ ...buy, amount: 19 }, stored, dir).verdict).toBe("deny");
});

test("the delete floor covers anything outside the state directory", () => {
  const rules = [rule({ actionClass: "delete-file", decision: "never" })];
  const stored = settings({ rules });

  expect(decide({ actionClass: "delete-file", target: "/etc/hosts" }, stored, dir).verdict).toBe("ask");
  // Yorozu's own files are the runtime's business, so the rule still applies to them.
  expect(decide({ actionClass: "delete-file", target: join(dir, "cache", "x") }, stored, dir).verdict).toBe(
    "deny",
  );
  // Switched off at onboarding, the rule decides wherever the file lives.
  expect(
    decide(
      { actionClass: "delete-file", target: "/etc/hosts" },
      settings({ confirmIrreversibleDeletes: false, rules }),
      dir,
    ).verdict,
  ).toBe("deny");
});

// ------------------------------------------------------------------ 27, 28: caps and the classes that always ask

test("27: a capped merchant rule runs routine shopping unattended, and stops at the cap", () => {
  const stored = settings({
    moneyThreshold: 200,
    rules: [
      rule({
        actionClass: "purchase",
        decision: "always",
        scope: { merchant: exact("Kurasu") },
        maxAmount: 50,
      }),
    ],
  });
  const buy = (amount: number): Action => ({
    actionClass: "purchase",
    target: "coffee",
    operation: "purchase",
    merchant: "Kurasu",
    amount,
  });

  expect(decide(buy(32), stored, dir).verdict).toBe("allow");
  expect(decide(buy(50), stored, dir).verdict).toBe("allow");
  // Over the cap the rule stops matching, so there is nothing to authorise it.
  expect(decide(buy(51), stored, dir).verdict).toBe("ask");
  // And a different merchant was never in scope.
  expect(decide({ ...buy(32), merchant: "Blue Bottle" }, stored, dir).verdict).toBe("ask");
});

test.each<[string, Partial<Action>]>([
  ["a subscription", { operation: "subscribe" }],
  ["a transfer by operation", { operation: "transfer" }],
  ["a transfer by class", { actionClass: "transfer-money" }],
  ["a securities trade", { operation: "trade" }],
  ["anything in crypto", { category: "Crypto" }],
])("28: %s asks again however wide the stored rule is", (_name, over) => {
  const action: Action = {
    actionClass: "purchase",
    target: "monthly plan",
    operation: "purchase",
    merchant: "Kurasu",
    amount: 5,
    ...over,
  };
  const stored = settings({
    moneyThreshold: 10_000,
    // As broad as a rule can be written: the whole class, no cap.
    rules: [rule({ actionClass: action.actionClass, decision: "always" })],
  });

  expect(needsFreshConfirmation(action)).toBe(true);
  expect(decide(action, stored, dir).verdict).toBe("ask");
  expect(cardFor("a1", action).mustConfirm).toBe(true);
  expect(cardFor("a1", action).suggestedRule).toBeUndefined();
});

test("an ordinary purchase is not one of those, and says so on the card", () => {
  const action: Action = {
    actionClass: "purchase",
    target: "coffee",
    operation: "purchase",
    merchant: "Kurasu",
    amount: 5,
  };
  expect(needsFreshConfirmation(action)).toBe(false);
  expect(cardFor("a1", action).mustConfirm).toBeUndefined();
});

// -------------------------------------------------------------------------- 29: verifyApproved

test("29: a price, quantity, recipient or account that moved invalidates the approval", () => {
  const action: Action = {
    actionClass: "purchase",
    target: "coffee",
    operation: "purchase",
    merchant: "Kurasu",
    account: "Visa ••4242",
    recipient: "home",
    quantity: 2,
    amount: 32,
  };
  recordApproval("a1", action);

  // The values that were on the card commit without complaint.
  expect(verifyApproved("a1", { amount: 32, quantity: 2, account: "Visa ••4242", recipient: "home" })).toBeNull();

  for (const [field, changed] of [
    ["amount", { amount: 39 }],
    ["quantity", { quantity: 3 }],
    ["recipient", { recipient: "the office" }],
    ["account", { account: "Amex ••1001" }],
  ] as const) {
    recordApproval("a1", action);
    const stale = verifyApproved("a1", changed);
    expect(stale, field).toMatch(/what was approved has changed/);
    expect(stale).toContain(field);
    // Spent: the same id cannot be used for a second attempt either.
    expect(verifyApproved("a1", {})).toMatch(/no live approval/);
  }
});

test("29: an action with no approval at all cannot be committed", () => {
  expect(verifyApproved("never-asked", { amount: 1 })).toMatch(/no live approval/);
});

test("29: changes beyond the displayed content summary invalidate approval", () => {
  const prefix = "x".repeat(200);
  recordApproval("a1", {
    actionClass: "edit-file",
    target: "/tmp/file",
    operation: "edit",
    contentSummary: prefix,
    contentHash: hashContent(`${prefix}A`),
  });
  expect(verifyApproved("a1", {
    contentSummary: prefix,
    contentHash: hashContent(`${prefix}B`),
  })).toMatch(/contentHash/);
});

// -------------------------------------------------------------------------- 25, 26: batches

test("25: a batch card lists the exact items, and the hash is of exactly those", () => {
  const items = [
    { label: "bob@example.com", detail: "April invoice" },
    { label: "carol@example.com", detail: "April invoice" },
  ];
  const card = cardFor("a1", { actionClass: "send-message", target: "2 people", operation: "send", items });
  expect(card.items).toEqual(items);
  expect(batchHash(items)).toBe(batchHash([...items]));
});

test("26: an item added or changed after approval is not covered by it", () => {
  const items = [
    { label: "bob@example.com", detail: "April invoice" },
    { label: "carol@example.com", detail: "April invoice" },
  ];
  const action: Action = { actionClass: "send-message", target: "2 people", operation: "send", items };
  recordApproval("a1", action);

  expect(verifyApproved("a1", { items })).toBeNull();

  recordApproval("a1", action);
  expect(verifyApproved("a1", { items: [...items, { label: "dave@example.com" }] })).toMatch(
    /not the one that was approved/,
  );

  recordApproval("a1", action);
  expect(
    verifyApproved("a1", { items: [items[0], { label: "carol@example.com", detail: "May invoice" }] }),
  ).toMatch(/not the one that was approved/);

  // The same items in a different order are a different list: the card showed an order.
  recordApproval("a1", action);
  expect(verifyApproved("a1", { items: [items[1], items[0]] })).toMatch(/not the one that was approved/);
});

test("25: the gate records the batch the card showed, so the tool can prove it", async () => {
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "yes" }));
  const args = { to: "bob@example.com, carol@example.com", subject: "April invoice" };
  const gate = await checkApproval(batchMailer, args, { ask, dir });

  expect(gate.refusal).toBeNull();
  expect(ask.mock.calls[0][0].items).toEqual([
    { label: "bob@example.com", detail: "April invoice" },
    { label: "carol@example.com", detail: "April invoice" },
  ]);
  expect(verifyApproved(gate.actionId!, { items: batchMailer.batch!(args) })).toBeNull();
  expect(
    verifyApproved(gate.actionId!, {
      items: batchMailer.batch!({ ...args, to: `${args.to}, dave@example.com` }),
    }),
  ).toMatch(/not the one that was approved/);
});

// ------------------------------------------------------------------------- settings on disk

test("settings round-trip, and a file broken by hand falls back to the safe floor", () => {
  saveSettings(settings({ yolo: true, moneyThreshold: 25, confirmIrreversibleDeletes: false }), dir);
  expect(loadSettings(dir)).toMatchObject({ yolo: true, moneyThreshold: 25, confirmIrreversibleDeletes: false });

  writeFileSync(join(dir, "approval.json"), "{ not json");
  expect(loadSettings(dir)).toEqual(DEFAULT_SETTINGS);
});

test("YOLO mode bypasses rules below the floor while keeping an audit row", async () => {
  saveSettings(
    settings({
      yolo: true,
      moneyThreshold: 1_000,
      rules: [rule({ actionClass: "purchase", decision: "never" })],
    }),
    dir,
  );
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "no" }));
  const gate = await checkApproval(
    {
      name: "buy",
      description: "buy",
      parameters: {},
      actionClass: "purchase",
      action: () => ({ target: "shop", amount: 100 }),
      run: async () => "ok",
    },
    {},
    { ask, dir },
  );

  expect(gate.refusal).toBeNull();
  expect(ask).not.toHaveBeenCalled();
  expect(readLog(dir).at(-1)?.decision).toBe("yolo");
});

test("a rule from before the structured scope is read forward, not lost", () => {
  writeFileSync(
    join(dir, "approval.json"),
    JSON.stringify({
      moneyThreshold: 0,
      confirmIrreversibleDeletes: true,
      rules: [{ actionClass: "send-message", target: "bob@example.com", decision: "always" }],
    }),
  );
  const [stored] = listRules(dir);
  expect(stored).toMatchObject({
    actionClass: "send-message",
    decision: "always",
    scope: { target: exact("bob@example.com") },
  });
  expect(stored.id).toBeTruthy();
  expect(decideFromDisk({ actionClass: "send-message", target: "bob@example.com" }, dir).verdict).toBe(
    "allow",
  );
});

test("21: a saved rule persists until it is revoked, and editing replaces rather than doubles", () => {
  const saved = rule({ actionClass: "purchase", decision: "always", maxAmount: 50 });
  addRule(saved, dir);
  addRule({ ...saved, maxAmount: 80 }, dir);
  expect(listRules(dir)).toHaveLength(1);
  expect(listRules(dir)[0].maxAmount).toBe(80);

  expect(deleteRule(saved.id, dir)).toBe(true);
  expect(listRules(dir)).toEqual([]);
  expect(deleteRule(saved.id, dir)).toBe(false);
});

test("a rule with no id is still usable and still revocable", () => {
  writeFileSync(
    join(dir, "approval.json"),
    JSON.stringify({ rules: [{ actionClass: "purchase", decision: "never" }] }),
  );
  const [stored] = listRules(dir);
  markRuleUsed(stored.id, dir);
  expect(deleteRule(stored.id, dir)).toBe(true);
});

// ------------------------------------------------------------------------- 18, 19, 21: the three grants

/** Stands in for a tool with an external effect; `run` is never reached in these tests. */
const mailer: Tool = {
  name: "mail_send",
  description: "",
  parameters: {},
  actionClass: "send-message",
  action: ({ to }) => ({
    target: String(to ?? ""),
    operation: "send",
    recipient: String(to ?? ""),
  }),
  run: () => "sent",
};

/** The same tool, declaring the list of people one decision would cover. */
const batchMailer: Tool = {
  ...mailer,
  batch: ({ to, subject }) =>
    String(to ?? "")
      .split(",")
      .map((address) => address.trim())
      .filter(Boolean)
      .map((label) => ({ label, ...(subject ? { detail: String(subject) } : {}) })),
};

/** An `ask` that must never be reached: a rule was supposed to settle it without a card. */
const never = async (): Promise<AskResult> => {
  throw new Error("the card should not have been shown");
};

test("18: allow once covers this action and nothing after it", async () => {
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "yes" }));

  expect((await checkApproval(mailer, { to: "bob" }, { ask, dir })).refusal).toBeNull();
  expect((await checkApproval(mailer, { to: "bob" }, { ask, dir })).refusal).toBeNull();

  expect(ask).toHaveBeenCalledTimes(2);
  expect(listRules(dir)).toEqual([]);
  expect(readLog(dir).map((row) => row.decision)).toEqual(["yes", "yes"]);
});

test("18: allow for this task covers the same scope for the rest of the turn and no longer", async () => {
  const grants = new TaskGrants();
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "task" }));

  expect((await checkApproval(mailer, { to: "bob" }, { ask, grants, dir })).refusal).toBeNull();
  // Same scope: covered by the grant, so no second card.
  expect((await checkApproval(mailer, { to: "bob" }, { ask, grants, dir })).refusal).toBeNull();
  expect(ask).toHaveBeenCalledTimes(1);

  // A different recipient is a different scope, so it asks.
  await checkApproval(mailer, { to: "carol" }, { ask, grants, dir });
  expect(ask).toHaveBeenCalledTimes(2);

  // Nothing was written, and next turn's grants are a new object with nothing in them.
  expect(listRules(dir)).toEqual([]);
  const nextTurn = new TaskGrants();
  await checkApproval(mailer, { to: "bob" }, { ask, grants: nextTurn, dir });
  expect(ask).toHaveBeenCalledTimes(3);
  expect(readLog(dir).map((row) => row.decision)).toEqual(["task", "task-grant", "task", "task"]);
});

test("18: a bounded grant covers a delegated agent too, because it is the turn's, not the agent's", async () => {
  const grants = new TaskGrants();
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "task" }));

  await checkApproval(mailer, { to: "bob" }, { ask, grants, context: { threadId: "t", agentId: "main" }, dir });
  const delegated = await checkApproval(mailer, { to: "bob" }, {
    ask,
    grants,
    context: { threadId: "t", agentId: "email" },
    dir,
  });

  expect(delegated.refusal).toBeNull();
  expect(ask).toHaveBeenCalledTimes(1);
});

test("18: a bounded grant does not reach past the floor", async () => {
  saveSettings(settings({ moneyThreshold: 10 }), dir);
  const grants = new TaskGrants();
  const shop: Tool = {
    name: "buy",
    description: "",
    parameters: {},
    actionClass: "purchase",
    action: ({ price }) => ({ target: "a book", operation: "purchase", merchant: "Kinokuniya", amount: Number(price) }),
    run: () => "bought",
  };
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "task" }));

  await checkApproval(shop, { price: 30 }, { ask, grants, dir });
  await checkApproval(shop, { price: 30 }, { ask, grants, dir });
  expect(ask).toHaveBeenCalledTimes(2);
});

test("19, 21: always allow saves the rule the editor produced, and the next one runs unasked", async () => {
  const edited = rule({
    actionClass: "send-message",
    decision: "always",
    // Widened in the editor: any recipient at this domain rather than the one address.
    scope: { recipient: { mode: "glob", value: "*@example.com" } },
  });
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "always", rule: edited }));

  expect((await checkApproval(mailer, { to: "bob@example.com" }, { ask, dir })).refusal).toBeNull();
  // A different address the widened rule covers: the promise not to ask again has to hold.
  expect((await checkApproval(mailer, { to: "carol@example.com" }, { ask, dir })).refusal).toBeNull();
  // One it does not: still asked about.
  await checkApproval(mailer, { to: "dave@other.com" }, { ask, dir });

  expect(ask).toHaveBeenCalledTimes(2);
  expect(listRules(dir)).toMatchObject([edited]);
});

test("19, 23: always without an explicitly edited scoped rule grants nothing", async () => {
  const result = await checkApproval(mailer, { to: "bob@example.com" }, {
    ask: async () => ({ answer: "always" }),
    dir,
  });

  expect(result.refusal).toMatch(/review and save a scoped rule/);
  expect(listRules(dir)).toEqual([]);
});

test("19: an always answer cannot inject an unrelated or unscoped rule", async () => {
  for (const edited of [
    rule({ actionClass: "purchase", decision: "always", scope: { merchant: exact("Shop") } }),
    rule({ actionClass: "send-message", decision: "always" }),
    rule({ actionClass: "send-message", decision: "always", maxAmount: 10 }),
    rule({
      actionClass: "send-message",
      decision: "always",
      scope: { bogus: exact("anything") } as never,
    }),
  ]) {
    const result = await checkApproval(mailer, { to: "bob@example.com" }, {
      ask: async () => ({ answer: "always", rule: edited }),
      dir,
    });
    expect(result.refusal).toMatch(/review and save a scoped rule/);
  }
  expect(listRules(dir)).toEqual([]);
});

test("19: the scoped editor can persist a deny and the pending action does not run", async () => {
  const edited = rule({
    actionClass: "send-message",
    decision: "never",
    scope: { recipient: exact("bob@example.com") },
  });
  const result = await checkApproval(mailer, { to: "bob@example.com" }, {
    ask: async () => ({ answer: "always", rule: edited }),
    dir,
  });
  expect(result.refusal).toMatch(/not allowed/);
  expect(listRules(dir)).toMatchObject([edited]);
});

test("generic browser interactions always ask and offer no reusable rule", async () => {
  saveSettings(settings({ yolo: true, rules: [rule({
    actionClass: "interact-web",
    decision: "always",
    scope: { target: exact("tab-1 element 4") },
  })] }), dir);
  const web: Tool = {
    name: "browser.click",
    description: "",
    parameters: {},
    actionClass: "interact-web",
    action: () => ({ target: "tab-1 element 4", operation: "run" }),
    run: () => "clicked",
  };
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "yes" }));
  const gate = await checkApproval(web, {}, { ask, dir });
  expect(gate.refusal).toBeNull();
  expect(ask).toHaveBeenCalledOnce();
  expect(cardFor("web", { actionClass: "interact-web", ...web.action!({}) }).suggestedRule).toBeUndefined();
});

test("generic native app interactions always ask and offer no reusable rule", async () => {
  saveSettings(settings({ yolo: true, rules: [rule({
    actionClass: "interact-app",
    decision: "always",
    scope: { target: exact("focused control") },
  })] }), dir);
  const input: Tool = {
    name: "input_type",
    description: "",
    parameters: {},
    actionClass: "interact-app",
    action: () => ({ target: "focused control", operation: "run" }),
    run: () => "typed",
  };
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "yes" }));
  const gate = await checkApproval(input, {}, { ask, dir });
  expect(gate.refusal).toBeNull();
  expect(ask).toHaveBeenCalledOnce();
  expect(cardFor("app", { actionClass: "interact-app", ...input.action!({}) }).suggestedRule).toBeUndefined();
});

test("no refuses this one action only: nothing is written, and the next one asks again", async () => {
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "no" }));

  expect((await checkApproval(mailer, { to: "bob" }, { ask, dir })).refusal).toMatch(/not allowed/);
  expect((await checkApproval(mailer, { to: "bob" }, { ask, dir })).refusal).toMatch(/not allowed/);

  expect(ask).toHaveBeenCalledTimes(2);
  expect(listRules(dir)).toEqual([]);
  expect(readLog(dir).map((row) => row.decision)).toEqual(["no", "no"]);
});

test("discuss settles nothing: no rule, no log row, and the action stays pending", async () => {
  const { refusal } = await checkApproval(mailer, { to: "bob" }, {
    ask: async () => ({ answer: "discuss" }),
    dir,
  });

  expect(refusal).toMatch(/pending/);
  expect(readLog(dir)).toEqual([]);
  expect(listRules(dir)).toEqual([]);
});

test("a never rule left on disk refuses without asking, and the row says which rule did it", async () => {
  const stored = rule({ actionClass: "send-message", decision: "never" });
  addRule(stored, dir);
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "yes" }));

  expect((await checkApproval(mailer, { to: "bob" }, { ask, dir })).refusal).toMatch(/not allowed/);
  expect(ask).not.toHaveBeenCalled();
  expect(readLog(dir)[0]).toMatchObject({ decision: "denied", ruleId: stored.id });
});

test("the floor asks again even once an always rule is on disk", async () => {
  saveSettings(
    {
      moneyThreshold: 10,
      confirmIrreversibleDeletes: true,
      rules: [rule({ actionClass: "purchase", decision: "always" })],
    },
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

  expect((await checkApproval(shop, { item: "a book", price: 30 }, { ask, dir })).refusal).toMatch(
    /not allowed/,
  );
  expect(ask).toHaveBeenCalledTimes(1);
});

test("YOLO cannot bypass a hard financial confirmation floor", async () => {
  saveSettings(settings({ yolo: true, moneyThreshold: 10_000 }), dir);
  const transfer: Tool = {
    name: "transfer",
    description: "",
    parameters: {},
    actionClass: "transfer-money",
    action: () => ({ target: "Savings", operation: "transfer", amount: 10 }),
    run: () => "transferred",
  };
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "yes" }));

  expect((await checkApproval(transfer, {}, { ask, dir })).refusal).toBeNull();
  expect(ask).toHaveBeenCalledTimes(1);
});

test("a hard financial floor cannot create permanent authority", async () => {
  const action: Action = {
    actionClass: "transfer-money",
    target: "Savings",
    operation: "transfer",
    account: "Checking",
  };
  const transfer: Tool = {
    name: "transfer",
    description: "",
    parameters: {},
    actionClass: "transfer-money",
    action: () => ({ target: "Savings", operation: "transfer", account: "Checking" }),
    run: () => "transferred",
  };
  const permanent = narrowestRule(action);
  const result = await checkApproval(transfer, {}, {
    ask: async () => ({ answer: "always", rule: permanent }),
    dir,
  });

  expect(result.refusal).toMatch(/permanent authority requires/);
  expect(listRules(dir)).toEqual([]);
});

test("a tool that only reads is never gated", async () => {
  const reader: Tool = { name: "fs_read", description: "", parameters: {}, run: () => "contents" };
  const ask = vi.fn(async (): Promise<AskResult> => ({ answer: "yes" }));

  expect((await checkApproval(reader, { path: "/etc/hosts" }, { ask, dir })).refusal).toBeNull();
  expect(ask).not.toHaveBeenCalled();
});

// -------------------------------------------------------------------------- 22, 23: proposals

const approvals = (count: number, over: Partial<LogRow> = {}): void => {
  for (let i = 0; i < count; i++) {
    appendLog(
      {
        ts: Date.now(),
        actionClass: "send-message",
        target: "bob@example.com",
        decision: "yes",
        scope: { operation: "send", recipient: "bob@example.com" },
        ...over,
      },
      dir,
    );
  }
};

test("22: three matching approvals in the window are worth a proposal; two are not", () => {
  approvals(PRECEDENT - 1);
  expect(proposalFor(send, loadSettings(dir), readLog(dir))).toBeNull();

  approvals(1);
  expect(proposalFor(send, loadSettings(dir), readLog(dir))).toMatchObject({
    actionClass: "send-message",
    decision: "always",
    scope: { recipient: exact("bob@example.com"), operation: exact("send") },
  });
});

test("22: approvals of a different scope do not add up to a proposal", () => {
  approvals(PRECEDENT, { target: "eve@example.com", scope: { operation: "send", recipient: "eve@example.com" } });
  expect(proposalFor(send, loadSettings(dir), readLog(dir))).toBeNull();
});

test("22: approvals older than the window have stopped counting", () => {
  const now = Date.now();
  approvals(PRECEDENT, { ts: now - PROPOSAL_WINDOW_MS - 1 });
  expect(proposalFor(send, loadSettings(dir), readLog(dir), now)).toBeNull();
});

test("22: refusals never add up to anything", () => {
  approvals(PRECEDENT, { decision: "no" });
  expect(proposalFor(send, loadSettings(dir), readLog(dir))).toBeNull();
});

test("22: nothing is proposed once a rule already covers it", () => {
  approvals(PRECEDENT);
  addRule(
    rule({
      actionClass: "send-message",
      decision: "always",
      scope: { recipient: exact("bob@example.com") },
    }),
    dir,
  );
  expect(proposalFor(send, loadSettings(dir), readLog(dir))).toBeNull();
});

test("23: a proposal is raised as a card and activates nothing by itself", async () => {
  const onProposal = vi.fn();
  const ask = async (): Promise<AskResult> => ({ answer: "yes" });

  for (let i = 0; i < PRECEDENT; i++) {
    await checkApproval(mailer, { to: "bob@example.com" }, { ask, onProposal, dir });
  }

  expect(onProposal).toHaveBeenCalledTimes(1);
  expect(onProposal.mock.calls[0][0]).toMatchObject({
    actionClass: "send-message",
    decision: "always",
    scope: { recipient: exact("bob@example.com") },
  });
  expect(onProposal.mock.calls[0][1]).toBe(PRECEDENT);
  // The whole point: nothing was stored, so the fourth one still asks.
  expect(listRules(dir)).toEqual([]);
  const asked = vi.fn(ask);
  await checkApproval(mailer, { to: "bob@example.com" }, { ask: asked, dir });
  expect(asked).toHaveBeenCalledTimes(1);
});

test("23: the proposal is only offered once, not on every approval after the third", async () => {
  const onProposal = vi.fn();
  const ask = async (): Promise<AskResult> => ({ answer: "yes" });

  for (let i = 0; i < PRECEDENT; i++) {
    await checkApproval(mailer, { to: "bob@example.com" }, { ask, onProposal, dir });
  }
  // Accepted from the card: the editor saved it, which is what stops the nagging.
  addRule(onProposal.mock.calls[0][0] as Rule, dir);
  await checkApproval(mailer, { to: "bob@example.com" }, { ask, onProposal, dir });

  expect(onProposal).toHaveBeenCalledTimes(1);
});

test("25: a batch card offers no rule, because no standing rule can mean “exactly these”", () => {
  const items = [{ label: "bob@example.com" }, { label: "carol@example.com" }];
  const batch = cardFor("a1", { actionClass: "send-message", target: "2 people", operation: "send", items });
  expect(batch.suggestedRule).toBeUndefined();

  // The same action without a batch is offered one as usual.
  const single = cardFor("a2", {
    actionClass: "send-message",
    target: "bob@example.com",
    operation: "send",
    recipient: "bob@example.com",
  });
  expect(single.suggestedRule).toMatchObject({ scope: { recipient: exact("bob@example.com") } });
});
