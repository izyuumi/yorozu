import { afterEach, expect, test } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  addRule, DEFAULT_SETTINGS, decide, forgetApprovals, listRules, matchesRule,
  recordApproval, TaskGrants, verifyApproved,
  type Action, type Rule,
} from "./approval.js";

afterEach(forgetApprovals);

const purchase: Action = { actionClass: "purchase", target: "Coffee", amount: 48, currency: "JPY" };

test("adding currency metadata cannot bypass a legacy capped deny with a broader allow", () => {
  const allow: Rule = {
    id: "routine-coffee", actionClass: "purchase", decision: "always",
    scope: { target: { mode: "exact", value: "Coffee" } },
  };
  const deny: Rule = { ...allow, id: "blocked-coffee", decision: "never", maxAmount: 100 };
  const settings = { ...DEFAULT_SETTINGS, moneyThreshold: 1000, rules: [allow, deny] };
  expect(decide({ ...purchase, currency: undefined }, settings)).toEqual({ verdict: "deny", ruleId: deny.id });
  expect(decide(purchase, settings)).toEqual({ verdict: "deny", ruleId: deny.id });
});

test("explicitly removing a committed currency invalidates the approval", () => {
  recordApproval("removed-currency", purchase);
  expect(verifyApproved("removed-currency", { amount: 48, currency: undefined })).toMatch(/currency/);
  expect(verifyApproved("removed-currency", {})).toMatch(/no live approval/);
});

test("a re-extracted final amount cannot drop its approved currency", () => {
  recordApproval("missing-currency", purchase);
  expect(verifyApproved("missing-currency", { target: "Coffee", amount: 48 })).toMatch(/currency/);
});

test("legacy amount verification and nonmonetary partial checks remain compatible", () => {
  recordApproval("legacy-amount", { ...purchase, currency: undefined });
  expect(verifyApproved("legacy-amount", { amount: 48 })).toBeNull();
  recordApproval("partial-check", purchase);
  expect(verifyApproved("partial-check", { target: "Coffee" })).toBeNull();
  expect(verifyApproved("partial-check", { amount: 48, currency: "JPY" })).toBeNull();
});

test("explicit currency deny remains limited to its own denomination after disk roundtrip", () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-currency-rule-"));
  try {
    addRule({ id: "yen-cap", actionClass: "purchase", decision: "never", maxAmount: 100, currency: "JPY" }, dir);
    const [rule] = listRules(dir);
    expect(rule?.currency).toBe("JPY");
    expect(matchesRule(rule!, purchase)).toBe(true);
    expect(matchesRule(rule!, { ...purchase, currency: "USD" })).toBe(false);
    expect(matchesRule(rule!, { ...purchase, currency: undefined })).toBe(false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("turn-scoped approval cannot authorize an equal number in another currency", () => {
  const grants = new TaskGrants();
  grants.grant(purchase);
  expect(grants.covers(purchase)).toBe(true);
  expect(grants.covers({ ...purchase, currency: "USD" })).toBe(false);
  expect(grants.covers({ ...purchase, currency: undefined })).toBe(false);
});
