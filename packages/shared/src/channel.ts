/**
 * What travels inside a live-channel box: the event, and a sequence number that makes a
 * replayed or reflected box recognisable. Mirrored by
 * packages/shared-swift/Sources/YorozuShared/Channel.swift.
 */
import type { YorozuEvent } from "./events.js";

export interface ChannelEnvelope {
  /** Per (peer, direction), starting at 1 and only ever going up. */
  seq: number;
  event: YorozuEvent;
}

/**
 * The largest seq either end will accept: every integer up to it is exact in a JS number and
 * fits a Swift `Int`, so both sides agree on the whole domain. Nothing sends this many boxes;
 * a seq above it is a malformed frame, not a fresh one.
 */
export const MAX_SEQ = Number.MAX_SAFE_INTEGER;

/** True for a number a counter can hold: an integer from 0 to `MAX_SEQ`. */
export const isSeq = (value: unknown): value is number =>
  Number.isSafeInteger(value) && (value as number) >= 0;

export const encodeEnvelope = (seq: number, event: YorozuEvent): Uint8Array =>
  new Uint8Array(Buffer.from(JSON.stringify({ seq, event } satisfies ChannelEnvelope)));

/**
 * Throws on anything but a well-formed envelope: a box that opened but says nothing usable.
 * The event is checked for shape only — the fields every event has — so a peer's box that
 * decrypts is still not trusted to be an event; what its `kind` and `data` mean is for the
 * event handling to judge.
 */
export function decodeEnvelope(plain: Uint8Array): ChannelEnvelope {
  const parsed = JSON.parse(Buffer.from(plain).toString()) as Partial<ChannelEnvelope> | null;
  if (typeof parsed !== "object" || parsed === null) throw new Error("envelope is not an object");
  if (!isSeq(parsed.seq) || parsed.seq < 1) throw new Error("envelope seq is not a positive integer");
  const event = parsed.event as Partial<YorozuEvent> | null | undefined;
  if (typeof event !== "object" || event === null) throw new Error("envelope carries no event");
  if (
    typeof event.id !== "string" ||
    typeof event.threadId !== "string" ||
    typeof event.ts !== "number" ||
    typeof event.agentId !== "string" ||
    typeof event.kind !== "string" ||
    typeof event.data !== "object" ||
    event.data === null
  ) {
    throw new Error("envelope event is not shaped like one");
  }
  return { seq: parsed.seq, event: event as YorozuEvent };
}

/**
 * A box is fresh only if it is newer than the last one taken from that peer. Both ends keep
 * that number, and the one they last sealed with, across a restart: a `send` that started over
 * would be rejected as a replay by the other end, and a `recv` that started over would accept one.
 */
export const acceptsSeq = (lastAccepted: number, seq: number): boolean => seq > lastAccepted;
