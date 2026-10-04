import { expect, test } from "vitest";
import { parseSiwcAccountControl, parseSiwcAccountStatus, type SiwcAccountControlData, type SiwcAccountStatusData } from "./siwc-accounts.js";
import { localPeerInfo } from "./peer-info.js";

const status = (): SiwcAccountStatusData => ({ version: 1, productionReady: false, nativeIntegration: "wired-unverified",
  available: true, state: "available", revision: 2, activeAccountBindingId: "binding-a",
  accounts: [{ accountBindingId: "binding-a", phase: "ready", planUse: true, active: true }] });

test("account controls carry only method-specific opaque IDs; event ID owns the operation", () => {
  const controls: SiwcAccountControlData[] = [
    { version: 1, method: "sign-in" }, { version: 1, method: "sign-in", bindingId: "binding-a", returning: true },
    { version: 1, method: "cancel", attemptId: "attempt-a" }, { version: 1, method: "status" },
    ...(["select", "sign-out", "verify-pending"] as const).map(method => ({ version: 1 as const, method, bindingId: "binding-a" })),
  ];
  for (const control of controls) expect(parseSiwcAccountControl(JSON.parse(JSON.stringify(control)))).toEqual(control);
  for (const invalid of [
    { version: 1, method: "status", operationId: "duplicate" }, { version: 1, method: "sign-in", returning: true },
    { version: 1, method: "cancel", bindingId: "binding-a" }, { version: 1, method: "select", bindingId: null },
    { version: 1, method: "status", attemptId: "wrong-method" }, { version: 2, method: "status" },
    ...["token", "authorizationUrl", "callbackUrl", "codeVerifier", "clientId", "subject", "email"].map(key => ({ version: 1, method: "sign-in", [key]: "synthetic-forbidden" })),
  ]) expect(() => parseSiwcAccountControl(invalid)).toThrow();
});

test("safe status bounds readiness, operation receipts and coherent active account", () => {
  expect(parseSiwcAccountStatus(status())).toEqual(status());
  const pending = { version: 1 as const, productionReady: false as const, nativeIntegration: "wired-unverified" as const,
    available: false, state: "unsupported" as const, accounts: [],
    lastControlResult: { operationId: "operation-a", status: "pending" as const, attemptId: "attempt-a" } };
  expect(parseSiwcAccountStatus(pending)).toEqual(pending); // First sign-in must not require an activated store.
  for (const invalid of [
    { ...status(), productionReady: true }, { ...status(), nativeIntegration: "verified" },
    { ...status(), available: false }, { ...status(), revision: -1 }, { ...status(), revision: Number.MAX_SAFE_INTEGER + 1 },
    { ...status(), activeAccountBindingId: "missing" }, { ...status(), accounts: [status().accounts[0], status().accounts[0]] },
    { ...status(), accounts: [{ ...status().accounts[0], phase: "signed-out" }] },
    { ...status(), accounts: [{ ...status().accounts[0], email: "synthetic-forbidden" }] },
    { ...status(), lastControlResult: { operationId: "operation-a", status: "completed", attemptId: "attempt-a" } },
    { ...status(), lastControlResult: { operationId: "operation-a", status: "rejected", reason: "https://synthetic.invalid" } },
    ...["authorizationUrl", "refreshToken", "idToken", "pkce", "clientId", "subject", "callbackUri"].map(key => ({ ...status(), [key]: "synthetic-forbidden" })),
  ]) expect(() => parseSiwcAccountStatus(invalid)).toThrow();
});

test("account settings capability is negotiated without requiring it from older peers", () => {
  const info = localPeerInfo("0.6");
  expect(info.capabilities).toContain("siwc-accounts-v1");
  expect(info.requiredCapabilities).not.toContain("siwc-accounts-v1");
});
