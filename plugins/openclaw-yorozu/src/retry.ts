/**
 * A run that fails for a moment (a plugin reload draining this generation, an overloaded or rate-limited model) runs
 * again instead of showing its error (owner, 2026-10-23). The message waits in the keyed state store (namespace
 * `retry`), so a reload that replaced this generation finds it when its account starts. Only before any reply or tool:
 * core releases its inbound dedupe claim for a failure that is safe to replay, and keeps it (dropping the retry) for
 * one that is not.
 */
import type { Message } from "./envelope.js";
import { yorozuRuntime } from "./runtime.js";

type Parked = { message: Message; attempt: number; due: number };

const store = () =>
  yorozuRuntime.getRuntime().state.openKeyedStore<Parked>({ namespace: "retry", retention: "retained" });

/** The wait before each retry; past the last, the failure is shown. About four minutes in all, past a 60 s drain. */
const DELAYS_MS = [5_000, 15_000, 30_000, 60_000, 120_000];
const TICK_MS = 5_000;

export function isTemporary(error: unknown): boolean {
  // Core's `PreparedModelRuntimeOwnerNotPublishedError` during a plugin reload ("Retry after the plugin reload completes").
  if ((error as { admissionBlocked?: unknown } | undefined)?.admissionBlocked === true) return true;
  return /replacement is in progress|overloaded|rate.?limit|\b(429|503|529)\b|temporarily unavailable|ECONNRESET|ETIMEDOUT/i.test(
    String(error),
  );
}

/** Parks `message` for its next attempt; false once it has had them all. */
export async function park(message: Message, attempt: number): Promise<boolean> {
  const delay = DELAYS_MS[attempt];
  if (delay === undefined) return false;
  await store().register(message.messageId, { message, attempt: attempt + 1, due: Date.now() + delay });
  return true;
}

/** Runs each parked message when it is due, until `signal` aborts; what an earlier generation parked runs here. */
export function runParked(signal: AbortSignal, run: (message: Message, attempt: number) => void): void {
  let busy = false;
  const tick = async () => {
    if (busy || signal.aborted) return;
    busy = true;
    try {
      const now = Date.now();
      for (const { value } of await store().entries()) {
        if (value.due > now) continue;
        await store().delete(value.message.messageId);
        run(value.message, value.attempt);
      }
    } finally {
      busy = false;
    }
  };
  const timer = setInterval(() => void tick().catch(() => {}), TICK_MS);
  signal.addEventListener("abort", () => clearInterval(timer), { once: true });
}
