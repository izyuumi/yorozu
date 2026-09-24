#!/usr/bin/env node
// Validate locally by default; --apply updates Yorozu iOS 0.4.0. Never submits for review.
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { asc } from "./asc.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const appId = "6811274963";
const versionString = "0.4.0";
const versionId = "170d8b17-739e-4df5-8e52-135a10c20fe2";
const infoId = "742a0425-c931-4ec4-97c0-d7f26a4ed936";
const buildId = "ee3786cc-7e74-476c-b48e-192c8a5d6432";
const buildNumber = "10";
const sourcePath = join(root, `docs/app-store/listing-${versionString}.md`);
const source = readFileSync(sourcePath, "utf8");
const fields = [
  ["Name", "name", 30], ["Subtitle", "subtitle", 30],
  ["Promotional text", "promotionalText", 170], ["Description", "description", 4000],
  ["Keywords", "keywords", 100], ["What's new", "whatsNew", 4000],
  ["Support URL", "supportUrl", 1000], ["Marketing URL", "marketingUrl", 1000],
  ["Privacy policy URL", "privacyPolicyUrl", 1000], ["Review notes", "notes", 4000],
];
const listing = {};
const lengths = {};
const screenshotSpecs = [
  { type: "APP_IPHONE_67", dir: "docs/app-store/screenshots/iphone-6.9", width: 1320, height: 2868 },
  { type: "APP_IPAD_PRO_3GEN_129", dir: "docs/app-store/screenshots/ipad-13", width: 2064, height: 2752 },
];
const editable = new Set(["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "METADATA_REJECTED", "REJECTED", "INVALID_BINARY"]);
function check(condition, message) { if (!condition) throw new Error(message); }
function validateLocal() {
  check(source.split("\n")[0] === `# App Store listing — Yorozu ${versionString} (iOS)`, "Listing source/version mismatch");
  const sections = [...source.matchAll(/^## ([^\n]+)\n([\s\S]*?)(?=^## |$(?![\s\S]))/gm)];
  for (const [heading, key, limit] of fields) {
    const matches = sections.filter((section) => section[1] === heading);
    check(matches.length === 1, `Expected exactly one ## ${heading} section`);
    listing[key] = matches[0][2].trim();
    const byteLimit = key === "keywords" || key === "notes";
    lengths[key] = byteLimit ? Buffer.byteLength(listing[key]) : Array.from(listing[key]).length;
    check(lengths[key] > 0 && lengths[key] <= limit, `${heading}: ${lengths[key]}/${limit} ${byteLimit ? "bytes" : "characters"}`);
    if (key.endsWith("Url")) check(new URL(listing[key]).protocol === "https:", `${heading} must be HTTPS`);
  }
  for (const spec of screenshotSpecs) {
    spec.files = files(spec.dir);
    check(spec.files.length >= 1 && spec.files.length <= 10, `${spec.dir}: expected 1–10 screenshots`);
    for (const file of spec.files) {
      const bytes = readFileSync(file.path);
      check(bytes.length >= 24 && bytes.subarray(0, 8).toString("hex") === "89504e470d0a1a0a", `${file.name}: invalid PNG`);
      check(bytes.readUInt32BE(16) === spec.width && bytes.readUInt32BE(20) === spec.height, `${file.name}: expected ${spec.width}×${spec.height}`);
    }
  }
}
const result = {};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const data = (type, id, attributes, relationships) => ({ data: { type, ...(id && { id }), ...(attributes && { attributes }), ...(relationships && { relationships }) } });
const changed = (actual, expected) => Object.entries(expected).some(([key, value]) => actual[key] !== value);
const get = async (path) => (await asc("GET", path)).data;
const list = async (path) => (await asc("GET", path)).data;
const patch = (type, id, attributes, relationships) => asc("PATCH", `/v1/${type}/${id}`, data(type, id, attributes, relationships));
const mask = (phone) => phone ? `${"*".repeat(Math.max(0, phone.length - 2))}${phone.slice(-2)}` : null;

async function preflight() {
  const [versions, infos, build, release, buildApp] = await Promise.all([
    list(`/v1/apps/${appId}/appStoreVersions?limit=200`), list(`/v1/apps/${appId}/appInfos?limit=200`),
    get(`/v1/builds/${buildId}`), get(`/v1/builds/${buildId}/preReleaseVersion`), get(`/v1/builds/${buildId}/app`),
  ]);
  const version = versions.find((item) => item.id === versionId);
  check(version?.attributes.platform === "IOS", "Expected existing iOS version not found");
  const { versionString: currentVersion, appStoreState } = version.attributes;
  check(editable.has(appStoreState), `Version is not editable: ${appStoreState}`);
  check(currentVersion === versionString || (currentVersion === "0.2.0" && appStoreState === "DEVELOPER_REJECTED"), `Refusing to rename unexpected version ${currentVersion}`);
  check(!versions.some((item) => item.id !== versionId && item.attributes.platform === "IOS" && item.attributes.versionString === versionString), "Another 0.4.0 version already exists");
  const info = infos.find((item) => item.id === infoId);
  check(info && editable.has(info.attributes.appStoreState), "Expected editable app information not found");
  check(buildApp.id === appId && release.attributes.version === versionString && release.attributes.platform === "IOS", "Build app/version/platform mismatch");
  check(build.attributes.version === buildNumber && build.attributes.processingState === "VALID" && !build.attributes.expired && build.attributes.buildAudienceType === "APP_STORE_ELIGIBLE", "Build 10 is not ready for App Store submission");
  const detail = await get(`/v1/appStoreVersions/${versionId}/appStoreReviewDetail`);
  check(detail?.attributes.contactPhone && detail.attributes.contactEmail && !detail.attributes.demoAccountRequired, "Expected App Review contact/demo settings missing");
  return { version, info };
}

async function ensureVersion(version) {
  const desired = { versionString, releaseType: "MANUAL", copyright: "2026 Yumi Izumi" };
  result.version = changed(version.attributes, desired) ? "done" : "skipped-already-set";
  if (changed(version.attributes, desired)) await patch("appStoreVersions", version.id, desired);
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

async function ensureAppInfo(info) {
  let localization = (await list(`/v1/appInfos/${info.id}/appInfoLocalizations?filter[locale]=en-US&limit=1`))[0];
  const fields = { name: listing.name, subtitle: listing.subtitle, privacyPolicyUrl: listing.privacyPolicyUrl };
  if (!localization) {
    localization = (await asc("POST", "/v1/appInfoLocalizations", data("appInfoLocalizations", null, { locale: "en-US", ...fields }, { appInfo: { data: { type: "appInfos", id: info.id } } }))).data;
    result.appInfoLocalization = "done-created";
  } else {
    const update = fields;
    if (changed(localization.attributes, update)) {
      await patch("appInfoLocalizations", localization.id, update);
      result.appInfoLocalization = "done";
    } else result.appInfoLocalization = "skipped-already-set";
  }
  return get(`/v1/appInfos/${info.id}`);
}

async function ensureReviewDetail(version) {
  const detail = await get(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`);
  const attributes = { notes: listing.notes };
  if (changed(detail.attributes, attributes)) {
    await patch("appStoreReviewDetails", detail.id, attributes);
    result.reviewDetail = "done";
  } else result.reviewDetail = "skipped-already-set";
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
    const deadline = Date.now() + 10 * 60 * 1000;
    for (;;) {
      screenshot = await get(`/v1/appScreenshots/${id}`);
      const state = screenshot.attributes.assetDeliveryState?.state;
      if (state === "COMPLETE" && screenshot.attributes.sourceFileChecksum) break;
      if (state === "FAILED") throw new Error(`screenshot ${screenshot.attributes.fileName} FAILED: ${JSON.stringify(screenshot.attributes.assetDeliveryState)}`);
      check(Date.now() < deadline, `Screenshot processing timed out: ${screenshot.attributes.fileName}`);
      await sleep(5000);
    }
    final.push(screenshot);
  }
  return final;
}

async function ensureScreenshots(localization) {
  for (const spec of screenshotSpecs) {
    const expected = spec.files;
    let set = (await list(`/v1/appStoreVersionLocalizations/${localization.id}/appScreenshotSets?filter[screenshotDisplayType]=${spec.type}&limit=1`))[0];
    let touched = false;
    if (!set) {
      set = (await asc("POST", "/v1/appScreenshotSets", data("appScreenshotSets", null, { screenshotDisplayType: spec.type }, { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: localization.id } } }))).data;
      touched = true;
    }
    const existing = await list(`/v1/appScreenshotSets/${set.id}/appScreenshots?limit=50`);
    const keep = new Map(existing.filter((shot) => expected.some((file) => file.name === shot.attributes.fileName && file.checksum === shot.attributes.sourceFileChecksum && shot.attributes.assetDeliveryState?.state !== "FAILED")).map((shot) => [shot.attributes.fileName, shot]));
    const keepIds = new Set([...keep.values()].map((shot) => shot.id));
    for (const shot of existing.filter((shot) => !keepIds.has(shot.id))) {
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
  const attached = await get(`/v1/appStoreVersions/${version.id}/build`);
  if (attached?.id !== buildId) await asc("PATCH", `/v1/appStoreVersions/${version.id}/relationships/build`, { data: { type: "builds", id: buildId } });
  result.build = attached?.id === buildId ? "skipped-already-set" : "done-attached";
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
  for (const set of sets.filter((set) => ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129"].includes(set.attributes.screenshotDisplayType))) screenshots[set.attributes.screenshotDisplayType] = (await list(`/v1/appScreenshotSets/${set.id}/appScreenshots?limit=50`)).map((shot) => ({ fileName: shot.attributes.fileName, checksum: shot.attributes.sourceFileChecksum, deliveryState: shot.attributes.assetDeliveryState?.state, error: shot.attributes.assetDeliveryState?.errors || null }));
  const state = {
    source: { path: sourcePath, sha256: createHash("sha256").update(source).digest("hex") },
    app: { id: app.id, bundleId: app.attributes.bundleId, contentRightsDeclaration: app.attributes.contentRightsDeclaration },
    version: versionNow.attributes, versionLocalization: versionLoc.attributes,
    appInfoLocalization: infoLoc[0]?.attributes, categories: { primary: primary?.id, secondary: secondary?.id },
    ageRatingDeclaration: age.attributes, computedAgeRating: infoNow.attributes.appStoreAgeRating,
    reviewDetail: review && { ...review.attributes, contactPhone: mask(review.attributes.contactPhone) },
    priceSchedule: price && { id: price.id, baseTerritory: baseTerritory && { id: baseTerritory.id, currency: baseTerritory.attributes.currency }, price: "pre-existing schedule left unchanged" }, availability: availability?.attributes,
    screenshots, attachedBuild: build?.attributes.version || null, attachedBuildId: build?.id || null, results: result,
  };
  mkdirSync("/tmp/yorozu-040-review", { recursive: true });
  writeFileSync("/tmp/yorozu-040-review/listing-readback.json", `${JSON.stringify(state, null, 2)}\n`);
  check(!changed(versionNow.attributes, { versionString, releaseType: "MANUAL" }), "Version readback mismatch");
  check(!changed(versionLoc.attributes, listingFields()), "Listing readback differs from Markdown source");
  check(!changed(infoLoc[0]?.attributes || {}, { name: listing.name, subtitle: listing.subtitle, privacyPolicyUrl: listing.privacyPolicyUrl }), "App information readback mismatch");
  check(review?.attributes.notes === listing.notes && build?.id === buildId, "Review notes/build readback mismatch");
  for (const spec of screenshotSpecs) {
    const actual = screenshots[spec.type] || [];
    check(actual.length === spec.files.length && actual.every((shot, i) => shot.fileName === spec.files[i].name && shot.checksum === spec.files[i].checksum && shot.deliveryState === "COMPLETE"), `${spec.type}: screenshot readback mismatch`);
  }
  return state;
}

async function main() {
  const args = process.argv.slice(2);
  check(args.length <= 1 && (!args.length || ["--check", "--apply"].includes(args[0])), "Usage: node scripts/asc-listing.mjs [--check|--apply]");
  validateLocal();
  // This is the first App Store release: Apple does not accept What's New yet.
  result.whatsNew = "skipped-first-app-store-release";
  if (args[0] !== "--apply") {
    console.log(JSON.stringify({ mode: "local-check-only", version: versionString, build: buildNumber, source: sourcePath, lengths, screenshots: screenshotSpecs.map(({ type, files }) => ({ type, files: files.map(({ name, checksum }) => ({ name, checksum })) })), results: result }, null, 2));
    return;
  }
  const target = await preflight();
  const version = await ensureVersion(target.version);
  const localization = await ensureVersionLocalization(version);
  const info = await ensureAppInfo(target.info);
  await ensureReviewDetail(version);
  await ensureScreenshots(localization);
  await attachBuild(version);
  const state = await readback(version, localization, info);
  console.log(JSON.stringify({ results: result, computedAgeRating: state.computedAgeRating, attachedBuild: state.attachedBuild, reviewState: "/tmp/yorozu-040-review/listing-readback.json" }, null, 2));
}

main().catch((error) => { console.error(error.stack || error.message); process.exitCode = 1; });
