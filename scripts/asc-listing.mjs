#!/usr/bin/env node
// Apply Yorozu iOS 0.2.0 listing. Never creates a review submission.
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { asc } from "./asc.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const appId = "6811274963";
const versionString = "0.2.0";
const listing = {
  description: `Yorozu connects your iPhone to the AI agents running on your own Mac, OpenClaw, Claude Code and Codex, so you can start a task from the couch, approve a command from the lock screen, and pick the thread up again at your desk.

• End-to-end encrypted: messages are sealed on your devices. Yorozu's relay only passes ciphertext it has no key for.
• Approvals on the lock screen: when an agent needs a yes or no, answer from the notification.
• Threads that follow you: conversations stay in sync between your Mac and iPhone, with search, pinning and archive.
• Coding agents too: start a Claude Code or Codex session in a project folder on your Mac and watch it work.
• No Yorozu account: pair once with a QR code. Your agents, models and credentials stay on your Mac.

Yorozu needs the free Yorozu app for Mac (macOS 15 or later, Apple silicon) with OpenClaw installed: yorozu.yumi.to. To look around first, tap "Try the demo" on the pairing screen.

Important: Anthropic and OpenAI set their own rules for using their subscriptions with third-party tools. Driving Claude Code or Codex through Yorozu with a subscription login may put that account at risk. See yorozu.yumi.to/terms.

Yorozu is open source under the MIT license. It is not affiliated with OpenClaw, Anthropic or OpenAI.`,
  keywords: "AI agent,remote,Mac,assistant,coding,approvals,encrypted,automation,companion,tasks",
  promotionalText: "Start tasks, answer approvals from the lock screen, and follow progress from your iPhone while OpenClaw, Claude Code or Codex work on your Mac.",
  supportUrl: "https://github.com/izyuumi/yorozu/issues",
  marketingUrl: "https://yorozu.yumi.to",
  subtitle: "Your Mac's AI agents, anywhere",
  privacyPolicyUrl: "https://yorozu.yumi.to/privacy/",
  notes: "Yorozu is a remote for AI agents that run on the user's own Mac, so a real session needs the free Yorozu Mac app, which is distributed outside the Mac App Store at https://yorozu.yumi.to/mac. To review without a Mac, tap \"Try the demo\" on the first screen. It opens sample threads, including a Claude Code and a Codex thread, a pending approval card, a progress card and a question card. Sending a message in the demo returns an explanatory reply. No account or sign-in is needed. Pairing with a real Mac uses a one-time code that expires after 10 minutes, which is why we provide the demo instead of a code. Encryption uses Apple's CryptoKit only. Source code: https://github.com/izyuumi/yorozu",
};
const result = {};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const data = (type, id, attributes, relationships) => ({ data: { type, ...(id && { id }), ...(attributes && { attributes }), ...(relationships && { relationships }) } });
const changed = (actual, expected) => Object.entries(expected).some(([key, value]) => actual[key] !== value);
const get = async (path) => (await asc("GET", path)).data;
const list = async (path) => (await asc("GET", path)).data;
const patch = (type, id, attributes, relationships) => asc("PATCH", `/v1/${type}/${id}`, data(type, id, attributes, relationships));
const mask = (phone) => phone ? `${"*".repeat(Math.max(0, phone.length - 2))}${phone.slice(-2)}` : null;

async function findPhone() {
  const apps = await list("/v1/apps?limit=200");
  const candidates = [];
  for (const app of apps.filter((app) => app.id !== appId)) {
    const versions = await list(`/v1/apps/${app.id}/appStoreVersions?include=appStoreReviewDetail&fields[appStoreReviewDetails]=contactPhone&limit=200`);
    for (const version of versions) {
      const detail = await get(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`);
      if (detail?.attributes.contactPhone) candidates.push({ createdDate: version.attributes.createdDate, phone: detail.attributes.contactPhone });
    }
  }
  return candidates.sort((a, b) => b.createdDate.localeCompare(a.createdDate))[0]?.phone;
}

async function ensureVersion() {
  const versions = await list(`/v1/apps/${appId}/appStoreVersions?limit=200`);
  const editable = new Set(["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "METADATA_REJECTED", "REJECTED", "INVALID_BINARY"]);
  let version = versions.find((v) => v.attributes.platform === "IOS" && v.attributes.versionString === versionString && editable.has(v.attributes.appStoreState));
  let action = "skipped-already-set";
  if (!version) {
    version = versions.find((v) => v.attributes.platform === "IOS" && editable.has(v.attributes.appStoreState));
    if (version) {
      await patch("appStoreVersions", version.id, { versionString, releaseType: "MANUAL", copyright: "2026 Yumi Izumi" });
      action = "done-renamed";
    } else {
      version = (await asc("POST", "/v1/appStoreVersions", data("appStoreVersions", null, { platform: "IOS", versionString, releaseType: "MANUAL", copyright: "2026 Yumi Izumi" }, { app: { data: { type: "apps", id: appId } } }))).data;
      action = "done-created";
    }
  }
  const desired = { versionString, releaseType: "MANUAL", copyright: "2026 Yumi Izumi" };
  if (changed(version.attributes, desired)) {
    await patch("appStoreVersions", version.id, desired);
    action = action === "skipped-already-set" ? "done" : action;
  }
  result.version = action;
  return get(`/v1/appStoreVersions/${version.id}`);
}

async function ensureVersionLocalization(version) {
  let localization = (await list(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations?filter[locale]=en-US&limit=1`))[0];
  if (!localization) {
    localization = (await asc("POST", "/v1/appStoreVersionLocalizations", data("appStoreVersionLocalizations", null, { locale: "en-US", ...listingFields() }, { appStoreVersion: { data: { type: "appStoreVersions", id: version.id } } }))).data;
    result.versionLocalization = "done-created";
  } else if (changed(localization.attributes, listingFields())) {
    await patch("appStoreVersionLocalizations", localization.id, listingFields());
    result.versionLocalization = "done";
  } else result.versionLocalization = "skipped-already-set";
  return get(`/v1/appStoreVersionLocalizations/${localization.id}`);
}
const listingFields = () => ({ description: listing.description, keywords: listing.keywords, promotionalText: listing.promotionalText, supportUrl: listing.supportUrl, marketingUrl: listing.marketingUrl });

async function ensureAppInfo() {
  const info = (await list(`/v1/apps/${appId}/appInfos?limit=200`))[0];
  let localization = (await list(`/v1/appInfos/${info.id}/appInfoLocalizations?filter[locale]=en-US&limit=1`))[0];
  const fields = { subtitle: listing.subtitle, privacyPolicyUrl: listing.privacyPolicyUrl };
  if (!localization) {
    localization = (await asc("POST", "/v1/appInfoLocalizations", data("appInfoLocalizations", null, { locale: "en-US", name: "Yorozu", ...fields }, { appInfo: { data: { type: "appInfos", id: info.id } } }))).data;
    result.appInfoLocalization = "done-created";
  } else {
    const update = { ...fields, ...(localization.attributes.name === "Yorozu" ? {} : { name: "Yorozu" }) };
    if (changed(localization.attributes, update)) {
      await patch("appInfoLocalizations", localization.id, update);
      result.appInfoLocalization = "done";
    } else result.appInfoLocalization = "skipped-already-set";
  }
  const [primary, secondary] = await Promise.all([get(`/v1/appInfos/${info.id}/primaryCategory`), get(`/v1/appInfos/${info.id}/secondaryCategory`)]);
  if (primary?.id !== "PRODUCTIVITY" || secondary?.id !== "DEVELOPER_TOOLS") {
    await patch("appInfos", info.id, null, { primaryCategory: { data: { type: "appCategories", id: "PRODUCTIVITY" } }, secondaryCategory: { data: { type: "appCategories", id: "DEVELOPER_TOOLS" } } });
    result.categories = "done";
  } else result.categories = "skipped-already-set";
  return get(`/v1/appInfos/${info.id}`);
}

async function ensureDeclarations(info) {
  const app = await get(`/v1/apps/${appId}`);
  if (app.attributes.contentRightsDeclaration !== "DOES_NOT_USE_THIRD_PARTY_CONTENT") {
    await patch("apps", appId, { contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT" });
    result.contentRights = "done";
  } else result.contentRights = "skipped-already-set";
  const declaration = await get(`/v1/appInfos/${info.id}/ageRatingDeclaration`);
  const attributes = {
    advertising: false, alcoholTobaccoOrDrugUseOrReferences: "NONE", contests: "NONE", gambling: false, gamblingSimulated: "NONE",
    gunsOrOtherWeapons: "NONE", healthOrWellnessTopics: false, lootBox: false, medicalOrTreatmentInformation: "NONE", messagingAndChat: false,
    parentalControls: false, profanityOrCrudeHumor: "NONE", sexualContentGraphicAndNudity: "NONE", sexualContentOrNudity: "NONE",
    ageAssurance: false, socialMedia: false, socialMediaAgeRestricted: false, horrorOrFearThemes: "NONE", matureOrSuggestiveThemes: "NONE",
    unrestrictedWebAccess: true, userGeneratedContent: false, violenceCartoonOrFantasy: "NONE", violenceRealisticProlongedGraphicOrSadistic: "NONE", violenceRealistic: "NONE",
  };
  if (changed(declaration.attributes, attributes)) {
    await patch("ageRatingDeclarations", declaration.id, attributes);
    result.ageRating = "done";
  } else result.ageRating = "skipped-already-set";
}

async function ensureReviewDetail(version) {
  let detail = await get(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`);
  const phone = detail?.attributes.contactPhone || await findPhone();
  if (!phone) throw new Error("blocked: no App Review contact phone exists on Yorozu or another app");
  const attributes = { contactFirstName: "Yumi", contactLastName: "Izumi", contactEmail: "mail@yumi.to", contactPhone: phone, demoAccountRequired: false, notes: listing.notes };
  if (!detail) {
    detail = (await asc("POST", "/v1/appStoreReviewDetails", data("appStoreReviewDetails", null, attributes, { appStoreVersion: { data: { type: "appStoreVersions", id: version.id } } }))).data;
    result.reviewDetail = "done-created";
  } else if (changed(detail.attributes, attributes)) {
    await patch("appStoreReviewDetails", detail.id, attributes);
    result.reviewDetail = "done";
  } else result.reviewDetail = "skipped-already-set";
  return get(`/v1/appStoreReviewDetails/${detail.id}`);
}

async function ensureAvailabilityAndPricing() {
  const price = await get(`/v1/apps/${appId}/appPriceSchedule`);
  result.pricing = price ? "skipped-already-set" : "blocked: no price schedule";
  try {
    await get(`/v1/apps/${appId}/appAvailabilityV2`);
    result.availability = "skipped-already-set";
  } catch (error) {
    if (!error.message.includes("NOT_FOUND")) throw error;
    const territories = await list("/v1/territories?limit=200");
    const localId = (territory) => `\${${territory.id}}`;
    const included = territories.map((territory) => ({ type: "territoryAvailabilities", id: localId(territory), attributes: { available: true }, relationships: { territory: { data: { type: "territories", id: territory.id } } } }));
    await asc("POST", "/v2/appAvailabilities", {
      data: { type: "appAvailabilities", attributes: { availableInNewTerritories: true }, relationships: { app: { data: { type: "apps", id: appId } }, territoryAvailabilities: { data: territories.map((territory) => ({ type: "territoryAvailabilities", id: localId(territory) })) } } },
      included,
    });
    result.availability = "done-all-territories";
  }
}

const md5 = (file) => createHash("md5").update(readFileSync(file)).digest("hex");
const files = (dir) => readdirSync(join(root, dir)).filter((file) => file.endsWith(".png")).sort().map((file) => ({ name: file, path: join(root, dir, file), checksum: md5(join(root, dir, file)) }));

async function upload(file, setId) {
  const screenshot = (await asc("POST", "/v1/appScreenshots", data("appScreenshots", null, { fileName: file.name, fileSize: readFileSync(file.path).length }, { appScreenshotSet: { data: { type: "appScreenshotSets", id: setId } } }))).data;
  const bytes = readFileSync(file.path);
  for (const op of screenshot.attributes.uploadOperations) {
    const response = await fetch(op.url, { method: op.method, headers: Object.fromEntries(op.requestHeaders.map((header) => [header.name, header.value])), body: bytes.subarray(op.offset, op.offset + op.length) });
    if (!response.ok) throw new Error(`upload ${file.name}: ${response.status} ${await response.text()}`);
  }
  await patch("appScreenshots", screenshot.id, { uploaded: true, sourceFileChecksum: file.checksum });
  return screenshot.id;
}

async function waitForScreenshots(ids) {
  const final = [];
  for (const id of ids) {
    let screenshot;
    for (;;) {
      screenshot = await get(`/v1/appScreenshots/${id}`);
      const state = screenshot.attributes.assetDeliveryState?.state;
      if (state === "COMPLETE") break;
      if (state === "FAILED") throw new Error(`screenshot ${screenshot.attributes.fileName} FAILED: ${JSON.stringify(screenshot.attributes.assetDeliveryState)}`);
      await sleep(5000);
    }
    final.push(screenshot);
  }
  return final;
}

async function ensureScreenshots(localization) {
  for (const spec of [
    { type: "APP_IPHONE_67", dir: "docs/app-store/screenshots/iphone-6.9" },
    { type: "APP_IPAD_PRO_3GEN_129", dir: "docs/app-store/screenshots/ipad-13" },
  ]) {
    const expected = files(spec.dir);
    let set = (await list(`/v1/appStoreVersionLocalizations/${localization.id}/appScreenshotSets?filter[screenshotDisplayType]=${spec.type}&limit=1`))[0];
    let touched = false;
    if (!set) {
      set = (await asc("POST", "/v1/appScreenshotSets", data("appScreenshotSets", null, { screenshotDisplayType: spec.type }, { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: localization.id } } }))).data;
      touched = true;
    }
    let existing = await list(`/v1/appScreenshotSets/${set.id}/appScreenshots?limit=50`);
    const keep = new Map(existing.filter((shot) => expected.some((file) => file.name === shot.attributes.fileName && file.checksum === shot.attributes.sourceFileChecksum && shot.attributes.assetDeliveryState?.state !== "FAILED")).map((shot) => [shot.attributes.fileName, shot]));
    for (const shot of existing.filter((shot) => !keep.has(shot.attributes.fileName))) {
      await asc("DELETE", `/v1/appScreenshots/${shot.id}`);
      touched = true;
    }
    const ids = [];
    for (const file of expected) {
      const id = keep.get(file.name)?.id || await upload(file, set.id);
      touched ||= !keep.has(file.name);
      ids.push(id);
    }
    await waitForScreenshots(ids);
    const currentIds = (await list(`/v1/appScreenshotSets/${set.id}/appScreenshots?limit=50`)).map((shot) => shot.id);
    if (currentIds.join(",") !== ids.join(",")) {
      await asc("PATCH", `/v1/appScreenshotSets/${set.id}/relationships/appScreenshots`, { data: ids.map((id) => ({ type: "appScreenshots", id })) });
      touched = true;
    }
    result[`screenshots-${spec.type}`] = touched ? "done" : "skipped-already-set";
  }
}

async function attachBuild(version) {
  const deadline = Date.now() + 40 * 60 * 1000;
  let build;
  do {
    const builds = await asc("GET", `/v1/builds?filter[app]=${appId}&include=preReleaseVersion&fields[builds]=version,processingState,preReleaseVersion&fields[preReleaseVersions]=version&limit=200`);
    const releaseVersions = new Map((builds.included || []).filter((item) => item.type === "preReleaseVersions").map((item) => [item.id, item.attributes.version]));
    build = builds.data.find((item) => item.attributes.version === "220" && releaseVersions.get(item.relationships.preReleaseVersion?.data?.id) === versionString);
    const state = build?.attributes.processingState || "NOT_FOUND";
    console.log(`build 220: ${state}`);
    if (state === "VALID") break;
    if (Date.now() >= deadline) {
      result.build = `blocked: ${state}`;
      return;
    }
    await sleep(60000);
  } while (true);
  const attached = await get(`/v1/appStoreVersions/${version.id}/build`);
  if (attached?.id !== build.id) await asc("PATCH", `/v1/appStoreVersions/${version.id}/relationships/build`, { data: { type: "builds", id: build.id } });
  result.build = attached?.id === build.id ? "skipped-already-set" : "done-attached";
}

async function readback(version, localization, info) {
  const [app, versionNow, versionLoc, infoNow, infoLoc, primary, secondary, age, review, price, availability, build] = await Promise.all([
    get(`/v1/apps/${appId}`), get(`/v1/appStoreVersions/${version.id}`), get(`/v1/appStoreVersionLocalizations/${localization.id}`), get(`/v1/appInfos/${info.id}`),
    list(`/v1/appInfos/${info.id}/appInfoLocalizations?filter[locale]=en-US&limit=1`), get(`/v1/appInfos/${info.id}/primaryCategory`), get(`/v1/appInfos/${info.id}/secondaryCategory`),
    get(`/v1/appInfos/${info.id}/ageRatingDeclaration`), get(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`), get(`/v1/apps/${appId}/appPriceSchedule`),
    get(`/v1/apps/${appId}/appAvailabilityV2`).catch(() => null), get(`/v1/appStoreVersions/${version.id}/build`).catch(() => null),
  ]);
  const baseTerritory = price && await get(`/v1/appPriceSchedules/${price.id}/baseTerritory`).catch(() => null);
  const sets = await list(`/v1/appStoreVersionLocalizations/${localization.id}/appScreenshotSets?limit=200`);
  const screenshots = {};
  for (const set of sets.filter((set) => ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129"].includes(set.attributes.screenshotDisplayType))) screenshots[set.attributes.screenshotDisplayType] = (await list(`/v1/appScreenshotSets/${set.id}/appScreenshots?limit=50`)).map((shot) => ({ fileName: shot.attributes.fileName, deliveryState: shot.attributes.assetDeliveryState?.state, error: shot.attributes.assetDeliveryState?.errors || null }));
  const state = {
    app: { id: app.id, bundleId: app.attributes.bundleId, contentRightsDeclaration: app.attributes.contentRightsDeclaration },
    version: versionNow.attributes, versionLocalization: versionLoc.attributes,
    appInfoLocalization: infoLoc[0]?.attributes, categories: { primary: primary?.id, secondary: secondary?.id },
    ageRatingDeclaration: age.attributes, computedAgeRating: infoNow.attributes.appStoreAgeRating,
    reviewDetail: review && { ...review.attributes, contactPhone: mask(review.attributes.contactPhone) },
    priceSchedule: price && { id: price.id, baseTerritory: baseTerritory && { id: baseTerritory.id, currency: baseTerritory.attributes.currency }, price: "pre-existing schedule left unchanged" }, availability: availability?.attributes,
    screenshots, attachedBuild: build?.attributes.version || null, results: result,
  };
  mkdirSync("/tmp/asc-review", { recursive: true });
  writeFileSync("/tmp/asc-review/state.json", `${JSON.stringify(state, null, 2)}\n`);
  return state;
}

async function main() {
  const version = await ensureVersion();
  const localization = await ensureVersionLocalization(version);
  const info = await ensureAppInfo();
  await ensureDeclarations(info);
  await ensureReviewDetail(version);
  await ensureAvailabilityAndPricing();
  await ensureScreenshots(localization);
  await attachBuild(version);
  const state = await readback(version, localization, info);
  console.log(JSON.stringify({ results: result, computedAgeRating: state.computedAgeRating, attachedBuild: state.attachedBuild, reviewState: "/tmp/asc-review/state.json" }, null, 2));
}

main().catch((error) => { console.error(error.stack || error.message); process.exitCode = 1; });
