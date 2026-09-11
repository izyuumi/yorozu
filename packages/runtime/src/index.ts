import type { YorozuEvent } from "@yorozu/shared";

/** One line per event, as the agent loop will emit them. */
export function describeEvent(event: YorozuEvent): string {
  return `[${event.threadId}] ${event.kind}`;
}
