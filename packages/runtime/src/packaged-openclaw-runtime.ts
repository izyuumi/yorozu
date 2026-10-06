/** Offline sealed DEVELOPMENT runtime loader. Call only with trusted app Resources.
 * Inventory integrity is not upstream dependency provenance or release approval.
 * Does not execute code, acquire a listener/broker, discover profiles, or install.
 */
import { createHash } from "node:crypto";
import { constants, promises as fs } from "node:fs";
import { isAbsolute, join, resolve, dirname, posix } from "node:path";

export const SEALED_OPENCLAW_PIN = Object.freeze({
  sourceSha: "f04797ef4d24f3da0f9df74acd58ab773ab5f11e",
  upstreamSha: "fc23bc864e4553c2d215e479eeec47b67a0bf943",
  patchSha256: "601c2eea193de989977a122a98bda8653910848092f7c4937195e40bf63ebc4e",
  lockSha256: "c717cc8ed7331b2b4787ed4cbe80d46d3d733de69e3dc9dd7f1d49e6b4942802",
  entrySha256: "c7f8d626f2751ee75995ca991b594fb41a21afe0d053e81883a8f85c2eede68e",
  buildInfoSha256: "38390412b3f1a8109e5e63c30ba9686076571539efa8df3010d4c0d45a55514d",
  protocolSha256: "e5dad9efc6acfb59124d1c9872541b811abc56956d3d11abea7f2c37866aed4a",
  nodeSha256: "56d28b39a8048f0cd1af7ad7e09f6cbe1c04439b6dfeb6c8d9090c082af60861",
});
const BAD = "The packaged OpenClaw development runtime has invalid sealed inputs.";
const MAX_FILES = 300000, MAX_FILE = 512 * 1024 * 1024, MAX_TOTAL = 12 * 1024 ** 3;
const MANIFEST = "runtime-artifact.json";
type Row = { path: string; sha256: string; mode: number; bytes: number } | { path: string; link: string };
const digest = (v: string | Buffer) => createHash("sha256").update(v).digest("hex");
function fail(): never { throw new Error(BAD); }
function fields(v: any, names: string[]): void {
  if (!v || typeof v !== "object" || Array.isArray(v) || Object.keys(v).length !== names.length || names.some(n => !Object.hasOwn(v, n))) fail();
}
function relative(v: unknown): v is string {
  return typeof v === "string" && v.length > 0 && v.length < 4096 && !/[\\\x00-\x1f\x7f]/.test(v)
    && !isAbsolute(v) && v.split("/").every(p => p !== "" && p !== "." && p !== "..");
}
function inside(root: string, path: string): boolean { return path === root || path.startsWith(root + "/"); }
async function directory(path: string): Promise<void> {
  if (!isAbsolute(path) || resolve(path) !== path) fail();
  let p = path;
  while (true) {
    const s = await fs.lstat(p); if (!s.isDirectory() || s.isSymbolicLink()) fail();
    if (p === dirname(p)) break; p = dirname(p);
  }
}
async function regular(path: string, max: number) {
  const f = await fs.open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try { const s = await f.stat(); if (!s.isFile() || s.nlink !== 1 || s.mode & 0o022 || s.size > max) fail(); return f; }
  catch (e) { await f.close(); throw e; }
}
export const OPENCLAW_HASH_STAGES = Object.freeze(["assembled-before-signing", "after-nested-signing-before-outer-bundle-signing"] as const);
export interface VerifiedPackagedOpenClawRuntime {
  readonly productionReady: false;
  /** true only for pnpm-frozen-lockfile-install-v1 evidence (see docs/openclaw-sealed-runtime.md). */
  readonly dependencyArchiveProvenanceVerified: boolean;
  readonly dependencyEvidenceKind: "reused-local-bytes-inventory-only" | "pnpm-frozen-lockfile-install-v1";
  readonly inventorySha256: string;
  readonly entries: number;
  /** Nested (Mach-O) signing may only change bytes recorded by the packager's reseal. */
  readonly hashStage: typeof OPENCLAW_HASH_STAGES[number];
  /** Verified bytes of the sealed Node; equals the unsigned pin until nested signing resealed it. */
  readonly nodeSha256: string;
}
/** Rechecks the exact inventory each preparation; self-described digests require
 * an immutable, trusted outer bundle/signature. No success cache, no fallback. */
export async function verifyPackagedOpenClawArtifact(resourcesRoot: string): Promise<VerifiedPackagedOpenClawRuntime> {
  try {
    if (typeof resourcesRoot !== "string" || resourcesRoot.length > 4096 || !isAbsolute(resourcesRoot) || resolve(resourcesRoot) !== resourcesRoot || /[\x00-\x1f\x7f]/.test(resourcesRoot)) fail();
    const root = join(resourcesRoot, "agent-runtimes", "openclaw"); await directory(root);
    const f = await regular(join(root, MANIFEST), 64 * 1024 * 1024);
    let a: any; try { a = JSON.parse(await f.readFile("utf8")); } finally { await f.close(); }
    fields(a, ["schemaVersion", "kind", "productionReady", "hashStage", "pins", "dependencyEvidence", "files", "inventorySha256", ...(a?.hashStage === "after-nested-signing-before-outer-bundle-signing" ? ["reseal"] : [])]);
    if (a.schemaVersion !== 1 || a.kind !== "yorozu-openclaw-runtime" || a.productionReady !== false || !OPENCLAW_HASH_STAGES.includes(a.hashStage)) fail();
    fields(a.pins, Object.keys(SEALED_OPENCLAW_PIN));
    if (Object.entries(SEALED_OPENCLAW_PIN).some(([k, v]) => a.pins[k] !== v)) fail();
    const evidence = a.dependencyEvidence;
    if (evidence?.kind === "pnpm-frozen-lockfile-install-v1") {
      // pnpm verified every fetched archive against the reviewed lockfile's integrity
      // digests with resolution frozen; the assembler rechecked the pinned lockfile and
      // the pnpm-written installed lock. Lifecycle-script downloads are not covered.
      fields(evidence, ["kind", "archiveProvenanceVerified", "lockfileMatchEstablished", "packageManager", "lockSha256", "installedLockSha256"]);
      if (evidence.archiveProvenanceVerified !== true || evidence.lockfileMatchEstablished !== true || !/^pnpm@\d+\.\d+\.\d+$/.test(evidence.packageManager)
        || evidence.lockSha256 !== SEALED_OPENCLAW_PIN.lockSha256 || !/^[a-f0-9]{64}$/.test(evidence.installedLockSha256)) fail();
    } else {
      fields(evidence, ["kind", "archiveProvenanceVerified", "lockfileMatchEstablished"]);
      if (evidence.kind !== "reused-local-bytes-inventory-only" || evidence.archiveProvenanceVerified !== false || evidence.lockfileMatchEstablished !== false) fail();
    }
    if (!Array.isArray(a.files) || !a.files.length || a.files.length > MAX_FILES) fail();
    const expected = new Map<string, Row>();
    let previous = "";
    for (const r of a.files) {
      if (!relative(r?.path) || r.path === MANIFEST || expected.has(r.path) || r.path <= previous) fail();
      previous = r.path;
      if (Object.hasOwn(r, "link")) {
        fields(r, ["path", "link"]);
        if (typeof r.link !== "string" || !r.link || r.link.length > 4096 || isAbsolute(r.link) || /[\\\x00-\x1f\x7f]/.test(r.link)) fail();
        const target = posix.normalize(posix.join(posix.dirname(r.path), r.link));
        if (!relative(target)) fail();
      } else {
        fields(r, ["path", "sha256", "mode", "bytes"]);
        if (!/^[a-f0-9]{64}$/.test(r.sha256) || ![420, 493].includes(r.mode) || !Number.isSafeInteger(r.bytes) || r.bytes < 0 || r.bytes > MAX_FILE) fail();
      }
      expected.set(r.path, r);
    }
    // Canonical JSON recursively sorts keys (same encoding as the offline assembler).
    const canonical = a.files.map((r: Row) => "link" in r ? { link: r.link, path: r.path } : { bytes: r.bytes, mode: r.mode, path: r.path, sha256: r.sha256 });
    if (digest(JSON.stringify(canonical)) !== a.inventorySha256) fail();
    for (const r of a.files) {
      let p = posix.dirname(r.path);
      while (p !== ".") { if (expected.has(p)) fail(); p = posix.dirname(p); }
    }
    const required: Record<string, string | undefined> = {
      node: SEALED_OPENCLAW_PIN.nodeSha256,
      "source/pnpm-lock.yaml": SEALED_OPENCLAW_PIN.lockSha256,
      "source/dist/yorozu-gateway-embedding.js": SEALED_OPENCLAW_PIN.entrySha256,
      "source/dist/build-info.json": SEALED_OPENCLAW_PIN.buildInfoSha256,
      "source/dist/protocol.schema.json": SEALED_OPENCLAW_PIN.protocolSha256,
      "source/package.json": undefined, "source/dist/entry.js": undefined,
      "plugin/adapter.mjs": undefined, "plugin/manifest.json": undefined,
    };
    const signed = a.hashStage === "after-nested-signing-before-outer-bundle-signing";
    for (const [name, hash] of Object.entries(required)) {
      const r = expected.get(name); if (!r || !("sha256" in r) || hash && r.sha256 !== hash && !(signed && name === "node")) fail();
    }
    if (signed) { fields(a.reseal, ["unsignedInventorySha256", "unsignedNodeSha256", "resignedPaths"]); if (a.reseal.unsignedNodeSha256 !== SEALED_OPENCLAW_PIN.nodeSha256 || !/^[a-f0-9]{64}$/.test(a.reseal.unsignedInventorySha256) || !Array.isArray(a.reseal.resignedPaths) || !a.reseal.resignedPaths.includes("node")) fail(); }
    if (!a.files.some((r: Row) => r.path.startsWith("source/node_modules/"))) fail();
    let total = 0, visited = 0; const found = new Set<string>(); const pending: string[] = [];
    async function walk(dir: string): Promise<void> {
      for await (const entry of await fs.opendir(dir)) {
        if (++visited > MAX_FILES * 3) fail();
        const path = join(dir, entry.name), name = path.slice(root.length + 1);
        if (name === MANIFEST) continue;
        const s = await fs.lstat(path);
        if (s.isDirectory()) { if (s.mode & 0o022) fail(); await walk(path); continue; }
        const r = expected.get(name); if (!r || found.has(name)) fail(); found.add(name);
        if ("link" in r) {
          if (!s.isSymbolicLink() || await fs.readlink(path) !== r.link || !inside(root, await fs.realpath(path))) fail();
        } else {
          if (!s.isFile() || s.nlink !== 1 || s.size !== r.bytes || s.mode & 0o022 || (s.mode & 0o111 ? 493 : 420) !== r.mode || (total += s.size) > MAX_TOTAL) fail();
          pending.push(name);
        }
      }
    }
    await walk(root); if (found.size !== expected.size) fail();
    let index = 0;
    await Promise.all(Array.from({ length: 4 }, async () => {
      while (index < pending.length) {
        const name = pending[index++], row = expected.get(name) as Exclude<Row, { link: string }>;
        const file = await regular(join(root, name), MAX_FILE);
        try {
          const h = createHash("sha256"); let bytes = 0;
          for await (const chunk of file.createReadStream({ autoClose: false })) { bytes += chunk.length; if (bytes > row.bytes) fail(); h.update(chunk); }
          if (bytes !== row.bytes || h.digest("hex") !== row.sha256) fail();
        } finally { await file.close(); }
      }
    }));
    const nodeRow = expected.get("node") as Exclude<Row, { link: string }>;
    return Object.freeze({ productionReady: false, dependencyArchiveProvenanceVerified: evidence.archiveProvenanceVerified === true, dependencyEvidenceKind: evidence.kind, inventorySha256: a.inventorySha256, entries: expected.size, hashStage: a.hashStage, nodeSha256: nodeRow.sha256 });
  } catch { throw new Error(BAD); }
}
/** Pure input loader: preserves the existing supervisor's scope/identity, listener,
 * embedding lifetime and broker controls. Never launches or selects a provider. */
export async function loadPackagedOpenClawRuntime(resourcesRoot: string) {
  const verified = await verifyPackagedOpenClawArtifact(resourcesRoot);
  const root = join(resourcesRoot, "agent-runtimes", "openclaw");
  return Object.freeze({
    node: { executable: join(root, "node"), version: "26.10.0" as const },
    openclaw: { version: "2026.9.8" as const, sourceSha: SEALED_OPENCLAW_PIN.sourceSha,
      source: join(root, "source"), adapter: join(root, "plugin", "adapter.mjs"), sourceIntegrity: "sealed-inventory-v1" as const,
      // After nested signing the sealed Node no longer matches the adapter's unsigned pin;
      // the verified inventory (under the outer bundle signature) is the trusted substitute.
      ...(verified.hashStage === "after-nested-signing-before-outer-bundle-signing" ? { nodeIntegrity: { sha256: verified.nodeSha256, hashStage: verified.hashStage } } : {}) },
  });
}
/** Reads only the sealed Node row of a manifest without full verification; preparation re-verifies everything. */
export async function readSealedOpenClawNodeIntegrity(resourcesRoot: string): Promise<{ sha256: string; hashStage: "after-nested-signing-before-outer-bundle-signing" } | undefined> {
  try {
    const f = await regular(join(resourcesRoot, "agent-runtimes", "openclaw", MANIFEST), 64 * 1024 * 1024);
    let a: any; try { a = JSON.parse(await f.readFile("utf8")); } finally { await f.close(); }
    if (a?.hashStage !== "after-nested-signing-before-outer-bundle-signing") return undefined;
    const row = Array.isArray(a.files) ? a.files.find((r: any) => r?.path === "node") : undefined;
    return /^[a-f0-9]{64}$/.test(row?.sha256 ?? "") ? { sha256: row.sha256, hashStage: a.hashStage } : undefined;
  } catch { return undefined; }
}
