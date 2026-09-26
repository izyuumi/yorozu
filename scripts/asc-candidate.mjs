#!/usr/bin/env node
// Resolve an uploaded candidate, then verify the same binary passed App Review.
// Only `distribute` writes: it hands the build to external TestFlight testers.
// Selecting the App Store build, submitting App Review, and releasing stay in ASC.
import { readFileSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { asc } from "./asc.mjs";

const appIdDefault = "6811274963";
const bundleId = "to.yumi.yorozu.ios";
const buildFields = "version,uploadedDate,expirationDate,expired,processingState,buildAudienceType,preReleaseVersion,app";
const query = (path, params) => `${path}?${new URLSearchParams(params)}`;
const requireValue = (condition, message) => { if (!condition) throw new Error(message); };

function validateVersion(version, build) {
  requireValue(typeof version === "string" && /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version), "version must be major.minor.patch");
  requireValue(typeof build === "string" && /^[1-9]\d*$/.test(build), "build must be a positive integer string");
}

async function verifyApp(request, appId) {
  requireValue(typeof appId === "string" && /^[1-9]\d*$/.test(appId), "ASC_APP_ID must be a numeric app ID");
  const { data } = await request("GET", query(`/v1/apps/${appId}`, { "fields[apps]": "bundleId" }));
  requireValue(data?.id === appId && data.attributes?.bundleId === bundleId, `App ${appId} must be ${bundleId}`);
}

export async function nextBuild(version, { request = asc, appId = process.env.ASC_APP_ID || appIdDefault } = {}) {
  validateVersion(version, "1");
  await verifyApp(request, appId);
  let path = query("/v1/builds", {
    "filter[app]": appId, "filter[preReleaseVersion.version]": version,
    "filter[preReleaseVersion.platform]": "IOS", "fields[builds]": "version", limit: "200",
  });
  let highest = 0;
  while (path) {
    const response = await request("GET", path);
    requireValue(Array.isArray(response.data), "ASC returned an invalid builds response");
    for (const item of response.data) {
      const build = item.attributes?.version;
      requireValue(typeof build === "string" && /^[1-9]\d*$/.test(build) && Number.isSafeInteger(Number(build)),
        "ASC returned an invalid build number");
      highest = Math.max(highest, Number(build));
    }
    const next = response.links?.next;
    if (next) {
      const url = new URL(next, "https://api.appstoreconnect.apple.com");
      requireValue(url.origin === "https://api.appstoreconnect.apple.com" && url.pathname === "/v1/builds",
        "ASC returned an invalid builds page URL");
      path = `${url.pathname}${url.search}`;
    } else path = null;
  }
  requireValue(Number.isSafeInteger(highest + 1), "ASC build number is too large");
  return String(highest + 1);
}

function buildMetadata(data, included, { appId, version, build }, now) {
  requireValue(data?.type === "builds" && typeof data.id === "string" && data.id.length > 0, "ASC returned no build ID");
  requireValue(data.relationships?.app?.data?.id === appId, "Build belongs to a different app");
  requireValue(data.attributes?.version === build, "ASC build number does not match candidate");
  const preReleaseId = data.relationships?.preReleaseVersion?.data?.id;
  const preRelease = included?.find((item) => item.type === "preReleaseVersions" && item.id === preReleaseId);
  requireValue(preRelease?.attributes?.platform === "IOS" && preRelease.attributes.version === version,
    "ASC marketing version or platform does not match candidate");
  const attributes = data.attributes;
  requireValue(attributes.processingState === "VALID", `ASC build processing state is ${attributes.processingState}`);
  requireValue(attributes.expired === false && Date.parse(attributes.expirationDate) > now, "ASC build is expired or has no valid expiration date");
  requireValue(attributes.buildAudienceType === "APP_STORE_ELIGIBLE", "ASC build is internal-only or not eligible for the App Store");
  requireValue(Number.isFinite(Date.parse(attributes.uploadedDate)), "ASC build has no valid upload date");
  return { app_id: appId, build_id: data.id, version, build, uploaded_date: attributes.uploadedDate };
}

// Dependency injection keeps the processing wait and all API verification testable offline.
export async function resolveCandidate(version, build, {
  request = asc, appId = process.env.ASC_APP_ID || appIdDefault,
  timeoutMs = Number(process.env.ASC_PROCESSING_TIMEOUT_SECONDS ?? 1800) * 1000,
  pollMs = Number(process.env.ASC_PROCESSING_POLL_SECONDS ?? 30) * 1000,
  now = Date.now, wait = sleep,
} = {}) {
  validateVersion(version, build);
  requireValue(Number.isFinite(timeoutMs) && timeoutMs >= 0, "ASC_PROCESSING_TIMEOUT_SECONDS must be nonnegative");
  requireValue(Number.isFinite(pollMs) && pollMs > 0, "ASC_PROCESSING_POLL_SECONDS must be positive");
  await verifyApp(request, appId);
  const path = query("/v1/builds", {
    "filter[app]": appId, "filter[version]": build,
    "filter[preReleaseVersion.version]": version, "filter[preReleaseVersion.platform]": "IOS",
    include: "preReleaseVersion,app", "fields[builds]": buildFields,
    "fields[preReleaseVersions]": "version,platform", "fields[apps]": "bundleId", limit: "2",
  });
  const deadline = now() + timeoutMs;
  for (;;) {
    const response = await request("GET", path);
    requireValue(Array.isArray(response.data), "ASC returned an invalid builds response");
    requireValue(response.data.length <= 1 && !response.links?.next, "ASC returned multiple builds for the candidate");
    const data = response.data[0];
    if (data && data.attributes?.processingState !== "PROCESSING") {
      return buildMetadata(data, response.included, { appId, version, build }, now());
    }
    const remaining = deadline - now();
    requireValue(remaining > 0, `Timed out waiting for iOS ${version} (${build}) to finish processing`);
    await wait(Math.min(pollMs, remaining));
  }
}

export async function verifyCandidate(candidate, { request = asc, appId = process.env.ASC_APP_ID || appIdDefault, now = Date.now } = {}) {
  const { version, ios } = candidate ?? {};
  const iosBuild = ios?.build;
  validateVersion(version, iosBuild);
  requireValue(ios?.app_id === appId && ios.version === version && ios.build === iosBuild, "Candidate iOS metadata does not match version, build, or app");
  requireValue(typeof ios.build_id === "string" && /^[A-Za-z0-9-]+$/.test(ios.build_id), "Candidate has no valid ASC build ID");
  requireValue(typeof ios.uploaded_date === "string" && Number.isFinite(Date.parse(ios.uploaded_date)), "Candidate has no valid iOS upload date");
  await verifyApp(request, appId);
  const response = await request("GET", query(`/v1/builds/${ios.build_id}`, {
    include: "preReleaseVersion,app", "fields[builds]": buildFields,
    "fields[preReleaseVersions]": "version,platform", "fields[apps]": "bundleId",
  }));
  const actual = buildMetadata(response.data, response.included, { appId, version, build: iosBuild }, now());
  requireValue(actual.build_id === ios.build_id && actual.uploaded_date === ios.uploaded_date, "ASC build ID or upload date does not match candidate");
  const versions = await request("GET", query(`/v1/apps/${appId}/appStoreVersions`, {
    "filter[versionString]": version, "filter[platform]": "IOS", include: "build",
    "fields[appStoreVersions]": "platform,versionString,appVersionState,appStoreState,build", "fields[builds]": "version", limit: "2",
  }));
  requireValue(Array.isArray(versions.data) && versions.data.length === 1 && !versions.links?.next, `Expected one iOS App Store version ${version}`);
  const storeVersion = versions.data[0];
  requireValue(storeVersion.attributes?.platform === "IOS" && storeVersion.attributes.versionString === version, "App Store version does not match candidate");
  requireValue(storeVersion.relationships?.build?.data?.id === ios.build_id, "App Store version has a different selected build");
  // appVersionState replaces deprecated appStoreState; never prefer a stale legacy value.
  const state = storeVersion.attributes.appVersionState ?? storeVersion.attributes.appStoreState;
  requireValue(["PENDING_DEVELOPER_RELEASE", "READY_FOR_DISTRIBUTION", "READY_FOR_SALE"].includes(state),
    `App Store version is ${state}; exact candidate must be approved before promotion`);
  return { ...actual, app_store_version_id: storeVersion.id, state };
}

// Add the resolved build to the external group and submit it for Beta App Review.
export async function distributeExternal(ios, { request = asc, group = process.env.ASC_EXTERNAL_GROUP || "Public" } = {}) {
  requireValue(typeof ios?.build_id === "string" && /^[A-Za-z0-9-]+$/.test(ios.build_id), "Candidate has no valid ASC build ID");
  const groups = await request("GET", query("/v1/betaGroups", {
    "filter[app]": ios.app_id, "filter[name]": group, "filter[isInternalGroup]": "false",
    "fields[betaGroups]": "name,isInternalGroup", limit: "2",
  }));
  const matches = groups.data?.filter((item) => item.attributes?.name === group && item.attributes.isInternalGroup === false) ?? [];
  requireValue(matches.length === 1, `Expected one external beta group named ${group}`);
  await request("POST", `/v1/betaGroups/${matches[0].id}/relationships/builds`, { data: [{ type: "builds", id: ios.build_id }] });
  await request("POST", "/v1/betaAppReviewSubmissions", {
    data: { type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: ios.build_id } } } },
  });
  return matches[0].id;
}

if (import.meta.filename === process.argv[1]) {
  const [command, ...args] = process.argv.slice(2);
  try {
    if (command === "next-build" && args.length === 1) {
      console.log(await nextBuild(args[0]));
    } else if (command === "resolve" && args.length === 3) {
      const result = await resolveCandidate(args[0], args[1]);
      writeFileSync(args[2], `${JSON.stringify(result, null, 2)}\n`);
      console.log(`Resolved iOS ${result.version} (${result.build}): ${result.build_id}`);
    } else if (command === "verify" && args.length === 1) {
      const result = await verifyCandidate(JSON.parse(readFileSync(args[0], "utf8")));
      console.log(`Verified iOS ${result.version} (${result.build}): ${result.state}`);
    } else if (command === "distribute" && args.length === 1) {
      const ios = JSON.parse(readFileSync(args[0], "utf8"));
      await distributeExternal(ios);
      console.log(`Submitted iOS ${ios.version} (${ios.build}) for external TestFlight review`);
    } else {
      throw new Error("Usage: asc-candidate.mjs next-build VERSION | resolve VERSION BUILD OUTPUT | verify CANDIDATE_JSON | distribute IOS_JSON");
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
