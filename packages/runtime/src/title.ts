/**
 * Auto-titling: a thread is created unnamed and named once, from its opening message, while
 * the agent works on the reply. Only an empty title is ever filled in, which is the whole of
 * the rule that a title the user typed with Rename is never overwritten.
 */
import type { Provider } from "./provider.js";
import { listThreads, renameThread } from "./threads.js";

/**
 * A title is a nicety: past this the thread gets the placeholder title instead of the phone
 * waiting. Long enough for a CLI provider to cold-start.
 */
const TITLE_TIMEOUT_MS = 15_000;
const TITLE_SYSTEM =
  "Reply with a 3-5 word title for this conversation, no quotes, no trailing period";
/** How much of the opening message the titler is shown. */
const TITLE_CONTEXT_CHARS = 500;

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
 * there is no titler, or it does not answer in time, the message's first five words serve,
 * so no thread that was ever written in stays "New chat". True when the title changed.
 */
export async function autoTitle(threadId: string, opening: string, titler: Provider | undefined, dir: string): Promise<boolean> {
  const untitled = (): boolean =>
    listThreads(dir).find((thread) => thread.id === threadId)?.title === "";
  opening = opening.trim();
  if (!opening || !untitled()) return false;

  const ask = async (): Promise<string> => {
    if (!titler) return "";
    let text = "";
    for await (const event of titler.stream(
      [{ role: "system", content: TITLE_SYSTEM }, { role: "user", content: opening.slice(0, TITLE_CONTEXT_CHARS) }],
      [],
    )) {
      if (event.type === "text") text += event.text;
    }
    return text;
  };
  const answered = await Promise.race([
    ask().catch(() => ""),
    new Promise<string>((resolve) => {
      setTimeout(() => resolve(""), TITLE_TIMEOUT_MS).unref?.();
    }),
  ]);
  const title = cleanTitle(answered) || cleanTitle(opening.split(/\s+/).slice(0, 5).join(" "));

  // Re-checked: a rename may have landed while the titler was thinking.
  if (!title || !untitled()) return false;
  return renameThread(threadId, title, dir);
}
