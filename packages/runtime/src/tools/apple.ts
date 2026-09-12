/**
 * Calendar, reminders and mail. All three live behind the Swift helper — EventKit and Mail's
 * scripting dictionary are both out of Node's reach — so these tools are the same line
 * protocol `screen_read` and `input_click` use, with the JSON turned into lines a model can
 * read. See docs/spec-v1.html section 3.
 *
 * Names use `_` where the spec writes `.`, as the native tools already do: provider function
 * names are limited to `[A-Za-z0-9_-]`.
 */

import { summarize, verifyApproved } from "../approval.js";
import type { Tool } from "../index.js";
import { askNative } from "./native.js";
import { truncate } from "./shell.js";

/** Rows the helper sends back; every field is optional because AppleScript's may be. */
type Row = Record<string, unknown>;

const rows = (value: unknown): Row[] => (Array.isArray(value) ? (value as Row[]) : []);

const str = (row: Row, key: string): string => String(row[key] ?? "");

/** A tool result the model can read, or a plain sentence when there is nothing to show. */
const lines = (found: string[], empty: string): string =>
  found.length ? truncate(found.join("\n")) : empty;

/** Only the arguments the caller actually set: an absent field must not become `"undefined"`. */
function given(args: Record<string, unknown>, keys: string[]): Record<string, unknown> {
  return Object.fromEntries(
    keys.filter((key) => args[key] !== undefined && args[key] !== null).map((key) => [key, args[key]]),
  );
}

const required = (args: Record<string, unknown>, key: string): string => {
  const value = String(args[key] ?? "").trim();
  if (!value) throw new Error(`${key} is required`);
  return value;
};

const ISO = "ISO 8601, e.g. 2026-09-12T14:00:00. No zone means the user's local time.";

// MARK: calendar

const eventLine = (event: Row): string =>
  [
    str(event, "start"),
    "→",
    str(event, "end"),
    event.allDay ? "(all day)" : "",
    str(event, "title") || "(untitled)",
    `[${str(event, "calendar")}]`,
    str(event, "location") ? `at ${str(event, "location")}` : "",
    `id=${str(event, "id")}`,
  ]
    .filter(Boolean)
    .join(" ");

export const calendarListTool: Tool = {
  name: "calendar_list",
  description: "List the user's calendars, with the name calendar_create takes.",
  parameters: { type: "object", properties: {}, required: [] },
  run: async () => {
    const { calendars } = await askNative("calendar.list");
    return lines(
      rows(calendars).map(
        (c) => `${str(c, "title")}${c.writable ? "" : " (read-only)"} id=${str(c, "id")}`,
      ),
      "no calendars",
    );
  },
};

export const calendarEventsTool: Tool = {
  name: "calendar_events",
  description:
    "List calendar events in a time window. Defaults to the next seven days. Each line ends " +
    "with the id calendar_update and calendar_delete take.",
  parameters: {
    type: "object",
    properties: {
      from: { type: "string", description: `Window start. ${ISO} Defaults to now.` },
      to: { type: "string", description: `Window end. ${ISO} Defaults to seven days out.` },
    },
    required: [],
  },
  run: async (args) => {
    const response = await askNative("calendar.events", given(args, ["from", "to"]));
    const found = rows(response.events).map(eventLine);
    return lines(
      found,
      `no events between ${str(response, "from")} and ${str(response, "to")}`,
    );
  },
};

export const calendarCreateTool: Tool = {
  name: "calendar_create",
  description: "Create a calendar event and return it, including the id it was given.",
  parameters: {
    type: "object",
    properties: {
      title: { type: "string" },
      start: { type: "string", description: ISO },
      end: { type: "string", description: ISO },
      calendar: { type: "string", description: "Calendar name. Defaults to the user's default." },
      notes: { type: "string" },
      location: { type: "string" },
    },
    required: ["title", "start", "end"],
  },
  run: async (args) => {
    required(args, "title");
    const response = await askNative(
      "calendar.create",
      given(args, ["title", "start", "end", "calendar", "notes", "location"]),
    );
    return `created ${eventLine(response.event as Row)}`;
  },
};

export const calendarUpdateTool: Tool = {
  name: "calendar_update",
  description:
    "Change an existing event. Only the fields given are touched; the id comes from " +
    "calendar_events.",
  parameters: {
    type: "object",
    properties: {
      id: { type: "string", description: "Event id from calendar_events." },
      title: { type: "string" },
      start: { type: "string", description: ISO },
      end: { type: "string", description: ISO },
      calendar: { type: "string" },
      notes: { type: "string" },
      location: { type: "string" },
    },
    required: ["id"],
  },
  run: async (args) => {
    required(args, "id");
    const response = await askNative(
      "calendar.update",
      given(args, ["id", "title", "start", "end", "calendar", "notes", "location"]),
    );
    return `updated ${eventLine(response.event as Row)}`;
  },
};

export const calendarDeleteTool: Tool = {
  name: "calendar_delete",
  description:
    "Delete a calendar event by id. For a repeating event this removes the one occurrence, " +
    "not the series.",
  parameters: {
    type: "object",
    properties: { id: { type: "string", description: "Event id from calendar_events." } },
    required: ["id"],
  },
  run: async (args) => {
    const response = await askNative("calendar.delete", { id: required(args, "id") });
    return `deleted ${str(response, "deleted") || "the event"}`;
  },
};

// MARK: reminders

const reminderLine = (reminder: Row): string =>
  [
    str(reminder, "due") ? `due ${str(reminder, "due")}` : "no due date",
    str(reminder, "title") || "(untitled)",
    `[${str(reminder, "list")}]`,
    `id=${str(reminder, "id")}`,
  ].join(" ");

export const remindersListTool: Tool = {
  name: "reminders_list",
  description:
    "List the user's open reminders, soonest due first. Completed ones are not shown.",
  parameters: {
    type: "object",
    properties: { list: { type: "string", description: "Only this list. Defaults to all." } },
    required: [],
  },
  run: async (args) => {
    const response = await askNative("reminders.list", given(args, ["list"]));
    return lines(rows(response.reminders).map(reminderLine), "no open reminders");
  },
};

export const remindersCreateTool: Tool = {
  name: "reminders_create",
  description: "Create a reminder and return it, including the id it was given.",
  parameters: {
    type: "object",
    properties: {
      title: { type: "string" },
      due: { type: "string", description: `When it is due. ${ISO} Optional.` },
      list: { type: "string", description: "Reminder list. Defaults to the user's default." },
      notes: { type: "string" },
    },
    required: ["title"],
  },
  run: async (args) => {
    required(args, "title");
    const response = await askNative(
      "reminders.create",
      given(args, ["title", "due", "list", "notes"]),
    );
    return `created ${reminderLine(response.reminder as Row)}`;
  },
};

export const remindersCompleteTool: Tool = {
  name: "reminders_complete",
  description: "Mark a reminder done, by the id reminders_list gave.",
  parameters: {
    type: "object",
    properties: { id: { type: "string", description: "Reminder id from reminders_list." } },
    required: ["id"],
  },
  run: async (args) => {
    const response = await askNative("reminders.complete", { id: required(args, "id") });
    return `completed ${str(response.reminder as Row, "title")}`;
  },
};

// MARK: mail

const messageLine = (message: Row): string =>
  [
    str(message, "date"),
    str(message, "sender"),
    str(message, "subject") || "(no subject)",
    `id=${str(message, "id")}`,
  ].join(" | ");

export const mailUnreadTool: Tool = {
  name: "mail_unread",
  description:
    "List unread messages in the user's inbox, newest first. Each line ends with the id " +
    "mail_read takes.",
  parameters: {
    type: "object",
    properties: { limit: { type: "number", description: "How many at most. Defaults to 10." } },
    required: [],
  },
  run: async (args) => {
    const limit = Number(args.limit);
    const response = await askNative("mail.unread", {
      ...(Number.isFinite(limit) && limit > 0 ? { limit: Math.floor(limit) } : {}),
    });
    return lines(rows(response.messages).map(messageLine), "no unread mail");
  },
};

export const mailReadTool: Tool = {
  name: "mail_read",
  description: "Read one inbox message in full, by the id mail_unread gave.",
  parameters: {
    type: "object",
    properties: { id: { type: "string", description: "Message id from mail_unread." } },
    required: ["id"],
  },
  run: async (args) => {
    const response = await askNative("mail.read", { id: required(args, "id") });
    const message = response.message as Row;
    return truncate(`${messageLine(message)}\n\n${str(message, "body")}`);
  },
};

/** `to` as the card lists it: one address per line, blanks dropped. */
export const recipientList = (to: string): string[] =>
  to.split(",").map((address) => address.trim()).filter((address) => address !== "");

export const mailSendTool: Tool = {
  name: "mail_send",
  description:
    "Send an email from the user's Mail account. Only send what the user approved: this " +
    "leaves the Mac and cannot be taken back.",
  // The one tool here with an effect outside the Mac, so it goes through the approval
  // engine. It fills the card in properly: who it goes to, what it says, and — when it goes
  // to several people at once — the exact list of them, which is what the one decision covers.
  actionClass: "send-message",
  action: ({ to, subject, body }) => ({
    target: String(to ?? ""),
    operation: "send",
    recipient: String(to ?? ""),
    contentSummary: summarize(`${String(subject ?? "")}\n\n${String(body ?? "")}`.trim()),
    consequence: "Sends this email from the user's own Mail account. It cannot be recalled.",
  }),
  batch: ({ to, subject }) => {
    const recipients = recipientList(String(to ?? ""));
    // One recipient is not a batch: the card already names them, and a list of one reads oddly.
    if (recipients.length < 2) return [];
    return recipients.map((recipient) => ({
      label: recipient,
      ...(subject ? { detail: String(subject) } : {}),
    }));
  },
  parameters: {
    type: "object",
    properties: {
      to: { type: "string", description: "Recipient address, or several separated by commas." },
      subject: { type: "string" },
      body: { type: "string" },
    },
    required: ["to", "subject", "body"],
  },
  run: async (args, context) => {
    const to = required(args, "to");
    // The last thing before the mail leaves: what was approved has to be what is being sent.
    // Nothing here can change `to` behind the user's back, but a tool that commits is the
    // right place to prove that rather than to assume it.
    if (context?.actionId) {
      const stale = verifyApproved(context.actionId, {
        recipient: to,
        items: mailSendTool.batch?.(args) ?? [],
      });
      if (stale) return stale;
    }
    const response = await askNative("mail.send", {
      to,
      subject: String(args.subject ?? ""),
      body: String(args.body ?? ""),
    });
    const sent = Array.isArray(response.sent) ? (response.sent as string[]) : [];
    return `sent to ${sent.join(", ")}`;
  },
};

export const appleTools: Tool[] = [
  calendarListTool,
  calendarEventsTool,
  calendarCreateTool,
  calendarUpdateTool,
  calendarDeleteTool,
  remindersListTool,
  remindersCreateTool,
  remindersCompleteTool,
  mailUnreadTool,
  mailReadTool,
  mailSendTool,
];
