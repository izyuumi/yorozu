import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fakeHost, probe } from "./fake-host.ts";

test("pair removes token at joined and secret at Open; interrupted joined resumes by nonce", { timeout: 25000 }, async t => {
  const host = await fakeHost(); t.after(() => host.stop());
  const dir = await mkdtemp(join(tmpdir(), "yorozu-pair-")); t.after(() => rm(dir, { recursive: true, force: true }));
  const p = probe(dir); t.after(() => p.quit()); p.send({ cmd: "pair", link: await host.link() });
  const joined = await p.wait(e => e.ev === "file" && e.standing === "known"); assert.equal(joined.hasToken, false); assert.equal(joined.hasSecret, true);
  await p.wait(e => e.ev === "conn" && e.state === "Open");
  assert.equal((await p.wait(e => e.ev === "file" && !e.hasSecret)).hasToken, false);
  await p.quit();
  const dir2 = await mkdtemp(join(tmpdir(), "yorozu-resume-")); t.after(() => rm(dir2, { recursive: true, force: true }));
  const interrupted = probe(dir2, ["--exit-after-joined-persist"]); interrupted.send({ cmd: "pair", link: await host.link() });
  await interrupted.exited;
  const resumed = probe(dir2); t.after(() => resumed.quit()); await resumed.wait(e => e.ev === "conn" && e.state === "Open");
  assert.equal((await resumed.wait(e => e.ev === "file" && !e.hasSecret)).hasToken, false);
});
