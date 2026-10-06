import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, copyFile, writeFile, readFile, rm, chmod, symlink, link } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { createHash } from "node:crypto";
// Native Node test/strip-types runner, no dependency installation needed.
// @ts-ignore -- Node standalone test deliberately imports the TS source.
import { loadPackagedOpenClawRuntime, verifyPackagedOpenClawArtifact, SEALED_OPENCLAW_PIN } from "./packaged-openclaw-runtime.ts";

const input = process.env.YOROZU_TEST_SEALED_OPENCLAW_RESOURCES;
const sha = (x: Buffer | string) => createHash("sha256").update(x).digest("hex");
const canonical = (rows: any[]) => rows.sort((a, b) => a.path < b.path ? -1 : 1).map(r => r.link !== undefined ? { link: r.link, path: r.path } : { bytes: r.bytes, mode: r.mode, path: r.path, sha256: r.sha256 });

test("complete offline artifact verifies and produces fixed inputs without launching native code", async () => {
  assert.ok(input, "explicit test artifact required; no skip or ambient runtime discovery");
  const proof = await verifyPackagedOpenClawArtifact(input);
  assert.equal(proof.productionReady, false);
  assert.equal(proof.dependencyArchiveProvenanceVerified, false);
  assert.ok(proof.entries > 100);
  const loaded = await loadPackagedOpenClawRuntime(input);
  assert.equal(loaded.openclaw.sourceSha, SEALED_OPENCLAW_PIN.sourceSha);
  assert.equal(loaded.node.version, "26.10.0");
  assert.equal(loaded.openclaw.sourceIntegrity, "sealed-inventory-v1");
  assert.equal(loaded.openclaw.source, join(input, "agent-runtimes/openclaw/source"));
});

test("sealed loader rejects malformed, tampered and escaping inputs", async t => {
  assert.ok(input, "explicit test artifact required");
  const original = join(input, "agent-runtimes/openclaw");
  const a = JSON.parse(await readFile(join(original, "runtime-artifact.json"), "utf8"));
  const work = await mkdtemp(join(tmpdir(), "yorozu-seal-tests-"));
  // macOS /var is a symlink; trusted resources must be canonical.
  const { realpath } = await import("node:fs/promises");
  const resources = await realpath(work), root = join(resources, "agent-runtimes/openclaw");
  await mkdir(root, { recursive: true });
  const names = ["node", "source/pnpm-lock.yaml", "source/dist/yorozu-gateway-embedding.js", "source/dist/build-info.json", "source/dist/protocol.schema.json", "source/package.json", "source/dist/entry.js", "plugin/adapter.mjs", "plugin/manifest.json"];
  const baseline = structuredClone(a); baseline.files = a.files.filter((r: any) => names.includes(r.path));
  for (const r of baseline.files) {
    const p = join(root, r.path); await mkdir(dirname(p), { recursive: true }); await copyFile(join(original, r.path), p); await chmod(p, r.mode);
  }
  const dep = "source/node_modules/proof.txt"; await mkdir(dirname(join(root, dep)), { recursive: true }); await writeFile(join(root, dep), "fixture");
  baseline.files.push({ path: dep, bytes: 7, mode: 420, sha256: sha("fixture") });
  async function manifest(value = baseline) {
    const b = structuredClone(value); b.files = canonical(b.files); b.inventorySha256 = sha(JSON.stringify(b.files));
    await writeFile(join(root, "runtime-artifact.json"), JSON.stringify(b));
  }
  const reject = () => assert.rejects(verifyPackagedOpenClawArtifact(resources), /invalid sealed inputs/);
  try {
    await manifest(); await verifyPackagedOpenClawArtifact(resources);
    await t.test("wrong source/full diff pin", async () => { const b = structuredClone(baseline); b.pins.patchSha256 = "0".repeat(64); await manifest(b); await reject(); });
    await t.test("false provenance upgrade", async () => { const b = structuredClone(baseline); b.dependencyEvidence.archiveProvenanceVerified = true; await manifest(b); await reject(); });
    await t.test("production claim", async () => { const b = structuredClone(baseline); b.productionReady = true; await manifest(b); await reject(); });
    await t.test("unknown manifest field", async () => { const b = structuredClone(baseline); b.fallback = true; await manifest(b); await reject(); });
    await t.test("traversal", async () => { const b = structuredClone(baseline); b.files[0].path = "../escape"; await manifest(b); await reject(); });
    await t.test("duplicate inventory entry", async () => { const b = structuredClone(baseline); b.files.push(b.files[0]); await manifest(b); await reject(); });
    await t.test("missing required entry", async () => { const b = structuredClone(baseline); b.files = b.files.filter((r: any) => r.path !== "source/dist/yorozu-gateway-embedding.js"); await manifest(b); await reject(); });
    await t.test("unlisted file", async () => { await manifest(); await writeFile(join(root, "surprise"), "x"); await reject(); await rm(join(root, "surprise")); });
    await t.test("dependency byte tamper and no success cache", async () => { await manifest(); await writeFile(join(root, dep), "changed"); await reject(); await writeFile(join(root, dep), "fixture"); });
    await t.test("hardlinked dependency", async () => { await link(join(root, dep), join(resources, "hardlink")); await reject(); await rm(join(resources, "hardlink")); });
    await t.test("group writable payload", async () => { await chmod(join(root, dep), 0o664); await reject(); await chmod(join(root, dep), 0o644); });
    await t.test("absolute symlink", async () => { const b = structuredClone(baseline); b.files.push({ path: "escape", link: "/etc/passwd" }); await symlink("/etc/passwd", join(root, "escape")); await manifest(b); await reject(); await rm(join(root, "escape")); });
    await t.test("relative escaping symlink", async () => { const b = structuredClone(baseline); b.files.push({ path: "escape", link: "../../../outside" }); await symlink("../../../outside", join(root, "escape")); await manifest(b); await reject(); await rm(join(root, "escape")); });
    await t.test("linked resources root", async () => { await manifest(); const alias = join(resources, "alias"); await symlink(root, alias); await assert.rejects(verifyPackagedOpenClawArtifact(join(alias, "../.."))); await rm(alias); });
    await t.test("restored bytes accepted", async () => { await manifest(); await verifyPackagedOpenClawArtifact(resources); });
  } finally { await rm(resources, { recursive: true, force: true }); }
});
