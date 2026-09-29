// Progress (progress-v1): OpenClaw's typed tool hooks, forwarded as tool_started/tool_finished
// frames for the run that is working on a Yorozu message. The hooks only observe: they never
// block, rewrite or wait, and a failure here must never reach the tool call, so nothing throws.
// `before_tool_call` carries the requester channel; `after_tool_call` does not, so a finish is
// matched to its start by `toolCallId`.

const CHANNEL = "yorozu";

/**
 * @param {{ runFor: (sessionKey: string) => string | undefined, send: (frame: object) => boolean }} link
 * `runFor` gives the message id of the session's active Yorozu run, if any.
 */
export function createProgress({ runFor, send }) {
  const open = new Map(); // toolCallId -> messageId, until that call finishes
  const emit = (frame) => {
    try {
      send(frame);
    } catch {}
  };
  const text = (value) => {
    if (typeof value === "string") return value;
    try {
      return JSON.stringify(value) ?? "";
    } catch {
      return String(value);
    }
  };

  return {
    before(event, ctx) {
      const { toolCallId } = event;
      if (ctx?.requester?.channel !== CHANNEL || !toolCallId || !ctx.sessionKey) return;
      const messageId = runFor(ctx.sessionKey);
      if (!messageId) return;
      open.set(toolCallId, messageId);
      emit({ type: "tool_started", messageId, callId: toolCallId, name: event.toolName, args: event.params ?? {} });
    },
    after(event) {
      const messageId = open.get(event.toolCallId);
      if (!messageId) return;
      open.delete(event.toolCallId);
      emit({
        type: "tool_finished", messageId, callId: event.toolCallId, ok: !event.error,
        output: event.error ? String(event.error) : text(event.result),
      });
    },
  };
}
