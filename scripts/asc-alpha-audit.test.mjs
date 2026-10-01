import assert from "node:assert/strict";
import { test } from "node:test";
import { auditInternalAlpha } from "./asc-alpha-audit.mjs";

const group = (id, internal, attrs = {}) => ({ type: "betaGroups", id, attributes: { name: internal ? "Internal" : "Public", isInternalGroup: internal, hasAccessToAllBuilds: false, publicLinkEnabled: !internal, ...attrs } });
const tester = (id, email = `${id}@example.invalid`) => ({ type: "betaTesters", id, attributes: { email } });
function fake({ groups = [group("internal", true), group("public", false)], members = { internal: [tester("owner")], public: [tester("beta")] }, next, bundleId = "to.yumi.yorozu.ios" } = {}) {
  return async (method, path) => {
    assert.equal(method, "GET", "Audit must never mutate ASC");
    const url = new URL(path, "https://api.appstoreconnect.apple.com");
    if (url.pathname === "/v1/apps/6811274963") return { data: { id: "6811274963", attributes: { bundleId } } };
    if (url.pathname.endsWith("/betaGroups")) return { data: groups, links: { next } };
    const match = /^\/v1\/betaGroups\/([A-Za-z0-9-]+)\/betaTesters$/.exec(url.pathname);
    assert.ok(match, "Audit can only read the requested app's groups and members");
    return { data: members[match[1]] ?? [] };
  };
}
test("established internal membership is read only and reports no personal data", async () => {
  const report = await auditInternalAlpha({ request: fake() });
  assert.equal(report.recipient_checks_passed, true); assert.equal(report.selected_tester_count, 1);
  assert.equal(report.automatic_distribution_ui_verified, false);
  assert.doesNotMatch(JSON.stringify(report), /owner|beta@example|@example|Public/);
});
test("matching emails with different tester IDs detect beta recipients", async () => {
  const report = await auditInternalAlpha({ request: fake({ members: { internal: [tester("internal-id", "Same@Example.invalid")], public: [tester("public-id", "same@example.invalid")] } }) });
  assert.equal(report.external_overlap_count, 1); assert.equal(report.recipient_checks_passed, false);
});
test("all-build access in other internal groups cannot silently broaden recipients", async () => {
  const report = await auditInternalAlpha({ request: fake({ groups: [group("internal", true), group("other", true, { name: "Other", hasAccessToAllBuilds: true })], members: { internal: [tester("owner")], other: [tester("extra")] } }) });
  assert.equal(report.unexpected_automatic_tester_count, 1); assert.equal(report.recipient_checks_passed, false);
});
test("unknown automatic access, empty membership and enabled public link fail closed", async () => {
  const report = await auditInternalAlpha({ request: fake({ groups: [group("internal", true, { hasAccessToAllBuilds: undefined, publicLinkEnabled: true })], members: {} }) });
  assert.deepEqual(report.reasons, ["empty-internal-group", "internal-public-link-not-disabled", "automatic-build-access-unknown"]);
});
test("ambiguous groups require a recipient decision", async () => {
  const report = await auditInternalAlpha({ request: fake({ groups: [group("a", true, { name: "A" }), group("b", true, { name: "B" })] }) });
  assert.ok(report.reasons.includes("ambiguous-internal-group"));
});
test("pagination cannot send credentials to another origin or cycle indefinitely", async () => {
  await assert.rejects(auditInternalAlpha({ request: fake({ next: "https://example.invalid/v1/apps/6811274963/betaGroups" }) }), /invalid-audit-response/);
  await assert.rejects(auditInternalAlpha({ request: fake({ next: "/v1/apps/6811274963/betaGroups?limit=200" }) }), /invalid-audit-response/);
});
test("wrong app and missing tester identity are rejected", async () => {
  await assert.rejects(auditInternalAlpha({ request: fake({ bundleId: "wrong" }) }), /invalid-audit-response/);
  await assert.rejects(auditInternalAlpha({ request: fake({ members: { internal: [{ type: "betaTesters", id: "unknown" }] } }) }), /invalid-audit-response/);
});
