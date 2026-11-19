import type { Keyed } from "./cards.js";
import type { Message } from "./envelope.js";

export type RunState = "accepted" | "handed" | "started" | "parked" | "settled";
export type RunRecord = { convId: string; at: number; boot: string; state: RunState };
export type Store<T> = Keyed<T> & { entries(): Promise<{ key: string; value: T }[]> };
export type LedgerDeps = {
  runs: () => Store<RunRecord>;
  now: () => number;
  bootId: string;
  log: { info(line: string): void; warn(line: string): void };
  inTranscript: (convId: string, messageId: string) => "found" | "missing" | "unreadable";
};
export type Ledger = {
  load(): Promise<"loaded" | "degraded">;
  counts(): string[];
  claim(message: Message): "fresh" | "duplicate";
  handing(messageId: string, convId: string): Promise<void>;
  runStarted(messageId: string, attempt: number, afterReturn: boolean): void;
  dispatchReturned(messageId: string, deferred: unknown, started: boolean): void;
  turnEnded(messageId: string, convId: string, outcome: { parked: boolean; queued: boolean }): void;
  idle(): Promise<void>;
};

const MAX_AGE_MS = 24 * 60 * 60 * 1000;
const MAX_ENTRIES = 10_000;

export function createLedger({ runs, now, bootId, log, inTranscript }: LedgerDeps): Ledger {
  const records = new Map<string, RunRecord>();
  const pending = new Map<string, Promise<void>>();
  let loading: ReturnType<Ledger["load"]> | undefined;
  let degraded = false;
  let countLines: string[] = [];

  function persist(messageId: string, operation: () => Promise<unknown>): Promise<void> {
    const write = async () => {
      try {
        await operation();
      } catch (error) {
        log.warn(`yorozu: run ledger write failed: ${String(error)}`);
      }
    };
    const previous = pending.get(messageId);
    const next = previous ? previous.then(write) : write();
    pending.set(messageId, next);
    void next.then(() => {
      if (pending.get(messageId) === next) pending.delete(messageId);
    });
    return next;
  }

  function write(messageId: string, convId: string, state: RunState, at = now()): Promise<void> {
    const value = { convId, at: records.get(messageId)?.at ?? at, boot: bootId, state };
    records.set(messageId, value);
    return persist(messageId, () => runs().register(messageId, value));
  }

  function trim(): void {
    for (const id of records.keys()) {
      if (records.size <= MAX_ENTRIES) break;
      records.delete(id);
    }
  }

  function startupCounts(): string[] {
    const byBoot = new Map<string, Record<Exclude<RunState, "settled">, number>>();
    for (const { boot, state } of records.values()) {
      if (boot === bootId || state === "settled") continue;
      const counts = byBoot.get(boot) ?? { accepted: 0, handed: 0, started: 0, parked: 0 };
      counts[state]++;
      byBoot.set(boot, counts);
    }
    return Array.from(byBoot, ([boot, { accepted, handed, started, parked }]) =>
      `yorozu: restart ledger ${boot}: not handed ${accepted}, handed not started ${handed}, started ${started}, parked ${parked}`);
  }

  async function load(): ReturnType<Ledger["load"]> {
    let rows: Awaited<ReturnType<Store<RunRecord>["entries"]>>;
    try {
      rows = await runs().entries();
    } catch (error) {
      degraded = true;
      log.warn(`yorozu: run ledger unavailable: ${String(error)}`);
      return "degraded";
    }
    const at = now();
    const expired: Promise<void>[] = [];
    for (const { key, value } of rows.sort((a, b) => a.value.at - b.value.at)) {
      if (value.at < at - MAX_AGE_MS) expired.push(persist(key, () => runs().delete(key)));
      else records.set(key, value);
    }
    trim();
    countLines = startupCounts();
    await Promise.all(expired);
    return "loaded";
  }

  function claim(message: Message): "fresh" | "duplicate" {
    const { messageId, convId } = message;
    const at = now();
    for (const [id, value] of records) {
      if (value.at < at - MAX_AGE_MS) records.delete(id);
    }
    trim();
    let previous = records.get(messageId);
    if (!previous && degraded) {
      const result = inTranscript(convId, messageId);
      if (result === "found") {
        previous = { convId, at, boot: bootId, state: "settled" };
        records.set(messageId, previous);
        trim();
      } else if (result === "unreadable") {
        log.warn("yorozu: run ledger transcript check failed: unreadable");
      }
    }
    if (previous) {
      log.info(`yorozu: duplicate message skipped ${messageId} ${previous.state} boot ${previous.boot === bootId ? "same" : "earlier"}`);
      return "duplicate";
    }
    void write(messageId, convId, "accepted", at);
    trim();
    return "fresh";
  }

  return {
    load: () => loading ??= load(),
    counts: () => [...countLines],
    claim,
    handing: (messageId, convId) => write(messageId, convId, "handed"),
    runStarted(messageId, attempt, afterReturn) {
      log.info(`yorozu: run started ${messageId} attempt ${attempt} boot ${bootId}`);
      if (afterReturn) log.info(`yorozu: follow-up started after dispatch ${messageId}`);
      const record = records.get(messageId);
      if (record?.state === "handed") void write(messageId, record.convId, "started");
    },
    dispatchReturned(messageId, deferred, started) {
      const value = deferred === "steer" || deferred === "followup" ? deferred
        : deferred == null ? "none" : `other:${String(deferred)}`;
      log.info(`yorozu: dispatch returned ${messageId} deferred ${value} started ${started}`);
    },
    turnEnded(messageId, convId, { parked, queued }) {
      if (parked || !queued) void write(messageId, convId, parked ? "parked" : "settled");
    },
    async idle() {
      while (pending.size) await Promise.all(pending.values());
    },
  };
}
