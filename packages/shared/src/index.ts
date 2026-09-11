/** Event kinds carried over the relay. See docs/spec-v1.html section 3. */
export type EventKind = "message" | "thought" | "tool_call" | "tool_result";

export interface YorozuEvent {
  id: string;
  threadId: string;
  kind: EventKind;
}
