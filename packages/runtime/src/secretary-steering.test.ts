import { expect, test } from "vitest";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { deliverSecretarySteer, secretarySteerReceipt } from "../dist/secretary-steering.js";

test("a durable steer intent prevents re-delivery after a lost receipt or restart", async () => {
  const dir = mkdtempSync(join(tmpdir(), "ys-steer-journal-"));
  let executions = 0;
  const request = { active: "one", text: "write B instead", files: [] };
  try {
    expect(await deliverSecretarySteer(dir, "change", request, async () => {
      expect(secretarySteerReceipt(dir, "change")).toBe("sending");
      executions += 1;
      throw new Error("connection closed after provider received input");
    })).toBe("unconfirmed");
    expect(await deliverSecretarySteer(dir, "change", request, async () => { executions += 1; return true; })).toBe("unconfirmed");
    const path = join(dir, "secretary-steering-v1", readdirSync(join(dir, "secretary-steering-v1"))[0]!);
    const retained = JSON.parse(readFileSync(path, "utf8"));
    // The other crash window: durable intent exists, but no receipt was ever saved.
    writeFileSync(path, JSON.stringify({ ...retained, receipt: "sending" }));
    expect(await deliverSecretarySteer(dir, "change", request, async () => { executions += 1; return true; })).toBe("unconfirmed");
    await expect(deliverSecretarySteer(dir, "change", { ...request, text: "different" }, async () => true)).rejects.toThrow("Conflicting");
    expect(executions).toBe(1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
