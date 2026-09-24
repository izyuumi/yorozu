import assert from "node:assert/strict";
import { test } from "node:test";
import { nextBuild, resolveCandidate, verifyCandidate } from "./asc-candidate.mjs";

const appId = "6811274963";
const version = "0.5.0";
const build = "123";
const uploadedDate = "2026-09-24T00:00:00Z";
const currentTime = Date.parse("2026-09-24T01:00:00Z");
const metadata = { app_id: appId, build_id: "build-id", version, build, uploaded_date: uploadedDate };
const candidate = () => ({ version, build, ios: { ...metadata } });
const buildResponse = () => ({
  data: {
    type: "builds", id: "build-id",
    attributes: {
      version: build, uploadedDate, expirationDate: "2026-12-23T00:00:00Z",
      expired: false, processingState: "VALID", buildAudienceType: "APP_STORE_ELIGIBLE",
    },
    relationships: { app: { data: { id: appId } }, preReleaseVersion: { data: { id: "pre-release-id" } } },
  },
  included: [{ type: "preReleaseVersions", id: "pre-release-id", attributes: { platform: "IOS", version } }],
});
const storeResponse = () => ({ data: [{
  id: "store-version-id", attributes: { platform: "IOS", versionString: version, appVersionState: "PENDING_DEVELOPER_RELEASE" },
  relationships: { build: { data: { id: "build-id" } } },
}] });

function fakeAsc({ buildResult = buildResponse(), storeResult = storeResponse(), bundleId = "to.yumi.yorozu.ios", listedBuilds } = {}) {
  return async (method, path) => {
    assert.equal(method, "GET", "ASC candidate commands must remain read-only");
    const url = new URL(path, "https://api.appstoreconnect.apple.com");
    if (url.pathname === `/v1/apps/${appId}`) return { data: { id: appId, attributes: { bundleId } } };
    if (url.pathname === "/v1/builds") {
      for (const [key, value] of Object.entries({ "filter[app]": appId, "filter[version]": build, "filter[preReleaseVersion.version]": version, "filter[preReleaseVersion.platform]": "IOS" })) {
        assert.equal(url.searchParams.get(key), value, `Must filter exact candidate ${key}`);
      }
      return listedBuilds ? listedBuilds() : { ...buildResult, data: [buildResult.data] };
    }
    if (url.pathname === "/v1/builds/build-id") return buildResult;
    if (url.pathname === `/v1/apps/${appId}/appStoreVersions`) {
      assert.equal(url.searchParams.get("filter[versionString]"), version);
      assert.equal(url.searchParams.get("filter[platform]"), "IOS");
      return storeResult;
    }
    assert.fail(`Unexpected ASC request ${path}`);
  };
}

test("resolve waits for exact upload to become VALID and records stable identity", async () => {
  let time = currentTime;
  let calls = 0;
  const ready = buildResponse();
  const request = fakeAsc({ listedBuilds: () => {
    calls += 1;
    if (calls === 1) return { data: [] };
    if (calls === 2) return { ...ready, data: [{ ...ready.data, attributes: { ...ready.data.attributes, processingState: "PROCESSING" } }] };
    return { ...ready, data: [ready.data] };
  } });
  assert.deepEqual(await resolveCandidate(version, build, { request, timeoutMs: 10, pollMs: 2, now: () => time, wait: async (ms) => { time += ms; } }), metadata);
  assert.equal(calls, 3);
});

test("iOS build allocation starts at 1 for a new version and advances past all uploads for an existing version", async () => {
  const request = async (method, path) => {
    assert.equal(method, "GET");
    const url = new URL(path, "https://api.appstoreconnect.apple.com");
    if (url.pathname === `/v1/apps/${appId}`) return { data: { id: appId, attributes: { bundleId: "to.yumi.yorozu.ios" } } };
    assert.equal(url.searchParams.get("filter[preReleaseVersion.version]"), version);
    assert.equal(url.searchParams.get("filter[preReleaseVersion.platform]"), "IOS");
    if (url.searchParams.has("page")) return { data: [{ attributes: { version: "10048" } }] };
    return { data: [{ attributes: { version: "10047" } }], links: { next: "/v1/builds?page=2&filter%5BpreReleaseVersion.version%5D=0.5.0&filter%5BpreReleaseVersion.platform%5D=IOS" } };
  };
  assert.equal(await nextBuild(version, { request }), "10049");
  assert.equal(await nextBuild("0.6.0", { request: async (method, path) =>
    path.startsWith(`/v1/apps/${appId}`)
      ? { data: { id: appId, attributes: { bundleId: "to.yumi.yorozu.ios" } } }
      : { data: [] } }), "1");
});

test("resolve never guesses another build and has a bounded wait", async () => {
  const wrongVersion = buildResponse();
  wrongVersion.included[0].attributes.version = "0.4.1";
  await assert.rejects(resolveCandidate(version, build, { request: fakeAsc({ buildResult: wrongVersion }), now: () => currentTime }), /marketing version/);
  let time = currentTime;
  await assert.rejects(resolveCandidate(version, build, {
    request: fakeAsc({ listedBuilds: () => ({ data: [] }) }), timeoutMs: 3, pollMs: 2,
    now: () => time, wait: async (ms) => { time += ms; },
  }), /Timed out/);
  assert.equal(time, currentTime + 3);
});

test("verify accepts approved exact candidate and current or legacy released states", async () => {
  for (const [field, state] of [["appVersionState", "PENDING_DEVELOPER_RELEASE"], ["appVersionState", "READY_FOR_DISTRIBUTION"], ["appStoreState", "READY_FOR_SALE"]]) {
    const storeResult = storeResponse();
    delete storeResult.data[0].attributes.appVersionState;
    storeResult.data[0].attributes[field] = state;
    const result = await verifyCandidate(candidate(), { request: fakeAsc({ storeResult }), now: () => currentTime });
    assert.deepEqual(result, { ...metadata, app_store_version_id: "store-version-id", state });
  }
});

test("verify uses iOS build from candidate when Mac build differs", async () => {
  assert.deepEqual(await verifyCandidate({ ...candidate(), build: "10042" },
    { request: fakeAsc(), now: () => currentTime }),
  { ...metadata, app_store_version_id: "store-version-id", state: "PENDING_DEVELOPER_RELEASE" });
});

test("verify rejects changed candidate metadata before contacting ASC", async () => {
  for (const field of ["version", "build", "app_id"]) {
    const invalid = candidate();
    invalid.ios[field] = "wrong";
    await assert.rejects(verifyCandidate(invalid, { request: () => assert.fail("Invalid manifest must not reach ASC") }), /metadata does not match|build must be a positive integer/);
  }
});

test("resolve and verify reject failed, expired, internal-only, or mismatched builds", async () => {
  const cases = [
    [(r) => { r.data.attributes.processingState = "FAILED"; }, /processing state is FAILED/],
    [(r) => { r.data.attributes.expired = true; }, /expired/],
    [(r) => { r.data.attributes.expirationDate = "2026-09-23T00:00:00Z"; }, /expired/],
    [(r) => { r.data.attributes.buildAudienceType = "INTERNAL_ONLY"; }, /internal-only/],
    [(r) => { delete r.data.attributes.buildAudienceType; }, /not eligible/],
    [(r) => { r.data.attributes.version = "124"; }, /build number/],
    [(r) => { r.included[0].attributes.version = "0.4.1"; }, /marketing version/],
    [(r) => { r.included[0].attributes.platform = "MAC_OS"; }, /platform/],
    [(r) => { r.data.relationships.app.data.id = "1"; }, /different app/],
  ];
  for (const [change, expected] of cases) {
    const buildResult = buildResponse();
    change(buildResult);
    const options = { request: fakeAsc({ buildResult }), now: () => currentTime };
    await assert.rejects(resolveCandidate(version, build, options), expected);
    await assert.rejects(verifyCandidate(candidate(), options), expected);
  }
  const processing = buildResponse();
  processing.data.attributes.processingState = "PROCESSING";
  await assert.rejects(verifyCandidate(candidate(), { request: fakeAsc({ buildResult: processing }), now: () => currentTime }), /processing state is PROCESSING/);
});

test("verify requires exact selected build and approved version", async () => {
  for (const [change, expected] of [
    [(r) => { r.data[0].relationships.build.data.id = "other-build"; }, /different selected build/],
    [(r) => { r.data[0].attributes.appVersionState = "IN_REVIEW"; r.data[0].attributes.appStoreState = "READY_FOR_SALE"; }, /IN_REVIEW/],
    [(r) => { r.data[0].attributes.versionString = "0.4.1"; }, /version does not match/],
    [(r) => { r.data = []; }, /Expected one iOS App Store version/],
  ]) {
    const storeResult = storeResponse();
    change(storeResult);
    await assert.rejects(verifyCandidate(candidate(), { request: fakeAsc({ storeResult }), now: () => currentTime }), expected);
  }
  const changedUpload = candidate();
  changedUpload.ios.uploaded_date = "2026-09-24T00:01:00Z";
  await assert.rejects(verifyCandidate(changedUpload, { request: fakeAsc(), now: () => currentTime }), /upload date does not match/);
  await assert.rejects(verifyCandidate(candidate(), { request: fakeAsc({ bundleId: "other.bundle.id" }), now: () => currentTime }), /must be to.yumi.yorozu.ios/);
});
