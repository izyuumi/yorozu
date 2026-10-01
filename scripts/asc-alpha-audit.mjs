#!/usr/bin/env node
// Read-only alpha recipient audit. No uploads, invitations, role or group changes.
// Tester identifiers stay in memory; logs contain only counts and fixed reasons.
import { asc } from "./asc.mjs";

const appId = "6811274963";
const origin = "https://api.appstoreconnect.apple.com";
const requireValue = (condition) => { if (!condition) throw new Error("invalid-audit-response"); };
const query = (path, values) => `${path}?${new URLSearchParams(values)}`;
async function pages(request, initial) {
  const pathname = new URL(initial, origin).pathname;
  const visited = new Set(); const items = [];
  let path = initial;
  while (path) {
    requireValue(!visited.has(path) && visited.size < 1000); visited.add(path);
    const response = await request("GET", path);
    requireValue(Array.isArray(response.data));
    items.push(...response.data);
    const next = response.links?.next;
    if (!next) break;
    const url = new URL(next, origin);
    requireValue(url.origin === origin && url.pathname === pathname);
    path = `${url.pathname}${url.search}`;
  }
  return items;
}
function testerKeys(tester) {
  requireValue(tester.type === "betaTesters" && typeof tester.id === "string" && tester.id.length > 0);
  const email = tester.attributes?.email;
  requireValue(typeof email === "string" && email.includes("@"));
  return [`id:${tester.id}`, `email:${email.trim().toLowerCase()}`];
}
const overlapCount = (left, right) => left.filter((tester) => testerKeys(tester).some((key) => right.has(key))).length;

export async function auditInternalAlpha({ request = asc } = {}) {
  const app = await request("GET", query(`/v1/apps/${appId}`, { "fields[apps]": "bundleId" }));
  requireValue(app.data?.id === appId && app.data.attributes?.bundleId === "to.yumi.yorozu.ios");
  const groups = await pages(request, query(`/v1/apps/${appId}/betaGroups`, {
    "fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled", limit: "200",
  }));
  const seen = new Set();
  for (const group of groups) {
    requireValue(group.type === "betaGroups" && typeof group.id === "string" && /^[A-Za-z0-9-]+$/.test(group.id) && !seen.has(group.id));
    seen.add(group.id);
    requireValue(typeof group.attributes?.name === "string" && typeof group.attributes.isInternalGroup === "boolean");
  }
  const internal = groups.filter((group) => group.attributes.isInternalGroup);
  const named = internal.filter((group) => group.attributes.name === "Internal");
  const selected = internal.length === 1 ? internal[0] : named.length === 1 ? named[0] : undefined;
  const members = new Map();
  for (const group of groups) {
    const testers = await pages(request, query(`/v1/betaGroups/${group.id}/betaTesters`, { "fields[betaTesters]": "email", limit: "200" }));
    testers.forEach(testerKeys); members.set(group.id, testers);
  }
  const externalKeys = new Set(groups.filter((group) => !group.attributes.isInternalGroup).flatMap((group) => members.get(group.id).flatMap(testerKeys)));
  const selectedMembers = selected ? members.get(selected.id) : [];
  const selectedKeys = new Set(selectedMembers.flatMap(testerKeys));
  const automaticUnknown = internal.filter((group) => typeof group.attributes.hasAccessToAllBuilds !== "boolean").length;
  const automatic = internal.filter((group) => group.attributes.hasAccessToAllBuilds === true);
  const unexpectedAutomatic = new Set(automatic.flatMap((group) => members.get(group.id)).filter((tester) => !testerKeys(tester).some((key) => selectedKeys.has(key))).map((tester) => tester.id)).size;
  const externalOverlap = overlapCount(selectedMembers, externalKeys);
  const automaticExternalOverlap = new Set(automatic.flatMap((group) => members.get(group.id)).filter((tester) => testerKeys(tester).some((key) => externalKeys.has(key))).map((tester) => tester.id)).size;
  const reasons = [];
  if (!selected) reasons.push("ambiguous-internal-group");
  if (selected && selectedMembers.length === 0) reasons.push("empty-internal-group");
  if (selected && selected.attributes.publicLinkEnabled !== false) reasons.push("internal-public-link-not-disabled");
  if (externalOverlap > 0 || automaticExternalOverlap > 0) reasons.push("existing-external-testers-would-receive-alpha");
  if (automaticUnknown > 0) reasons.push("automatic-build-access-unknown");
  if (unexpectedAutomatic > 0) reasons.push("other-internal-testers-have-all-build-access");
  return {
    app_id: appId, selected_group_id: selected?.id ?? null, internal_group_count: internal.length,
    selected_tester_count: selectedMembers.length, external_overlap_count: externalOverlap,
    automatic_internal_group_count: automatic.length, automatic_unknown_group_count: automaticUnknown,
    unexpected_automatic_tester_count: unexpectedAutomatic, automatic_external_overlap_count: automaticExternalOverlap,
    // All-build access is the API attribute audited here. A false value alone does
    // not prove the separate App Store Connect "Enable automatic distribution" UI.
    automatic_distribution_ui_verified: false,
    recipient_checks_passed: reasons.length === 0, reasons,
  };
}

if (import.meta.filename === process.argv[1]) {
  try { console.log(JSON.stringify(await auditInternalAlpha(), null, 2)); }
  catch {
    // ASC error bodies can contain personal data; never print upstream diagnostics.
    console.error("Internal TestFlight read-only audit failed; no access or distribution was changed.");
    process.exitCode = 1;
  }
}
