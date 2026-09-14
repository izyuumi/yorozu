/**
 * The cleartext side-channel the Mac sends the relay alongside a sealed event, so a phone with
 * no live socket can be woken.
 *
 * Its cleartext fields are deliberately content-free. The relay — and APNs behind it — learn
 * that *something* of a given class happened in a thread named by an opaque reference. A reply
 * may also carry a separately sealed preview which only that phone can open.
 */
import type { YorozuEvent } from "./events.js";

/** Maximum plaintext bytes carried by an encrypted lock-screen reply preview. */
export const NOTIFY_PREVIEW_BYTES = 256;

/** What kind of thing happened, which is the whole of what a notification says. */
export type NotifyClass = "reply" | "approval" | "done" | "failed";

/**
 * Fixed fallback text for each class. The notification extension replaces a reply body only
 * after authenticating its encrypted preview; every other path keeps this content-free phrase.
 */
export const NOTIFY_BODY: Record<NotifyClass, string> = {
  reply: "Yorozu replied.",
  approval: "Yorozu needs your approval.",
  done: "Yorozu finished.",
  failed: "Yorozu stopped.",
};

export const NOTIFY_TITLE = "Yorozu";

/**
 * The wake-up an event is worth, or null for one that is nobody's business but this device's.
 *
 * A user's own message says nothing to the phone that sent it, and the thread and control
 * frames — lists, rules, devices, sync — are answers to something the phone asked for and are
 * not news. Nor is a turn merely moving: deltas, tool traffic and a delegated agent finishing
 * are the turn still running, and nobody is woken for that. What is left is a turn arriving
 * somewhere a person has to be told about.
 */
export function notifyFor(event: YorozuEvent): NotifyClass | null {
  switch (event.kind) {
    // A card is the turn parked on a person: nothing moves until it is answered, which is the
    // one class worth interrupting someone for.
    case "approval_card":
    case "question_card":
      return "approval";
    // Stop is a turn that ends deliberately and says nothing back, so nothing else will arrive
    // to end it.
    case "interrupt":
      return "failed";
    case "message": {
      if (event.data.role !== "agent") return null;
      // Only the *main* agent's last message ends a turn; a delegated one finishing is a step
      // of it, and the deltas before it are the turn still running.
      if (event.data.done !== true || event.parentAgentId !== undefined) return null;
      // A turn that ran tools and said nothing is finished rather than answered, and says so:
      // "Yorozu finished" is true of it and "Yorozu replied" would not be.
      return event.data.text.trim() === "" ? "done" : "reply";
    }
    default:
      return null;
  }
}

/** Reply text worth previewing, bounded before encryption so APNs stays well below 4 KB. */
export function notificationPreview(event: YorozuEvent): string | null {
  if (notifyFor(event) !== "reply" || event.kind !== "message") return null;
  const text = event.data.text.trim();
  let bytes = 0;
  let preview = "";
  for (const character of text) {
    const size = Buffer.byteLength(character);
    if (bytes + size > NOTIFY_PREVIEW_BYTES) break;
    preview += character;
    bytes += size;
  }
  return preview || null;
}
