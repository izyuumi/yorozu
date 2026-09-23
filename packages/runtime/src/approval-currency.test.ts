import { expect, test } from "vitest";
import { cardFor, narrowestRule, matchesRule, normalizeRule, recordApproval, verifyApproved } from "./approval.js";

const purchase = { actionClass: "purchase" as const, target: "Coffee", amount: 48, currency: "JPY" };

test("approval cards preserve transaction currency outside descriptive scope", () => {
  const card = cardFor("currency-card", purchase);
  expect(card).toMatchObject({ amount: 48, currency: "JPY", suggestedRule: { currency: "JPY" } });
  expect(card.scope ?? {}).not.toHaveProperty("currency");
});

test("currency caps survive persistence and never cover another currency", () => {
  const rule = narrowestRule(purchase);
  expect(normalizeRule(rule)?.currency).toBe("JPY");
  expect(matchesRule(rule, purchase)).toBe(true);
  expect(matchesRule(rule, { ...purchase, currency: "USD" })).toBe(false);
  expect(matchesRule(rule, { ...purchase, currency: undefined })).toBe(false);
  const legacy = { ...rule, currency: undefined };
  expect(matchesRule(legacy, purchase)).toBe(false);
  expect(matchesRule(legacy, { ...purchase, currency: undefined })).toBe(true);
});

test("changing transaction currency invalidates a previously approved amount", () => {
  recordApproval("currency-change", purchase);
  expect(verifyApproved("currency-change", { amount: 48, currency: "USD" })).toMatch(/currency/);
});
