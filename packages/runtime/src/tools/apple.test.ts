import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { env } from "node:process";
import { afterEach, beforeEach, expect, test } from "vitest";
import {
  calendarCreateTool,
  calendarDeleteTool,
  calendarEventsTool,
  calendarListTool,
  calendarUpdateTool,
  mailReadTool,
  mailSendTool,
  mailUnreadTool,
  remindersCompleteTool,
  remindersCreateTool,
  remindersListTool,
} from "./apple.js";
import { defaultNativeHost } from "./native.js";

/**
 * A stand-in for the Swift helper, speaking the same line protocol as the one in
 * native.test.ts, so the calendar, reminders and mail tools are testable without EventKit,
 * without Mail and without a Mac. Every reply carries `echo`, which is the request verbatim:
 * that is how a test asserts which arguments actually crossed the pipe.
 *
 * `FAKE_MODE=denied` answers every mail command the way TCC does when Automation was never
 * granted, which is the failure this machine actually has.
 */
const FAKE_HELPER = `
import { createInterface } from "node:readline";

const send = (body, request) =>
  process.stdout.write(JSON.stringify({ ok: !body.error, ...body, echo: request, rid: request.rid }) + "\\n");

const EVENTS = [
  { id: "ev1", title: "Standup", start: "2026-09-14T09:30:00Z", end: "2026-09-14T09:45:00Z",
    calendar: "Work", allDay: false },
  { id: "ev2", title: "Dentist", start: "2026-09-15T11:00:00Z", end: "2026-09-15T12:00:00Z",
    calendar: "Home", allDay: false, location: "Clinic" },
];

const REMINDERS = [
  { id: "r1", title: "Buy milk", list: "Home", due: "2026-09-13T18:00:00Z", completed: false },
  { id: "r2", title: "Someday", list: "Home", completed: false },
];

const DENIED =
  "Automation is not granted for Mail (-1743). Grant it in System Settings \\u25b8 " +
  "Privacy & Security \\u25b8 Automation, under Yorozu.";

createInterface({ input: process.stdin }).on("line", (line) => {
  const request = JSON.parse(line);
  const cmd = request.cmd;
  if (cmd.startsWith("mail.") && process.env.FAKE_MODE === "denied") {
    return send({ error: DENIED }, request);
  }
  switch (cmd) {
    case "calendar.list":
      return send(
        { calendars: [
          { id: "c1", title: "Work", writable: true },
          { id: "c2", title: "Holidays", writable: false },
        ] },
        request,
      );
    case "calendar.events":
      return send(
        {
          from: request.from ?? "2026-09-12T00:00:00Z",
          to: request.to ?? "2026-09-19T00:00:00Z",
          events: request.from === "2030-01-01" ? [] : EVENTS,
        },
        request,
      );
    case "calendar.create":
      return send(
        { event: { id: "ev9", allDay: false, calendar: request.calendar ?? "Work",
                   title: request.title, start: request.start, end: request.end } },
        request,
      );
    case "calendar.update":
      return send(
        { event: { id: request.id, allDay: false, calendar: "Work",
                   title: request.title ?? "Standup",
                   start: request.start ?? "2026-09-14T09:30:00Z",
                   end: request.end ?? "2026-09-14T09:45:00Z" } },
        request,
      );
    case "calendar.delete":
      return send({ deleted: "Standup" }, request);
    case "reminders.list":
      return send({ reminders: REMINDERS }, request);
    case "reminders.create":
      return send(
        { reminder: { id: "r9", title: request.title, list: request.list ?? "Home",
                      ...(request.due ? { due: request.due } : {}), completed: false } },
        request,
      );
    case "reminders.complete":
      return send(
        { reminder: { id: request.id, title: "Buy milk", list: "Home", completed: true } },
        request,
      );
    case "mail.unread": {
      const limit = request.limit ?? 10;
      return send(
        { messages: Array.from({ length: limit }, (_, i) => ({
            id: String(i + 1), sender: "someone" + (i + 1) + "@example.com",
            subject: "Subject " + (i + 1), date: "Saturday 12 September 2026 at 09:0" + i,
          })) },
        request,
      );
    }
    case "mail.read":
      if (request.id !== "42") {
        return send({ error: "no message with id " + request.id + " in the inbox" }, request);
      }
      return send(
        { message: { id: "42", sender: "a@example.com", subject: "Lunch",
                     date: "Saturday 12 September 2026 at 09:00", body: "Are you free?" } },
        request,
      );
    case "mail.send":
      return send({ sent: request.to.split(",").map((a) => a.trim()) }, request);
    default:
      return send({ error: "unknown command: " + cmd }, request);
  }
});
`;

let dir: string;
let helper: string;
const saved: Record<string, string | undefined> = {};

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-apple-"));
  helper = join(dir, "helper.mjs");
  writeFileSync(helper, FAKE_HELPER);
  for (const key of ["YOROZU_NATIVE_CMD", "YOROZU_STATE_DIR"]) saved[key] = env[key];
  env.YOROZU_STATE_DIR = dir;
  env.YOROZU_NATIVE_CMD = `node ${helper}`;
});

afterEach(() => {
  defaultNativeHost().close();
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete env[key];
    else env[key] = value;
  }
  rmSync(dir, { recursive: true, force: true });
});

const denyMail = (): void => {
  env.YOROZU_NATIVE_CMD = `FAKE_MODE=denied node ${helper}`;
};

test("calendar_list names each calendar and whether it can be written to", async () => {
  expect((await calendarListTool.run({})).split("\n")).toEqual([
    "Work id=c1",
    "Holidays (read-only) id=c2",
  ]);
});

test("calendar_events formats a window and carries the id for later edits", async () => {
  const out = await calendarEventsTool.run({ from: "2026-09-14T00:00:00", to: "2026-09-16T00:00:00" });

  expect(out.split("\n")).toEqual([
    "2026-09-14T09:30:00Z → 2026-09-14T09:45:00Z Standup [Work] id=ev1",
    "2026-09-15T11:00:00Z → 2026-09-15T12:00:00Z Dentist [Home] at Clinic id=ev2",
  ]);
});

test("an empty window says so, with the window it actually looked at", async () => {
  const out = await calendarEventsTool.run({ from: "2030-01-01" });

  expect(out).toBe("no events between 2030-01-01 and 2026-09-19T00:00:00Z");
});

test("arguments the model left out are never sent as undefined", async () => {
  await calendarEventsTool.run({});
  const { echo } = await defaultNativeHost().request("calendar.events", {});

  // The helper defaults the window; the tool must not have invented one.
  expect(Object.keys(echo as Record<string, unknown>).sort()).toEqual(["cmd", "rid"]);
});

test("calendar_create passes the event through and reports what was made", async () => {
  const out = await calendarCreateTool.run({
    title: "Lunch",
    start: "2026-09-14T12:00:00Z",
    end: "2026-09-14T13:00:00Z",
    calendar: "Home",
  });

  expect(out).toBe("created 2026-09-14T12:00:00Z → 2026-09-14T13:00:00Z Lunch [Home] id=ev9");
});

test("calendar_update changes only what it was given", async () => {
  const out = await calendarUpdateTool.run({ id: "ev1", title: "Standup (moved)" });

  expect(out).toContain("updated");
  expect(out).toContain("Standup (moved)");
  expect(out).toContain("id=ev1");
});

test("calendar_delete reports the event it removed", async () => {
  expect(await calendarDeleteTool.run({ id: "ev1" })).toBe("deleted Standup");
});

test("reminders_list shows due dates and says when there is none", async () => {
  expect((await remindersListTool.run({})).split("\n")).toEqual([
    "due 2026-09-13T18:00:00Z Buy milk [Home] id=r1",
    "no due date Someday [Home] id=r2",
  ]);
});

test("reminders_create and reminders_complete round-trip one reminder", async () => {
  expect(await remindersCreateTool.run({ title: "Call the dentist", due: "2026-09-13T10:00:00Z" })).toBe(
    "created due 2026-09-13T10:00:00Z Call the dentist [Home] id=r9",
  );
  expect(await remindersCompleteTool.run({ id: "r1" })).toBe("completed Buy milk");
});

test("mail_unread asks for the limit it was given", async () => {
  expect((await mailUnreadTool.run({ limit: 2 })).split("\n")).toEqual([
    "Saturday 12 September 2026 at 09:00 | someone1@example.com | Subject 1 | id=1",
    "Saturday 12 September 2026 at 09:01 | someone2@example.com | Subject 2 | id=2",
  ]);
  expect((await mailUnreadTool.run({})).split("\n")).toHaveLength(10);
});

test("mail_read returns the header line and then the body", async () => {
  const out = await mailReadTool.run({ id: "42" });

  expect(out.split("\n")).toEqual([
    "Saturday 12 September 2026 at 09:00 | a@example.com | Lunch | id=42",
    "",
    "Are you free?",
  ]);
});

test("a message that is not there is an error the model can act on", async () => {
  await expect(Promise.resolve(mailReadTool.run({ id: "7" }))).rejects.toThrow(
    "no message with id 7 in the inbox",
  );
});

test("mail_send reports every recipient it sent to", async () => {
  expect(await mailSendTool.run({ to: "a@example.com, b@example.com", subject: "Hi", body: "There" })).toBe(
    "sent to a@example.com, b@example.com",
  );
});

test("a missing Automation grant is a readable error, not a crash", async () => {
  denyMail();

  for (const run of [
    () => mailUnreadTool.run({ limit: 1 }),
    () => mailReadTool.run({ id: "42" }),
    () => mailSendTool.run({ to: "a@example.com", subject: "s", body: "b" }),
  ]) {
    await expect(Promise.resolve(run())).rejects.toThrow(/-1743/);
  }
});

test("a required argument the model omitted fails before the helper is asked", async () => {
  await expect(Promise.resolve(calendarDeleteTool.run({}))).rejects.toThrow("id is required");
  await expect(Promise.resolve(remindersCompleteTool.run({}))).rejects.toThrow("id is required");
  await expect(Promise.resolve(mailSendTool.run({ subject: "s", body: "b" }))).rejects.toThrow(
    "to is required",
  );
});
