/**
 * The cleartext side-channel the Mac sends the relay alongside a sealed event, so a phone with
 * no live socket can be woken.
 *
 * Everything here is deliberately content-free. The relay — and APNs behind it — learn that
 * *something* of a given class happened in a thread named by an opaque reference, and nothing
 * else: no message text, no tool arguments, no approval details, no thread title. The event
 * itself still travels sealed on the ordinary frame; this is only the wake-up beside it.
 */
import type { YorozuEvent } from "./events.js";

/**
 * What kind of thing happened, which is the whole of what a notification says. The first four
 * are the notification classes in the spec; `activity` is not a notification at all but a Live
 * Activity update, which is why it carries no alert.
 */
export type NotifyClass = "reply" | "approval" | "done" | "failed" | "activity";

/** Where the turn has got to. Mirrors `TurnStatus` in packages/shared-swift. */
export type NotifyStatus = "working" | "needsApproval" | "done" | "failed";

/**
 * What a notification of each class says, in full. Fixed strings chosen here rather than
 * assembled from the event, because an assembled one is how content leaks: there is no path
 * from a message, a tool call or an approval card to the words on the lock screen.
 */
export const NOTIFY_BODY: Record<Exclude<NotifyClass, "activity">, string> = {
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
 * not news. What is left is a turn moving, which is either a notification or, when the phone is
 * only watching a Live Activity, a status change for it.
 */
export function notifyFor(event: YorozuEvent): { class: NotifyClass; status: NotifyStatus } | null {
  switch (event.kind) {
    // A card is the turn parked on a person: nothing moves until it is answered, which is the
    // one class worth interrupting someone for.
    case "approval_card":
    case "question_card":
      return { class: "approval", status: "needsApproval" };
    // Stop is a turn that ends deliberately and says nothing back, so nothing else will arrive
    // to end it.
    case "interrupt":
      return { class: "failed", status: "failed" };
    case "message": {
      if (event.data.role !== "agent") return null;
      // Only the *main* agent's last message ends a turn; a delegated one finishing is a step
      // of it, and the deltas before it are the turn still running.
      if (event.data.done !== true || event.parentAgentId !== undefined) {
        return { class: "activity", status: "working" };
      }
      // A turn that ran tools and said nothing is finished rather than answered, and says so:
      // "Yorozu finished" is true of it and "Yorozu replied" would not be.
      return { class: event.data.text.trim() === "" ? "done" : "reply", status: "done" };
    }
    case "thought":
    case "tool_call":
    case "tool_result":
    case "progress_card":
    case "approval_answer":
    case "question_answer":
      return { class: "activity", status: "working" };
    default:
      return null;
  }
}
