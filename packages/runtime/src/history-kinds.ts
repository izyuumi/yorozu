import type { EventKind } from "@yorozu/shared";

/** Kinds that belong to a thread's history. Control traffic is not logged. */
export const LOGGED: ReadonlySet<EventKind> = new Set<EventKind>([
  "message",
  "turn_changes",
  "thread_rewound",
  "thought",
  "tool_call",
  "tool_result",
  "approval_card",
  "approval_answer",
  "approval_status",
  "stop_status",
  "admission_status",
  "question_card",
  "question_answer",
  "progress_card",
]);

