import assert from "node:assert/strict";
import { test } from "node:test";
import { internalRequest, preflightInternal, resolveInternal, makeInternalAvailable } from "./asc-internal.mjs";

const appId = "6811274963";
const groupId = "954b8070-0ad9-4112-a061-2001bdc150b7";
const now = Date.parse("2026-10-03T12:00:00Z");
const validBuild = () => ({
  data: { type: "builds", id: "internal-build", attributes: {
    version: "1", uploadedDate: "2026-10-03T11:00:00Z", expirationDate: "2027-01-01T11:00:00Z",
    expired: false, processingState: "VALID", buildAudienceType: "INTERNAL_ONLY",
  }, relationships: { app: { data: { id: appId } }, preReleaseVersion: { data: { id: "train" } } } },
  included: [{ type: "preReleaseVersions", id: "train", attributes: { version: "0.6.0", platform: "IOS" } }],
});
const validGroup = () => ({ type: "betaGroups", id: groupId,
  attributes: { isInternalGroup: true, publicLinkEnabled: null, hasAccessToAllBuilds: true } });
const manifest = { app_id: appId, group_id: groupId, version: "0.6.0", build: "1", build_id: "internal-build",
  uploaded_date: "2026-10-03T11:00:00Z", internal_only: true };

function server({ build = validBuild(), groups = [validGroup()], testers = 1, listed, states = ["IN_BETA_TESTING"],
  next, bundleId = "to.yumi.yorozu.ios", external = "INELIGIBLE_FOR_EXTERNAL_TESTING" } = {}) {
  const writes = [];
  let assigned = false;
  let details = 0;
  const request = async (method, path, body) => {
    const url = new URL(path, "https://api.appstoreconnect.apple.com");
    if (method === "POST") {
      assert.equal(url.pathname, `/v1/betaGroups/${groupId}/relationships/builds`);
      assert.deepEqual(body, { data: [{ type: "builds", id: "internal-build" }] });
      writes.push(body); assigned = true; return {};
    }
    assert.equal(method, "GET");
    if (url.pathname === `/v1/apps/${appId}`) return { data: { id: appId, attributes: { bundleId } } };
    if (url.pathname === `/v1/apps/${appId}/betaGroups`) return { data: groups, links: { next } };
    if (url.pathname === `/v1/betaGroups/${groupId}/relationships/betaTesters`) {
      assert.equal(url.searchParams.get("fields[betaTesters]"), null, "No tester personal fields are requested");
      return { data: Array.from({ length: testers }, (_, i) => ({ type: "betaTesters", id: `tester-${i}` })) };
    }
    if (url.pathname === "/v1/builds") {
      assert.equal(url.searchParams.get("filter[app]"), appId);
      assert.equal(url.searchParams.get("filter[version]"), "1");
      assert.equal(url.searchParams.get("filter[preReleaseVersion.version]"), "0.6.0");
      assert.equal(url.searchParams.get("filter[preReleaseVersion.platform]"), "IOS");
      return { ...build, data: listed ? listed() : [build.data] };
    }
    if (url.pathname === "/v1/builds/internal-build") return build;
    if (url.pathname === "/v1/builds/internal-build/buildBetaDetail") return { data: { type: "buildBetaDetails", id: "internal-build", attributes: {
      internalBuildState: states[Math.min(details++, states.length - 1)], externalBuildState: external,
    } } };
    if (url.pathname === `/v1/betaGroups/${groupId}/relationships/builds`) return { data: assigned ? [build.data] : [] };
    assert.fail(`Unexpected request ${path}`);
  };
  return { request, writes };
}

const timing = () => {
  let time = now;
  return { now: () => time, wait: async (ms) => { time += ms; }, timeoutMs: 4, pollMs: 1 };
};

test("internal release waits for exact processing and internal availability, assigning only established group", async () => {
  const build = validBuild();
  let lists = 0;
  const mock = server({ build, listed: () => ++lists === 1 ? [] : [build.data], states: ["READY_FOR_BETA_TESTING", "IN_BETA_TESTING"] });
  const options = { request: mock.request, ...timing() };
  const ios = await resolveInternal("0.6.0", "1", options);
  assert.deepEqual(ios, manifest);
  const result = await makeInternalAvailable(ios, { ...options, assign: true });
  assert.equal(result.available, true);
  assert.equal(result.internal_state, "IN_BETA_TESTING");
  assert.equal(mock.writes.length, 1);
  await makeInternalAvailable(ios, { ...options, assign: true });
  assert.equal(mock.writes.length, 1, "Already assigned builds are not assigned again");
});

test("wrong or public-eligible build cannot be assigned, even when a manifest claims internal-only", async () => {
  for (const [change, message] of [
    [(r) => { r.data.attributes.buildAudienceType = "APP_STORE_ELIGIBLE"; }, /not INTERNAL_ONLY/],
    [(r) => { delete r.data.attributes.buildAudienceType; }, /not INTERNAL_ONLY/],
    [(r) => { r.data.attributes.expired = true; }, /expired/],
    [(r) => { r.data.attributes.expirationDate = "2026-10-03T11:00:00Z"; }, /expired/],
    [(r) => { r.data.attributes.processingState = "FAILED"; }, /processing state/],
    [(r) => { r.data.attributes.version = "2"; }, /number mismatch/],
    [(r) => { r.data.relationships.app.data.id = "other"; }, /another app/],
    [(r) => { r.included[0].attributes.version = "0.5.0"; }, /version or platform/],
    [(r) => { r.included[0].attributes.platform = "MAC_OS"; }, /version or platform/],
    [(r) => { r.data.attributes.uploadedDate = "2026-10-03T10:00:00Z"; }, /identity changed/],
  ]) {
    const build = validBuild(); change(build);
    const mock = server({ build });
    await assert.rejects(makeInternalAvailable(manifest, { request: mock.request, ...timing(), assign: true }), message);
    assert.equal(mock.writes.length, 0);
  }
});

test("recipient changes and wrong app fail before any assignment", async () => {
  const externalGroup = validGroup(); externalGroup.attributes.isInternalGroup = false;
  const linked = validGroup(); linked.attributes.publicLinkEnabled = true;
  for (const [setup, message] of [
    [{ groups: [] }, /group is missing/],
    [{ groups: [externalGroup] }, /not internal/],
    [{ groups: [linked] }, /not internal/],
    [{ groups: [validGroup(), { ...validGroup(), id: "other-internal" }] }, /automatically/],
    [{ testers: 0 }, /exactly one tester/],
    [{ testers: 2 }, /exactly one tester/],
    [{ bundleId: "other.app" }, /Wrong internal/],
  ]) {
    const mock = server(setup);
    await assert.rejects(makeInternalAvailable(manifest, { request: mock.request, ...timing(), assign: true }), message);
    assert.equal(mock.writes.length, 0);
  }
});

test("client rejects external destinations, review submissions, and foreign or looping pagination", async () => {
  const request = internalRequest(() => assert.fail("Rejected route must not contact ASC"));
  for (const [method, path, body] of [
    ["POST", "/v1/betaGroups/public/relationships/builds", { data: [{ type: "builds", id: "internal-build" }] }],
    ["POST", "/v1/betaAppReviewSubmissions", {}],
    ["GET", "https://example.invalid/v1/apps/6811274963"],
    ["GET", "/v1/apps/another-app"],
    ["DELETE", `/v1/betaGroups/${groupId}/relationships/builds`],
  ]) await assert.rejects(request(method, path, body), /outside the internal/);
  for (const next of ["https://example.invalid/v1/apps/6811274963/betaGroups", `/v1/apps/${appId}/betaGroups?loop=1`]) {
    await assert.rejects(preflightInternal({ request: server({ next }).request }), /pagination/);
  }
});

test("processing and unavailable internal builds time out; verification never assigns a build", async () => {
  let mock = server({ listed: () => [] });
  await assert.rejects(resolveInternal("0.6.0", "1", { request: mock.request, ...timing() }), /Timed out/);
  mock = server();
  await assert.rejects(makeInternalAvailable(manifest, { request: mock.request, ...timing() }), /Timed out/);
  assert.equal(mock.writes.length, 0, "Read-only verification cannot grant build access");
  mock = server({ states: ["MISSING_EXPORT_COMPLIANCE"] });
  await assert.rejects(makeInternalAvailable(manifest, { request: mock.request, ...timing() }), /blocked/);
});

test("manifest cannot redirect a valid internal build to another group or version", async () => {
  for (const changed of [{ group_id: "public" }, { app_id: "another" }, { internal_only: false }, { version: "0.5.0" }]) {
    const mock = server();
    await assert.rejects(makeInternalAvailable({ ...manifest, ...changed }, { request: mock.request, ...timing(), assign: true }), /manifest|version/);
    assert.equal(mock.writes.length, 0);
  }
});


test("read-only request modes reject assignment at the boundary before invoking transport", async () => {
  const path = `/v1/betaGroups/${groupId}/relationships/builds`;
  const body = { data: [{ type: "builds", id: "internal-build" }] };
  for (const mode of [undefined, "preflight", "resolve", "verify"]) {
    const calls = [];
    const request = internalRequest(async (...args) => { calls.push(args); return {}; }, mode);
    for (const method of ["POST", "PUT", "PATCH", "DELETE"]) {
      await assert.rejects(request(method, path, body), /outside the internal/);
    }
    assert.equal(calls.length, 0, `${mode ?? "default"} must reject before transport`);
    await request("GET", path);
    assert.deepEqual(calls, [["GET", path, undefined]]);
  }
  assert.throws(() => internalRequest(() => assert.fail("no transport"), "unknown"), /Invalid internal/);
});

test("only distribution boundary permits fixed-group assignment POST", async () => {
  const path = `/v1/betaGroups/${groupId}/relationships/builds`;
  const body = { data: [{ type: "builds", id: "internal-build" }] };
  const calls = [];
  const request = internalRequest(async (...args) => { calls.push(args); return {}; }, "distribute");
  for (const [method, target, data] of [
    ["POST", "/v1/betaGroups/other/relationships/builds", body],
    ["POST", "/v1/betaAppReviewSubmissions", body],
    ["POST", path + "?extra=1", body],
    ["POST", "https://example.invalid" + path, body],
    ["POST", path, { data: [] }],
    ["POST", path, { data: [body.data[0], body.data[0]] }],
    ["POST", path, { data: [{ type: "betaTesters", id: "internal-build" }] }],
    ["POST", path, { data: [{ type: "builds", id: "../other" }] }],
    ["PATCH", path, body],
    ["DELETE", path, body],
  ]) await assert.rejects(request(method, target, data), /outside the internal/);
  assert.equal(calls.length, 0);
  await request("POST", path, body);
  assert.deepEqual(calls, [["POST", path, body]]);
  // Wrapping a writable transport for a read-only phase must narrow it again.
  const preflight = internalRequest(request, "preflight");
  await assert.rejects(preflight("POST", path, body), /outside the internal/);
  assert.equal(calls.length, 1);
});

test("preflight, resolve and verify remain read-only after distribution has assigned access", async () => {
  const mock = server();
  const options = { request: mock.request, ...timing() };
  await makeInternalAvailable(manifest, { ...options, assign: true });
  assert.equal(mock.writes.length, 1);
  await preflightInternal(options);
  const ios = await resolveInternal("0.6.0", "1", options);
  const result = await makeInternalAvailable(ios, { ...options, assign: false });
  assert.equal(result.available, true);
  assert.equal(mock.writes.length, 1, "Read-only phases cannot add another assignment");
  await assert.rejects(makeInternalAvailable(ios, { ...options, assign: "distribute" }), /must be boolean/);
  assert.equal(mock.writes.length, 1);
});
