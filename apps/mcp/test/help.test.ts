import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { findPersonalData } from "../scripts/privacy.ts";
import { content } from "../src/content.ts";
import * as help from "../src/help.ts";

test("the bundle holds no personal data", () => {
  const raw = readFileSync(new URL("../src/content.json", import.meta.url), "utf8");
  assert.deepEqual(findPersonalData(raw), []);
});

test("the personal-data scan catches what it should", () => {
  for (const sample of ["/Users/someone/x", "/home/someone/x", "a.person@example.com", `ghp_${"a".repeat(36)}`, `sk-${"a".repeat(30)}`, `AKIA${"A".repeat(16)}`, "-----BEGIN PRIVATE KEY-----"]) {
    assert.notDeepEqual(findPersonalData(sample), [], sample);
  }
});

test("the bundle covers the docs, settings, permissions and releases", () => {
  const ids = content.docs.map((d) => d.id);
  for (const id of ["readme", "setup", "release", "plugin", "help-mcp"]) assert.ok(ids.includes(id), id);
  assert.ok(content.settings.app.some((s) => s.key === "accent" && s.options?.length));
  assert.ok(content.settings.host.some((s) => s.key === "channels.yorozu.agent"));
  assert.ok(content.permissions.ios.some((p) => p.key === "NSMicrophoneUsageDescription" && p.prompt));
  assert.ok(content.permissions.macos.some((p) => p.key === "com.apple.security.device.audio-input"));
  assert.match(content.releases[0].version, /^\d+\.\d+\.\d+$/);
});

test("searchDocs ranks the matching section first and ignores stopwords", () => {
  const [first] = help.searchDocs(content, "how do I pair a device");
  assert.match(first.heading, /pair/i);
  assert.ok(first.uri.startsWith("yorozu://docs/"));
  assert.deepEqual(help.searchDocs(content, "the a of"), []);
  assert.equal(help.searchDocs(content, "relay", 2).length, 2);
  assert.match(help.formatDocHits("zzqx", []), /No docs match/);
});

test("troubleshoot matches the voice-model pack state and the offline states", () => {
  const voice = help.troubleshoot(content, "The voice model isn’t available for this version of Yorozu yet");
  assert.match(voice.matches[0].fix, /assetPackNotFound|asset pack/);
  const relay = help.troubleshoot(content, "relay offline");
  assert.ok(relay.matches.some((m) => /relay/i.test(m.symptom)));
  const gateway = help.troubleshoot(content, "Gateway offline");
  assert.ok(gateway.matches.some((m) => /gateway|host/i.test(m.symptom)));
  assert.match(help.formatTroubleshoot("zzqx", help.troubleshoot(content, "zzqx")), /No known problem/);
});

test("settings lookups accept keys, titles and short host keys", () => {
  assert.equal(help.findSetting(content, "Accent")?.key, "accent");
  assert.equal(help.findSetting(content, "agent")?.key, "channels.yorozu.agent");
  assert.equal(help.findSetting(content, "nope"), undefined);
  const mac = help.listSettings(content, "macos");
  assert.ok(mac.app.every((s) => s.platforms.includes("macos")));
  assert.ok(!mac.app.some((s) => s.key === "noticeHaptics"));
});

test("setup guide, permissions, version and changelog", () => {
  assert.match(help.setupGuide(content, "ios"), /App Store/);
  assert.match(help.setupGuide(content, "macos"), /yorozu\.yumi\.to\/mac/);
  assert.equal(help.permissionsNeeded(content, "ios").platform, "ios");
  assert.equal(help.latestVersion(content).version, content.releases[0].version);
  assert.match(help.changelog(content, `v${content.releases.at(-1)!.version}`) ?? "", /^## /);
  assert.equal(help.changelog(content, "99.0.0"), undefined);
  assert.equal(help.changelog(content, undefined, 1)?.match(/^## /gm)?.length, 1);
});
