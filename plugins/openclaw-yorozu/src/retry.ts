import type { Message } from "./envelope.js";
import { yorozuRuntime } from "./runtime.js";

type Parked = { message: Message; attempt: number; due: number };

const store = () =>
  yorozuRuntime.getRuntime().state.openKeyedStore<Parked>({ namespace: "retry", retention: "retained" });

const DELAYS_MS = [5_000, 15_000, 30_000, 60_000, 120_000];
const TICK_MS = 5_000;

export function isTemporary(error: unknown): boolean {
  if ((error as { admissionBlocked?: unknown } | undefined)?.admissionBlocked === true) return true;
  return /replacement is in progress|overloaded|rate.?limit|\b(429|503|529)\b|temporarily unavailable|ECONNRESET|ETIMEDOUT/i.test(
    String(error),
  );
}

export async function park(message: Message, attempt: number): Promise<boolean> {
  const delay = DELAYS_MS[attempt];
  if (delay === undefined) return false;
  await store().register(message.messageId, { message, attempt: attempt + 1, due: Date.now() + delay });
  return true;
}

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
