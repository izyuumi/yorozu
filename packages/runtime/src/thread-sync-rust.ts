import type { YorozuEvent } from "@yorozu/shared";
import { syncHostRequest } from "./rust-sync.js";
export function rustSyncPage(dir: string, threadId: string, after: string | undefined, minTs: number,
  includeApprovalStatus: boolean, includeQuestionStatus = true): { events: YorozuEvent[]; more: boolean } {
  const result = syncHostRequest(dir, { op: "history_page", threadId, ...(after === undefined ? {} : { after }), minTs, includeApprovalStatus, includeQuestionStatus });
  if (!Array.isArray(result.events) || typeof result.more !== "boolean") throw new Error("History page remains unconfirmed");
  return { events: result.events as YorozuEvent[], more: result.more };
}
