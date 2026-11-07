import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { expect, test } from "vitest";

const root = new URL("../compat/v0.13.0/", import.meta.url);
const repo = new URL("../../../", import.meta.url);
const manifest = JSON.parse(readFileSync(new URL("manifest.json", root), "utf8")) as {
  tag: string;
  commit: string;
  files: Record<string, string>;
};

let hasCommit = false;
try {
  execFileSync("git", ["cat-file", "-e", manifest.commit], { cwd: repo, stdio: "ignore" });
  hasCommit = true;
} catch {
  // Shallow CI checkouts need only the vendored source and manifest.
}

for (const [file, hash] of Object.entries(manifest.files)) {
  test(`v0.13.0 source hash: ${file}`, () => {
    const bytes = readFileSync(new URL(file, root));
    expect(createHash("sha256").update(bytes).digest("hex")).toBe(hash);
  });

  test.skipIf(!hasCommit)(`v0.13.0 source matches shipped commit: ${file}`, () => {
    const original = execFileSync("git", ["show", `${manifest.commit}:apps/relay/${file}`], { cwd: repo });
    expect(readFileSync(new URL(file, root))).toEqual(original);
  });
}
