import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fakeHost, probe } from "./fake-host.ts";
test("wrong proof revoked; spent token fails after one nonce recovery", { timeout: 25000 }, async t => {
  const host = await fakeHost(); t.after(() => host.stop());
  const dir = await mkdtemp(join(tmpdir(), "yorozu-refused-")); t.after(() => rm(dir, { recursive: true, force: true }));
  const p = probe(dir); t.after(() => p.quit());
  const link = new URL(await host.link()); link.searchParams.set("secret", "AQ"); p.send({ cmd: "pair", link: link.href });
  assert.equal((await p.wait(e => e.ev === "close")).code, 4001);
  assert.equal((await p.wait(e => e.notice)).notice, "The host refused this pairing link. Make a new one with `openclaw yorozu pair`.");
  const used = await host.link(); p.send({ cmd: "pair", link: used }); await p.wait(e => e.ev === "conn" && e.state === "Open"); await p.quit();
  const dir2 = await mkdtemp(join(tmpdir(), "yorozu-spent-")); t.after(() => rm(dir2, { recursive: true, force: true }));
  const p2 = probe(dir2); t.after(() => p2.quit()); p2.send({ cmd: "pair", link: used });
  const close = await p2.wait(e => e.ev === "close"); assert.deepEqual(close, { ev: "close", code: 4001, reason: "unknown token" });
  assert.equal((await p2.wait(e => e.notice)).notice, "This pairing link has expired or was already used. Make a new one with `openclaw yorozu pair`.");
});
