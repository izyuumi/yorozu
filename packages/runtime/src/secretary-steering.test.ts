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

test("durable admission intent fences restart after failed stop persistence without using history absence", async () => {
  const { SecretaryAdmissionFence } = await import("../dist/secretary-steering.js");
  const dir = mkdtempSync(join(tmpdir(), "ys-admission-fence-"));
  try {
    const fence = new SecretaryAdmissionFence(dir);
    fence.begin("thread:request");
    fence.fail(); // stop journal failed after native handoff
    expect(() => fence.begin("other-thread:new-request")).toThrow("held");
    expect(new SecretaryAdmissionFence(dir).blocked).toBe(true);
    // No final-history lookup, deletion, dismissal or replay is attempted.
    expect(readdirSync(fence.root)).toHaveLength(1);
    // Fencing new execution must not prevent recording further stop controls.
    fence.begin("stop-other", "journal"); fence.confirmed("stop-other");
    expect(fence.blocked).toBe(true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("positive cessation consumes only its exact durable execution intent", async () => {
  const { SecretaryAdmissionFence } = await import("../dist/secretary-steering.js");
  const dir = mkdtempSync(join(tmpdir(), "ys-admission-confirmed-"));
  try {
    const fence = new SecretaryAdmissionFence(dir); fence.begin("settled"); fence.begin("unknown"); fence.confirmed("settled");
    expect(new SecretaryAdmissionFence(dir).blocked).toBe(true);
    fence.confirmed("unknown"); expect(new SecretaryAdmissionFence(dir).blocked).toBe(false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
