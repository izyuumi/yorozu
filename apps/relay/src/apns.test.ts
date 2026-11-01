import { expect, test } from "vitest";
import { configured, dead, gone, topic } from "./apns.js";

test("a room without a complete apple key is not configured, and wakes nobody", () => {
  expect(configured({})).toBe(false);
  expect(configured({ APNS_KEY_ID: "k" })).toBe(false);
  expect(configured({ APNS_KEY_ID: "k", APNS_TEAM_ID: "t" })).toBe(false);
  expect(configured({ APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_KEY_P8: "pem" })).toBe(true);
});

test("only an unregistered token is dead", () => {
  expect(gone(410)).toBe(true);
  expect(gone(400)).toBe(false);
  expect(gone(200)).toBe(false);
  expect(gone(429)).toBe(false);
  expect(gone(500)).toBe(false);
});

test("a live activity token is dropped when apple says it is gone, and kept through passing trouble", () => {
  expect(dead({ status: 410, reason: "Unregistered" })).toBe(true);
  expect(dead({ status: 410, reason: "ExpiredToken" })).toBe(true);
  expect(dead({ status: 400, reason: "BadDeviceToken" })).toBe(true);
  expect(dead({ status: 400, reason: "ExpiredToken" })).toBe(true);
  expect(dead({ status: 400, reason: "BadTopic" })).toBe(false);
  expect(dead({ status: 429, reason: "TooManyRequests" })).toBe(false);
  expect(dead({ status: 500 })).toBe(false);
  expect(dead({ status: 200 })).toBe(false);
});

test("a live activity push goes to the app's topic with apple's suffix", () => {
  expect(topic({}, "alert")).toBe("to.yumi.yorozu.ios");
  expect(topic({}, "liveactivity")).toBe("to.yumi.yorozu.ios.push-type.liveactivity");
  expect(topic({ APNS_TOPIC: "example.app" }, "liveactivity")).toBe("example.app.push-type.liveactivity");
  expect(topic({ APNS_TOPIC: "example.app" }, "background")).toBe("example.app");
});
