import type { YorozuEvent } from "@yorozu/shared";
import { syncHostRequest } from "./rust-sync.js";
export function rustSyncPage(dir: string, threadId: string, after: string | undefined, minTs: number,
  includeApprovalStatus: boolean): { events: YorozuEvent[]; more: boolean } {
  let result = syncHostRequest(dir, { op: "history_page", threadId, ...(after === undefined ? {} : { after }), minTs, includeApprovalStatus });
  if (typeof result.token === "string" && typeof result.responseBytes === "number")
    result = syncHostRequest(dir, { op: "history_page_result", token: result.token }, result.responseBytes);
  if (!Array.isArray(result.events) || typeof result.more !== "boolean") throw new Error("History page remains unconfirmed");
  return { events: result.events as YorozuEvent[], more: result.more };
}
