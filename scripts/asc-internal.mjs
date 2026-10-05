#!/usr/bin/env node
// This release lane can assign builds only to the established internal group.
// It never reads tester personal data or submits a build for beta/App Store review.
import { readFileSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { asc } from "./asc.mjs";

const appId = "6811274963";
const groupId = "954b8070-0ad9-4112-a061-2001bdc150b7";
const origin = "https://api.appstoreconnect.apple.com";
const groupPath = `/v1/betaGroups/${groupId}/relationships`;
const buildFields = "version,uploadedDate,expirationDate,expired,processingState,buildAudienceType,preReleaseVersion,app";
const query = (path, values) => `${path}?${new URLSearchParams(values)}`;
const requireValue = (condition, message) => { if (!condition) throw new Error(message); };
const validId = (id) => typeof id === "string" && /^[A-Za-z0-9-]+$/.test(id);

// Kept at the request boundary so pagination and future callers cannot widen this lane.
export function internalRequest(request = asc, mode = "verify") {
  requireValue(["preflight", "resolve", "verify", "distribute"].includes(mode), "Invalid internal TestFlight request mode");
  // Read-only is enforced here, not merely by today's caller control flow.
  const allowAssignment = mode === "distribute";
  return async (method, path, body) => {
    const url = new URL(path, origin);
    const read = url.pathname === `/v1/apps/${appId}` || url.pathname === `/v1/apps/${appId}/betaGroups`
      || url.pathname === `${groupPath}/betaTesters` || url.pathname === `${groupPath}/builds`
      || url.pathname === "/v1/builds" || /^\/v1\/builds\/[A-Za-z0-9-]+(?:\/buildBetaDetail)?$/.test(url.pathname);
    const assign = url.pathname === `${groupPath}/builds` && !url.search
      && Array.isArray(body?.data) && body.data.length === 1
      && body.data[0].type === "builds" && validId(body.data[0].id);
    requireValue(url.origin === origin && !url.username && !url.password && !url.hash
      && (method === "GET" && read && body === undefined || method === "POST" && allowAssignment && assign),
    "Request is outside the internal TestFlight lane");
    return request(method, `${url.pathname}${url.search}`, body);
  };
}

async function pages(request, path) {
  const pathname = new URL(path, origin).pathname;
  const seen = new Set();
  const rows = [];
  while (path) {
    const url = new URL(path, origin);
    requireValue(url.origin === origin && url.pathname === pathname && !seen.has(url.href) && seen.size < 1000,
      "Invalid internal TestFlight pagination");
    seen.add(url.href);
    const response = await request("GET", path);
    requireValue(Array.isArray(response.data), "Invalid internal TestFlight list");
    rows.push(...response.data);
    path = response.links?.next;
  }
  return rows;
}

export async function preflightInternal({ request = asc } = {}) {
  request = internalRequest(request, "preflight");
  const app = await request("GET", query(`/v1/apps/${appId}`, { "fields[apps]": "bundleId" }));
  requireValue(app.data?.id === appId && app.data.attributes?.bundleId === "to.yumi.yorozu.ios", "Wrong internal TestFlight app");
  const groups = await pages(request, query(`/v1/apps/${appId}/betaGroups`, {
    "fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled", limit: "200",
  }));
  const selected = groups.filter((group) => group.id === groupId);
  requireValue(selected.length === 1 && selected[0].type === "betaGroups"
    && selected[0].attributes?.isInternalGroup === true && selected[0].attributes.publicLinkEnabled !== true,
  "Established internal group is missing or is not internal");
  requireValue(groups.every((group) => typeof group.attributes?.isInternalGroup === "boolean"
    && (group.id === groupId || !group.attributes.isInternalGroup || group.attributes.hasAccessToAllBuilds === false)),
  "Another internal group may receive this build automatically");
  const testers = await pages(request, `${groupPath}/betaTesters?limit=200`);
  requireValue(testers.length === 1 && testers[0].type === "betaTesters" && validId(testers[0].id),
    "Established internal group must still contain exactly one tester");
  return { app_id: appId, group_id: groupId, tester_count: testers.length };
}

function validateVersion(version, build) {
  requireValue(version === "0.6.0", "Internal release version must be 0.6.0");
  requireValue(typeof build === "string" && /^[1-9]\d*$/.test(build), "Internal build must be a positive integer");
}

function metadata(response, version, build, now) {
  const data = response.data;
  requireValue(data?.type === "builds" && validId(data.id), "Invalid internal build ID");
  requireValue(data.relationships?.app?.data?.id === appId, "Internal build belongs to another app");
  requireValue(data.attributes?.version === build, "Internal build number mismatch");
  const preRelease = response.included?.find((item) => item.type === "preReleaseVersions"
    && item.id === data.relationships?.preReleaseVersion?.data?.id);
  requireValue(preRelease?.attributes?.version === version && preRelease.attributes.platform === "IOS", "Internal version or platform mismatch");
  const attrs = data.attributes;
  requireValue(attrs.processingState === "VALID", `Internal build processing state is ${attrs.processingState}`);
  requireValue(attrs.buildAudienceType === "INTERNAL_ONLY", "Build is not INTERNAL_ONLY");
  requireValue(attrs.expired === false && Date.parse(attrs.expirationDate) > now, "Internal build is expired");
  requireValue(Number.isFinite(Date.parse(attrs.uploadedDate)), "Internal upload date is missing");
  return { app_id: appId, group_id: groupId, build_id: data.id, version, build,
    uploaded_date: attrs.uploadedDate, internal_only: true };
}

function clock(options) {
  const timeoutMs = options.timeoutMs ?? Number(process.env.ASC_PROCESSING_TIMEOUT_SECONDS ?? 1800) * 1000;
  const pollMs = options.pollMs ?? Number(process.env.ASC_PROCESSING_POLL_SECONDS ?? 30) * 1000;
  const now = options.now ?? Date.now;
  requireValue(Number.isFinite(timeoutMs) && timeoutMs >= 0 && Number.isFinite(pollMs) && pollMs > 0, "Invalid internal processing timeout");
  const deadline = now() + timeoutMs;
  return { now, pause: async () => {
    requireValue(now() < deadline, "Timed out waiting for internal TestFlight availability");
    await (options.wait ?? sleep)(Math.min(pollMs, deadline - now()));
  } };
}

export async function resolveInternal(version, build, options = {}) {
  validateVersion(version, build);
  const request = internalRequest(options.request, "resolve");
  await preflightInternal({ request });
  const { now, pause } = clock(options);
  const path = query("/v1/builds", {
    "filter[app]": appId, "filter[version]": build, "filter[preReleaseVersion.version]": version,
    "filter[preReleaseVersion.platform]": "IOS", include: "preReleaseVersion,app",
    "fields[builds]": buildFields, "fields[preReleaseVersions]": "version,platform", "fields[apps]": "bundleId", limit: "2",
  });
  for (;;) {
    const response = await request("GET", path);
    requireValue(Array.isArray(response.data) && response.data.length <= 1 && !response.links?.next, "Ambiguous internal build");
    const data = response.data[0];
    if (data && data.attributes?.processingState !== "PROCESSING") return metadata({ ...response, data }, version, build, now());
    await pause();
  }
}

async function verifyBuild(ios, request, now) {
  validateVersion(ios?.version, ios?.build);
  requireValue(ios.app_id === appId && ios.group_id === groupId && ios.internal_only === true && validId(ios.build_id),
    "Invalid internal build manifest");
  const response = await request("GET", query(`/v1/builds/${ios.build_id}`, {
    include: "preReleaseVersion,app", "fields[builds]": buildFields,
    "fields[preReleaseVersions]": "version,platform", "fields[apps]": "bundleId",
  }));
  const actual = metadata(response, ios.version, ios.build, now());
  requireValue(actual.build_id === ios.build_id && actual.uploaded_date === ios.uploaded_date, "Internal build identity changed");
}

async function assigned(request, buildId) {
  const builds = await pages(request, `${groupPath}/builds?limit=200`);
  return builds.some((build) => build.type === "builds" && build.id === buildId);
}

export async function makeInternalAvailable(ios, { assign = false, ...options } = {}) {
  requireValue(typeof assign === "boolean", "Internal assignment mode must be boolean");
  const request = internalRequest(options.request, assign ? "distribute" : "verify");
  const { now, pause } = clock(options);
  await preflightInternal({ request });
  await verifyBuild(ios, request, now);
  if (assign && !await assigned(request, ios.build_id)) {
    await request("POST", `${groupPath}/builds`, { data: [{ type: "builds", id: ios.build_id }] });
  }
  for (;;) {
    await verifyBuild(ios, request, now);
    const detail = await request("GET", `/v1/builds/${ios.build_id}/buildBetaDetail`);
    requireValue(detail.data?.type === "buildBetaDetails" && detail.data.id === ios.build_id,
      "Internal testing detail belongs to another build");
    const attrs = detail.data?.attributes;
    requireValue(attrs && !["EXPIRED", "PROCESSING_EXCEPTION", "MISSING_EXPORT_COMPLIANCE"].includes(attrs.internalBuildState),
      `Internal TestFlight is blocked: ${attrs?.internalBuildState}`);
    requireValue(attrs.externalBuildState !== "IN_BETA_TESTING", "Internal build is unexpectedly available externally");
    if (attrs.internalBuildState === "IN_BETA_TESTING" && await assigned(request, ios.build_id)) {
      await preflightInternal({ request });
      return { ...ios, internal_state: attrs.internalBuildState, available: true, verified_at: new Date(now()).toISOString() };
    }
    await pause();
  }
}

if (import.meta.filename === process.argv[1]) {
  try {
    const [command, ...args] = process.argv.slice(2);
    let result;
    if (command === "preflight" && args.length === 0) result = await preflightInternal();
    else if (command === "resolve" && args.length === 3) {
      result = await resolveInternal(args[0], args[1]);
      writeFileSync(args[2], `${JSON.stringify(result, null, 2)}\n`);
    } else if (["distribute", "verify"].includes(command) && args.length === 2) {
      result = await makeInternalAvailable(JSON.parse(readFileSync(args[0], "utf8")), { assign: command === "distribute" });
      writeFileSync(args[1], `${JSON.stringify(result, null, 2)}\n`);
    } else throw new Error("Usage: asc-internal.mjs preflight | resolve VERSION BUILD OUTPUT | distribute|verify IOS_JSON OUTPUT");
    console.log(JSON.stringify(result, null, 2));
  } catch (error) {
    // Upstream diagnostics may contain private account data; preserve only local guard messages.
    console.error(error.message.includes("→") ? "Internal TestFlight request failed; inspect App Store Connect." : error.message);
    process.exitCode = 1;
  }
}
