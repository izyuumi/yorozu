import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import type { OpenClawConfig } from "openclaw/plugin-sdk/channel-core";
import { findUserMessage } from "./history.js";
import { createLedger, type Ledger, type RunRecord } from "./ledger.js";
import { yorozuRuntime } from "./runtime.js";

type LedgerContext = { cfg: OpenClawConfig; agent: string; log?: ChannelGatewayContext["log"] };

const counted = Symbol.for("yorozu.runLedger.counted");
const processState = globalThis as typeof globalThis & { [counted]?: boolean };
let ledger: Ledger | undefined;
let bound: LedgerContext;

export async function openLedger(ctx: LedgerContext): Promise<Ledger> {
  bound = ctx;
  const current = ledger ??= createLedger({
    runs: () => yorozuRuntime.getRuntime().state.openKeyedStore<RunRecord>({
      namespace: "runs", maxEntries: 10_000, overflowPolicy: "evict-oldest",
    }),
    now: Date.now,
    bootId: `${process.pid}:${Math.round(performance.timeOrigin)}`,
    log: { info: (line) => bound.log?.info?.(line), warn: (line) => bound.log?.warn?.(line) },
    inTranscript: (convId, messageId) => findUserMessage(bound.cfg, bound.agent, convId, messageId),
  });
  await current.load();
  if (!processState[counted]) {
    processState[counted] = true;
    for (const line of current.counts()) bound.log?.info?.(line);
  }
  return current;
}

export function currentLedger(): Ledger | undefined {
  return ledger;
}
