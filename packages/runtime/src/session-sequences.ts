import { syncHostRequest } from "./rust-sync.js";
import type { ChannelSeqs } from "./serve.js";
/** Rust owns durable sequence currency; Node retains reservation and replay policy for now. */
export class SessionSequences {
  readonly hasProjection: boolean;
  constructor(private readonly dir: string) {
    const result = this.request({ op: "seq_open" });
    if (result.stored !== true || typeof result.hasProjection !== "boolean") throw this.unavailable();
    this.hasProjection = result.hasProjection;
  }
  private unavailable(): Error {
    return new Error("Yorozu couldn't confirm its connection counters. Restore the saved state or check storage access, then try again.");
  }
  private request(data: Record<string, unknown>): Record<string, unknown> {
    try { return syncHostRequest(this.dir, data); }
    catch { throw this.unavailable(); }
  }
  get(pub: string): { sendSeq: number; recvSeq: number } {
    const result = this.request({ op: "seq_get", pub });
    if (![result.sendSeq, result.recvSeq].every((value) => typeof value === "number" && Number.isSafeInteger(value) && value >= 0)) throw this.unavailable();
    return result as { sendSeq: number; recvSeq: number };
  }
  save(records: ChannelSeqs): void {
    if (this.request({ op: "seq_save", records }).stored !== true) throw this.unavailable();
  }
}
