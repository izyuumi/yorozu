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
  const declared = JSON.parse(await readFile(join(input, "agent-runtimes/openclaw/runtime-artifact.json"), "utf8")).dependencyEvidence;
  assert.equal(proof.dependencyEvidenceKind, declared.kind);
  assert.equal(proof.dependencyArchiveProvenanceVerified, declared.kind === "pnpm-frozen-lockfile-install-v1");
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
  // Rejection cases start from the reused-bytes evidence shape regardless of the input artifact's own evidence.
  baseline.dependencyEvidence = { kind: "reused-local-bytes-inventory-only", archiveProvenanceVerified: false, lockfileMatchEstablished: false };
  baseline.hashStage = "assembled-before-signing"; delete baseline.reseal; // a signed input artifact must not pre-seed the signed-stage cases
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
    await t.test("frozen-install evidence requires exact pinned lock, pnpm pin and installed lock digest", async () => {
      const frozen = structuredClone(baseline); frozen.dependencyEvidence = { kind: "pnpm-frozen-lockfile-install-v1", archiveProvenanceVerified: true, lockfileMatchEstablished: true, packageManager: "pnpm@12.5.1", lockSha256: SEALED_OPENCLAW_PIN.lockSha256, installedLockSha256: "1".repeat(64) };
      await manifest(frozen); const proof = await verifyPackagedOpenClawArtifact(resources);
      assert.equal(proof.dependencyArchiveProvenanceVerified, true); assert.equal(proof.dependencyEvidenceKind, "pnpm-frozen-lockfile-install-v1");
      for (const change of [{ lockSha256: "0".repeat(64) }, { packageManager: "npm@11.0.0" }, { installedLockSha256: "short" }, { lockfileMatchEstablished: false }]) { const b = structuredClone(frozen); Object.assign(b.dependencyEvidence, change); await manifest(b); await reject(); }
      const reused = structuredClone(baseline); reused.dependencyEvidence.packageManager = "pnpm@12.5.1"; await manifest(reused); await reject();
    });
    await t.test("nested-signed stage needs a reseal record naming the resigned sealed Node and the unsigned pins", async () => {
      const signed = structuredClone(baseline); signed.hashStage = "after-nested-signing-before-outer-bundle-signing";
      await manifest(signed); await reject(); // no reseal record
      signed.reseal = { unsignedInventorySha256: baseline.inventorySha256 ?? "2".repeat(64), unsignedNodeSha256: SEALED_OPENCLAW_PIN.nodeSha256, resignedPaths: ["node"] };
      await manifest(signed); assert.equal((await verifyPackagedOpenClawArtifact(resources)).hashStage, "after-nested-signing-before-outer-bundle-signing");
      // A resigned node may differ from the unsigned pin only in this stage; other pins stay exact.
      const node = signed.files.find((r: any) => r.path === "node"); const original = node.sha256; node.sha256 = "3".repeat(64); await manifest(signed); await reject(); node.sha256 = original;
      for (const change of [(b: any) => { b.reseal.unsignedNodeSha256 = "4".repeat(64); }, (b: any) => { b.reseal.resignedPaths = []; }, (b: any) => { b.hashStage = "signed"; }]) { const b = structuredClone(signed); change(b); await manifest(b); await reject(); }
    });
  } finally { await rm(resources, { recursive: true, force: true }); }
});
