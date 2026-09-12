/**
 * macOS privacy grants, as something the agent can ask for mid-conversation.
 *
 * The rule this exists to enforce: the user grants everything once during onboarding, and if
 * something was skipped or revoked, the agent asks macOS for it again — it never tells the
 * user to go and find a checkbox in System Settings. So every native tool failure that is
 * really a missing grant comes back naming that grant, and `request_permission` is what the
 * agent does about it. See agents/main.md.
 *
 * The helper sends the grant's name in its own `permission` field rather than in the error
 * text, so nothing here has to match on English. The message fallback is only for the one
 * case that predates the field: an AppleScript `-1743`.
 */

import type { Tool } from "../index.js";
import { askNative } from "./native.js";

/** Mirrors `Permission.requestable` in apps/mac/Sources/YorozuPermissions/Permission.swift. */
export const PERMISSION_KINDS = [
  "accessibility",
  "screenRecording",
  "inputMonitoring",
  "fullDiskAccess",
  "calendars",
  "reminders",
  "contacts",
  "photos",
  "music",
  "location",
  "camera",
  "microphone",
  "files",
  "automation",
] as const;

export type PermissionKind = (typeof PERMISSION_KINDS)[number];

const isKind = (value: unknown): value is PermissionKind =>
  PERMISSION_KINDS.includes(value as PermissionKind);

/**
 * A tool failure that is a missing grant rather than a real error. The message is written for
 * the model: it says what to do next, because the one thing it must not do is pass the
 * problem back to the user as an errand.
 */
export class PermissionError extends Error {
  readonly kind: PermissionKind;

  constructor(kind: PermissionKind, detail: string) {
    super(
      `${detail} — macOS permission "${kind}" is missing. Call request_permission with ` +
        `kind "${kind}", tell the user in one line that you asked macOS for it and they ` +
        `should tap Allow on the Mac, then retry this tool once. Do not tell the user to ` +
        `open System Settings.`,
    );
    this.name = "PermissionError";
    this.kind = kind;
  }
}

/**
 * The `PermissionError` a helper reply deserves, or undefined when the failure was something
 * else. Pure, so the mapping is testable without a Mac: see permissions.test.ts.
 */
export function permissionErrorFor(response: {
  ok?: boolean;
  error?: unknown;
  permission?: unknown;
}): PermissionError | undefined {
  if (response.ok) return undefined;
  const detail = String(response.error ?? "").trim() || "the helper refused";
  if (isKind(response.permission)) return new PermissionError(response.permission, detail);
  // Older helpers, and any AppleScript path that throws before the field is attached: -1743
  // is TCC refusing to deliver an Apple event, which is always the Automation grant.
  if (/\B-1743\b/.test(detail)) return new PermissionError("automation", detail);
  return undefined;
}

/** How long the user gets to notice a system prompt and answer it. */
const WAIT_MS = 60_000;
const POLL_MS = 2_000;

export const requestPermissionTool: Tool = {
  name: "request_permission",
  description:
    "Ask macOS to show its own permission prompt for one privacy grant, and wait up to a " +
    "minute for the user to answer it. Use this whenever a tool fails because a macOS " +
    "permission is missing — never ask the user to open System Settings themselves. Kinds: " +
    PERMISSION_KINDS.join(", ") +
    ".",
  parameters: {
    type: "object",
    properties: {
      kind: {
        type: "string",
        enum: [...PERMISSION_KINDS],
        description: "The grant to ask for, as named in the failing tool's error.",
      },
    },
    required: ["kind"],
  },
  run: async ({ kind }) => {
    const want = String(kind ?? "");
    if (!isKind(want)) {
      throw new Error(`unknown permission: ${want}. One of: ${PERMISSION_KINDS.join(", ")}`);
    }
    const deadline = Date.now() + WAIT_MS;
    // The prompt itself blocks the helper until the user answers, for every grant whose API
    // reports the answer back. Location is the exception — CoreLocation tells a delegate, not
    // the caller — so the poll below is what actually notices it.
    const asked = await askNative("permission.request", { kind: want }, WAIT_MS);
    if (asked.granted) return `${want} is granted`;

    while (Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, POLL_MS));
      const { granted } = await askNative("permission.status", { kind: want });
      if (granted) return `${want} is granted`;
    }
    // Full Disk Access has no API to prompt with: asking for it opens its pane, and the user
    // has to flip it there. That is the only grant the agent may ever mention a pane for.
    if (!asked.canPrompt) {
      return (
        `${want} cannot be granted by a prompt — macOS only allows it from Privacy & ` +
        `Security ▸ Full Disk Access, which is now open on the Mac. Tell the user that, once.`
      );
    }
    return `${want} was not granted: the user did not allow it. Do not ask again this turn.`;
  },
};
