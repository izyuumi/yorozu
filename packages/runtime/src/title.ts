/**
 * Auto-titling: a thread is created unnamed and named once, from its opening message, while
 * the agent works on the reply. Only an empty title is ever filled in, which is the whole of
 * the rule that a title the user typed with Rename is never overwritten.
 *
 * The title comes from the Mac's on-device model, not the configured chain: the opening
 * message is the one piece of chat content that would otherwise go to a cloud model for
 * something that is only a label, and Apple's model needs nothing signed in to.
 */
import { listThreads, renameThread } from "./threads.js";
import { askNative } from "./tools/native.js";

/**
 * A title is a nicety: past this the thread gets the placeholder title instead of the phone
 * waiting. Long enough for the on-device model to load on a cold Mac.
 */
const TITLE_TIMEOUT_MS = 15_000;
/** How much of the opening message the titler is shown. */
const TITLE_CONTEXT_CHARS = 500;

/** Answers an opening message with a title. An empty answer, or a throw, means "no title". */
export type Titler = (opening: string) => Promise<string>;

/**
 * Apple's on-device model, through `yorozu-native`, which is the same helper the Mac's
 * calendar and screen tools already speak to. The helper's own error — no Apple Intelligence
 * on this Mac, or the helper not built in a checkout — is the caller's cue to fall back.
 */
export const onDeviceTitler: Titler = async (opening) =>
  String((await askNative("title.generate", { text: opening }, TITLE_TIMEOUT_MS)).title ?? "");

/** The model's answer as a title: one line, no quotes, no trailing period, and short. */
export function cleanTitle(raw: string): string {
  return raw
    .split("\n")
    .map((line) => line.replace(/["'`]/g, "").trim())
    .find((line) => line !== "")
    ?.replace(/[.\s]+$/, "")
    .slice(0, 60) ?? "";
}

/**
 * Names a thread from its opening message, once. Runs alongside the turn, not after it: the
 * titler is asked as soon as the message lands, so the title usually beats the reply. When
 * the titler fails, or does not answer in time, the message's first five words serve, so no
 * thread that was ever written in stays "New chat". True when the title changed.
 */
export async function autoTitle(threadId: string, opening: string, titler: Titler, dir: string): Promise<boolean> {
  const untitled = (): boolean =>
    listThreads(dir).find((thread) => thread.id === threadId)?.title === "";
  opening = opening.trim();
  if (!opening || !untitled()) return false;

  const answered = await Promise.race([
    titler(opening.slice(0, TITLE_CONTEXT_CHARS)).catch(() => ""),
    new Promise<string>((resolve) => {
      setTimeout(() => resolve(""), TITLE_TIMEOUT_MS).unref?.();
    }),
  ]);
  const title = cleanTitle(answered) || cleanTitle(opening.split(/\s+/).slice(0, 5).join(" "));

  // Re-checked: a rename may have landed while the titler was thinking.
  if (!title || !untitled()) return false;
  return renameThread(threadId, title, dir);
}
