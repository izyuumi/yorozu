import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fakeHost, probe } from "./fake-host.ts";
test("known device rejoins offline; same host reconnect opens session", { timeout: 25000 }, async t => {
  const host = await fakeHost(); t.after(() => host.stop());
  const dir = await mkdtemp(join(tmpdir(), "yorozu-offline-")); t.after(() => rm(dir, { recursive: true, force: true }));
  const p = probe(dir); t.after(() => p.quit()); p.send({ cmd: "pair", link: await host.link() }); await p.wait(e => e.ev === "conn" && e.state === "Open");
  const from = p.events.length; await host.close(); await p.wait(e => e.ev === "conn" && e.state === "Joined", from); await p.quit();
  const restarted = probe(dir); t.after(() => restarted.quit()); await restarted.wait(e => e.ev === "conn" && e.state === "Joined");
  await host.reconnect(); await restarted.wait(e => e.ev === "conn" && e.state === "Open");
});
