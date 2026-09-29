import { createHash } from "node:crypto";

// JSON bytes, before the two base64 layers and sealed-frame overhead on the relay.
const MAX_REPLY_BYTES = 256 * 1024;
const replyBytes = (text) => Buffer.byteLength(JSON.stringify(text));

// Preserve exact text and surrogate pairs when an aggregate exceeds one relay-safe message.
function replyChunks(text) {
  if (replyBytes(text) <= MAX_REPLY_BYTES) return [text];
  const chunks = [];
  let chunk = "";
  let bytes = 2; // JSON quotes
  for (const character of text) {
    const size = replyBytes(character) - 2;
    if (bytes + size > MAX_REPLY_BYTES) {
      chunks.push(chunk);
      chunk = "";
      bytes = 2;
    }
    chunk += character;
    bytes += size;
  }
  if (chunk) chunks.push(chunk);
  return chunks;
}

// Hands one Yorozu message to OpenClaw with an abort signal, mirroring the SDK's
// dispatchInboundDirectDm (which cannot pass reply options). `sdk` is injected so tests can fake it.

/**
 * @param {{ resolveRoute: Function, buildContext: Function, createReplyPipeline: Function, dispatchTurn: Function, attachments: { save: Function, release: Function } }} sdk
 * @returns {(params: { cfg: object, accountId: string, message: object, deliver: Function, preview?: Function, log?: object }, signal: AbortSignal, begin: (sessionKey?: string) => void) => Promise<"completed" | "failed" | undefined>}
 */
export const createInboundDispatcher = (sdk) => async ({ cfg, accountId, message, deliver, preview, log }, signal, begin) => {
  const peer = { kind: "direct", id: message.threadId };
  // Refused here (e.g. no binding with several agents): throws before `begin`, so it is resent.
  const { route, buildEnvelope } = sdk.resolveRoute({ cfg, channel: "yorozu", accountId, peer });
  const label = `Yorozu ${message.threadId}`;
  // A failed save throws before `begin`: the message stays unacked and is resent.
  const media = await sdk.attachments.save(message);
  const ctxPayload = await sdk.buildContext({
    channel: "yorozu",
    accountId: route.accountId ?? accountId,
    messageId: message.id,
    messageIdFull: message.id,
    timestamp: message.ts,
    from: `yorozu:${message.threadId}`,
    sender: { id: "owner", name: label },
    conversation: { kind: "direct", id: peer.id, routePeer: peer, label },
    route: { agentId: route.agentId, accountId: route.accountId, routeSessionKey: route.sessionKey, dispatchSessionKey: route.sessionKey },
    reply: { to: "yorozu:openclaw", originatingTo: `yorozu:${message.threadId}` },
    message: {
      body: buildEnvelope({ channel: "Yorozu", from: label, body: message.text, timestamp: message.ts }),
      bodyForAgent: message.text,
      rawBody: message.text,
      commandBody: message.text,
    },
    ...(media.length ? { media } : {}),
    access: { commands: { authorized: true } },
    channelIngress: "unsupported",
    extra: { NativeDirectUserId: peer.id, OriginatingChannel: "yorozu" },
  });
  const { onModelSelected, ...replyPipeline } = sdk.createReplyPipeline({
    cfg, agentId: route.agentId, channel: "yorozu", accountId: route.accountId ?? accountId,
  });
  let outcome; // undefined until OpenClaw reports one
  sdk.attachments.release(message);
  begin(route.sessionKey);
  // One native answer per run. SDK final payloads remain authoritative: previews are
  // snapshots, not delivery receipts, and can be revised or suppressed by OpenClaw.
  const id = `openclaw:${createHash("sha256").update(message.threadId).update("\0").update(message.id).digest("hex")}:reply`;
  const parts = [];
  const finalParts = [];
  let current = "";
  let sealed = false;
  let timer;
  let lastPreviewAt = 0;
  const snapshot = () => [...parts, current].filter(Boolean).join("\n\n");
  const flush = () => {
    clearTimeout(timer);
    timer = undefined;
    if (sealed || signal.aborted) return false;
    const text = snapshot();
    if (!text || replyBytes(text) > MAX_REPLY_BYTES) return false;
    lastPreviewAt = Date.now();
    try { return preview?.({ id, messageId: message.id, threadId: message.threadId, text }) ?? false; }
    catch (error) {
      log?.error?.(`yorozu preview failed: ${String(error)}`);
      return false;
    }
  };
  const partial = (payload) => {
    if (sealed || signal.aborted || !preview) return false;
    if (typeof payload.text === "string") current = payload.text;
    else if (typeof payload.delta === "string") current = payload.replace ? payload.delta : current + payload.delta;
    else return false;
    // Leading snapshot immediately; at most one pending snapshot for a token burst.
    const delay = 100 - (Date.now() - lastPreviewAt);
    if (delay <= 0) return flush();
    timer ??= setTimeout(flush, delay);
    return false; // Not operator-visible until flush accepts it.
  };
  let result;
  let error;
  let threw = false;
  try {
    result = await sdk.dispatchTurn({
      cfg,
      channel: "yorozu",
      accountId: route.accountId ?? accountId,
      route: { agentId: route.agentId, sessionKey: route.sessionKey },
      ctxPayload,
      record: { onRecordError: (error) => log?.error?.(`yorozu inbound record failed: ${String(error)}`) },
      delivery: {
        deliver: preview ? async (payload) => {
          if (typeof payload?.text === "string" && payload.text.trim()) finalParts.push(payload.text);
        } : deliver,
        onError: (error) => {
          outcome = "failed";
          log?.error?.(`yorozu inbound dispatch failed: ${String(error)}`);
        },
      },
      replyPipeline,
      replyOptions: {
        onModelSelected,
        abortSignal: signal,
        ...(preview ? {
          // Official SDK preview mode avoids competing completed block deliveries.
          disableBlockStreaming: true,
          preserveProgressCallbackStartOrder: true,
          onPartialReply: partial,
          onAssistantMessageStart: () => {
            if (sealed) return false;
            if (current) parts.push(current);
            current = "";
            return false;
          },
        } : {}),
        onAgentRunTerminalOutcome: (terminal) => {
          if (outcome !== "failed") outcome = terminal;
        },
      },
    });
  } catch (caught) {
    error = caught;
    threw = true;
  } finally {
    sealed = true;
    clearTimeout(timer);
  }
  if (preview) {
    const interrupted = signal.aborted && outcome !== "completed";
    const failed = !interrupted && Boolean(threw || outcome === "failed" || result?.dispatched === false);
    // A deliberate successful NO_REPLY must clear the draft, never promote suppressed text.
    const text = finalParts.length ? finalParts.join("\n\n") : interrupted || failed ? snapshot() : "";
    if (text || snapshot()) {
      const chunks = replyChunks(text);
      for (let index = 0; index < chunks.length; index++) await deliver({ text: chunks[index] }, {
        id: index === 0 ? id : `${id}:${index}`, messageId: message.id, interrupted, failed,
      });
    }
  }
  if (threw) throw error;
  return result?.dispatched === false ? "failed" : outcome;
};
