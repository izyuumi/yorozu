import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { env } from "node:process";
import { afterEach, beforeEach, expect, test } from "vitest";
import { calendarListTool, mailUnreadTool } from "./apple.js";
import { defaultNativeHost } from "./native.js";
import {
  PERMISSION_KINDS,
  PermissionError,
  permissionErrorFor,
  requestPermissionTool,
} from "./permissions.js";

/**
 * The mapping is pure, so most of this needs no Mac and no helper. The two tool tests at the
 * end use a fake helper — the same trick apple.test.ts plays — to prove the mapping is
 * actually wired into the pipe rather than just exported.
 */

test("a helper failure naming a grant becomes a PermissionError for that grant", () => {
  const error = permissionErrorFor({
    ok: false,
    error: "Calendars access is not granted",
    permission: "calendars",
  });

  expect(error).toBeInstanceOf(PermissionError);
  expect(error?.kind).toBe("calendars");
  // The message has to carry the original failure and the instruction, because the model
  // sees nothing else.
  expect(error?.message).toContain("Calendars access is not granted");
  expect(error?.message).toContain('request_permission with kind "calendars"');
  expect(error?.message).toContain("Do not tell the user to open System Settings");
});

test("every kind the helper can report maps to itself", () => {
  for (const kind of PERMISSION_KINDS) {
    expect(permissionErrorFor({ ok: false, error: "nope", permission: kind })?.kind).toBe(kind);
  }
});

test("an AppleScript -1743 is the Automation grant even with no permission field", () => {
  const error = permissionErrorFor({
    ok: false,
    error: "Automation is not granted for Mail (-1743)",
  });

  expect(error?.kind).toBe("automation");
});

test("failures that are not about permissions are left alone", () => {
  for (const response of [
    { ok: false, error: "no event with id ev1" },
    { ok: false, error: "to must be after from" },
    // A number that merely contains the digits must not look like the Apple event code.
    { ok: false, error: "no message with id 91743 in the inbox" },
    // Not a grant this build knows about: better a plain error than a bogus tool call.
    { ok: false, error: "denied", permission: "telepathy" },
  ]) {
    expect(permissionErrorFor(response)).toBeUndefined();
  }
});

test("a successful reply is never an error, whatever else it carries", () => {
  expect(permissionErrorFor({ ok: true, permission: "calendars" })).toBeUndefined();
});

test("a failure with no message at all still names the grant", () => {
  const error = permissionErrorFor({ ok: false, permission: "photos" });

  expect(error?.kind).toBe("photos");
  expect(error?.message).toContain("the helper refused");
});

// MARK: wired into the pipe

/**
 * Answers `permission.request` and `permission.status` from an env-supplied verdict, and
 * refuses calendar and mail the way TCC does, so the tools above can be driven end to end.
 */
const FAKE_HELPER = `
import { createInterface } from "node:readline";

const send = (body, request) =>
  process.stdout.write(JSON.stringify({ ok: !body.error, ...body, rid: request.rid }) + "\\n");

createInterface({ input: process.stdin }).on("line", (line) => {
  const request = JSON.parse(line);
  switch (request.cmd) {
    case "calendar.list":
      return send({ error: "Calendars access is not granted", permission: "calendars" }, request);
    case "mail.unread":
      return send({ error: "Automation is not granted for Mail (-1743)" }, request);
    case "permission.request":
    case "permission.status":
      return send(
        { kind: request.kind, granted: process.env.FAKE_GRANTED === "1", canPrompt: request.kind !== "fullDiskAccess" },
        request,
      );
    default:
      return send({ error: "unknown command: " + request.cmd }, request);
  }
});
`;

let dir: string;
let helper: string;
const saved: Record<string, string | undefined> = {};

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-permissions-"));
  helper = join(dir, "helper.mjs");
  writeFileSync(helper, FAKE_HELPER);
  for (const key of ["YOROZU_NATIVE_CMD", "YOROZU_STATE_DIR"]) saved[key] = env[key];
  env.YOROZU_STATE_DIR = dir;
  env.YOROZU_NATIVE_CMD = `FAKE_GRANTED=1 node ${helper}`;
});

afterEach(() => {
  defaultNativeHost().close();
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete env[key];
    else env[key] = value;
  }
  rmSync(dir, { recursive: true, force: true });
});

test("a calendar tool refused by TCC throws a PermissionError, not a bare error", async () => {
  await expect(Promise.resolve(calendarListTool.run({}))).rejects.toThrow(PermissionError);
  await expect(Promise.resolve(calendarListTool.run({}))).rejects.toThrow(
    /request_permission with kind "calendars"/,
  );
});

test("the -1743 mail failure is mapped over the pipe too", async () => {
  await expect(Promise.resolve(mailUnreadTool.run({}))).rejects.toThrow(
    /request_permission with kind "automation"/,
  );
});

test("request_permission reports the grant it obtained", async () => {
  expect(await requestPermissionTool.run({ kind: "calendars" })).toBe("calendars is granted");
});

test("request_permission refuses a kind that is not a grant, before asking the helper", async () => {
  await expect(Promise.resolve(requestPermissionTool.run({ kind: "telepathy" }))).rejects.toThrow(
    "unknown permission: telepathy",
  );
});
