/**
 * The cleartext side-channel the Mac sends the relay alongside a sealed event, so a phone with
 * no live socket can be woken.
 *
 * Its cleartext fields are deliberately content-free. The relay — and APNs behind it — learn
 * that *something* of a given class happened in a thread named by an opaque reference. A reply
 * or a card may also carry a separately sealed preview which only that phone can open: the
 * words for the lock screen, the reference of the card they are about, and whether the Mac
 * judged that card answerable from a button — see `NotificationPreviewContent`.
 */
import type { ApprovalCardData, QuestionCardData, YorozuEvent } from "./events.js";

/** Maximum plaintext bytes carried by an encrypted lock-screen preview's `body`. */
export const NOTIFY_PREVIEW_BYTES = 256;

/** The `v` a sealed preview's plaintext carries. A plaintext without one is a bare body. */
export const NOTIFY_PREVIEW_VERSION = 1;

/**
 * What a sealed preview says once opened. The phone shows `body`, and draws Allow and Deny
 * only when `quick` is set *and* `event` names the card the push is about — both sealed by the
 * Mac, so a relay that redraws the buttons under a different card, or under a card the Mac
 * sent for review, changes nothing.
 */
export interface NotificationPreviewContent {
  /** The reply's text, or the card's one-line summary. */
  body: string;
  /** `threadRef(event.id)` of the card or message this preview is about; null when unknown. */
  event: string | null;
  /** Authenticated destination, unlike relay-written `ref`. */
  thread?: string;
  class?: NotifyClass;
  /** Whether the Mac judged this card answerable from the lock screen. Never true for a reply. */
  quick: boolean;
  /** The thread's title, shown as the notification's title; null when unknown. */
  title?: string | null;
}

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
      return null;
    case "message": {
      if (event.data.role !== "agent") return null;
      // Only the *main* agent's last message ends a turn; a delegated one finishing is a step
      // of it, and the deltas before it are the turn still running.
      if (event.data.done !== true || event.parentAgentId !== undefined) return null;
      if (event.data.failed === true) return "failed";
      // A turn that ran tools and said nothing is finished rather than answered, and says so:
      // "Yorozu finished" is true of it and "Yorozu replied" would not be.
      return event.data.text.trim() === "" ? "done" : "reply";
    }
    default:
      return null;
  }
}

/** The first `limit` bytes of a text, cut between characters so no glyph is split. */
function boundedBytes(text: string, limit = NOTIFY_PREVIEW_BYTES): string {
  let bytes = 0;
  let preview = "";
  for (const character of text) {
    const size = Buffer.byteLength(character);
    if (bytes + size > limit) break;
    preview += character;
    bytes += size;
  }
  return preview;
}

/** The wire class as a phrase, the same words the card itself leads with. */
const CARD_VERBS: Record<string, string> = {
  "send-message": "Send a message",
  purchase: "Make a purchase",
  "transfer-money": "Transfer money",
  book: "Make a booking",
  "run-command": "Run a command",
  "edit-file": "Change a file",
  "delete-file": "Delete a file",
};

/**
 * One line for an approval card: what it wants to do and to what, which is what the lock
 * screen needs to ask "Allow?" over. A native SDK card leads with the tool it names.
 */
export function approvalCardSummary(card: ApprovalCardData): string {
  const words = card.actionClass.replace(/-/g, " ");
  const verb = card.nativeAgent
    ? card.actionClass
    : CARD_VERBS[card.actionClass] ?? words.charAt(0).toUpperCase() + words.slice(1);
  const target = card.target.trim().replace(/\s+/g, " ");
  return target ? `${verb}: ${target}` : verb;
}

/** One line for a question card: the question itself. */
export function questionCardSummary(card: QuestionCardData): string {
  return card.question.trim().replace(/\s+/g, " ");
}

/**
 * The words a preview carries for an event, bounded before encryption so APNs stays well
 * below 4 KB: a completed reply's text, or a card's summary. Nothing else has a preview.
 */
export function notificationPreviewBody(event: YorozuEvent): string | null {
  switch (notifyFor(event)) {
    case "reply":
      return event.kind === "message" ? boundedBytes(event.data.text.trim()) || null : null;
    case "approval":
      if (event.kind === "approval_card") return boundedBytes(approvalCardSummary(event.data)) || null;
      if (event.kind === "question_card") return boundedBytes(questionCardSummary(event.data)) || null;
      return null;
    default:
      return null;
  }
}

/** How much of a preview's bytes a thread title may take from the body. */
const NOTIFY_TITLE_BYTES = 64;

/**
 * The plaintext that is sealed into a preview box: the versioned JSON object, as a whole within
 * `NOTIFY_PREVIEW_BYTES` — the relay refuses a bigger box. The body gives way to fit.
 */
export function encodeNotificationPreview(content: NotificationPreviewContent): string {
  let title = [...boundedBytes(content.title?.trim().replace(/\s+/g, " ") ?? "", NOTIFY_TITLE_BYTES)];
  const encode = (body: string): string =>
    JSON.stringify({
      v: NOTIFY_PREVIEW_VERSION,
      body,
      event: content.event,
      ...(content.thread ? { thread: content.thread } : {}),
      ...(content.class ? { class: content.class } : {}),
      quick: content.quick === true,
      ...(title.length ? { title: title.join("") } : {}),
    });
  let body = [...content.body];
  let plaintext = encode(content.body);
  // Escapes make the encoded size differ from the text's, so trim and re-measure.
  while (Buffer.byteLength(plaintext) > NOTIFY_PREVIEW_BYTES && body.length > 1) {
    const over = Buffer.byteLength(plaintext) - NOTIFY_PREVIEW_BYTES;
    body = body.slice(0, Math.max(1, body.length - Math.ceil(over / 4)));
    plaintext = encode(body.join(""));
  }
  while (Buffer.byteLength(plaintext) > NOTIFY_PREVIEW_BYTES && title.length > 0) {
    title.pop();
    plaintext = encode(body.join(""));
  }
  if (Buffer.byteLength(plaintext) > NOTIFY_PREVIEW_BYTES) {
    throw new Error("notification preview routing exceeds byte limit");
  }
  return plaintext;
}

/**
 * What an opened preview box says. A plaintext that is not a JSON object, or one without a
 * `v`, is a preview from before the object existed: its whole text is the body, it is about
 * no card in particular, and it permits no button. An empty body is no preview at all.
 */
export function decodeNotificationPreview(plaintext: string): NotificationPreviewContent | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(plaintext);
  } catch {
    parsed = undefined;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed) || !("v" in parsed)) {
    return plaintext === "" ? null : { body: plaintext, event: null, quick: false };
  }
  const object = parsed as Record<string, unknown>;
  const body = typeof object.body === "string" ? object.body : "";
  if (body === "") return null;
  return {
    body,
    event: typeof object.event === "string" && object.event !== "" ? object.event : null,
    ...(typeof object.thread === "string" && object.thread !== "" && object.thread.length <= 128
      ? { thread: object.thread } : {}),
    ...(["reply", "approval", "done", "failed"].includes(String(object.class))
      ? { class: object.class as NotifyClass } : {}),
    quick: object.quick === true,
    ...(typeof object.title === "string" && object.title !== "" ? { title: object.title } : {}),
  };
}
