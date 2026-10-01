/** Rust owns ephemeral plaintext job supersession, rotation, pacing and bounded claims. */
import type { YorozuEvent } from "@yorozu/shared";
import { syncHostRequest } from "./rust-sync.js";
export class CatchupQueue {
  private responseBytes = 1024 * 1024;
  constructor(private readonly dir: string) {}
  replace(pub: string, generation: string, connection: string, events: YorozuEvent[]): void {
    this.cancel(pub);
    // The worker parses/re-encodes Rust results; JavaScript numeric notation can be larger.
    const encodedBytes = events.reduce((largest, event) => Math.max(largest, Buffer.byteLength(JSON.stringify(event)) + 4096), 1024 * 1024);
    const proof = syncHostRequest(this.dir, { op: "catchup_replace", pub, generation, connection, events });
    if (proof.stored !== true || typeof proof.responseBytes !== "number") throw new Error("Catch-up remains unconfirmed");
    this.responseBytes = Math.max(this.responseBytes, proof.responseBytes, encodedBytes);
  }
  cancel(pub: string): void { if (syncHostRequest(this.dir, { op: "catchup_cancel", pub }).stored !== true) throw new Error("Catch-up remains unconfirmed"); }
  clear(): void {
    if (syncHostRequest(this.dir, { op: "catchup_clear" }).stored !== true) throw new Error("Catch-up remains unconfirmed");
    this.responseBytes = 1024 * 1024;
  }
  next(connection: string, eligible: { pub: string; generation: string }[], writable: boolean, bufferedBytes: number):
    { remaining: boolean; waitMs: number; event?: YorozuEvent; done?: boolean; pub?: string; generation?: string; claim?: string } {
    const result = syncHostRequest(this.dir, { op: "catchup_next", connection, eligible, writable, bufferedBytes }, this.responseBytes);
    if (typeof result.remaining !== "boolean" || (result.event &&
      (typeof result.pub !== "string" || typeof result.generation !== "string" || typeof result.claim !== "string" || typeof result.done !== "boolean"))) throw new Error("Catch-up remains unconfirmed");
    return { ...result, remaining: result.remaining, waitMs: typeof result.waitMs === "number" ? result.waitMs : 0 } as ReturnType<CatchupQueue["next"]>;
  }
  finish(claim: string, pub: string, generation: string, sent: boolean): { remaining: boolean; waitMs: number } {
    const proof = syncHostRequest(this.dir, { op: "catchup_finish", claim, pub, generation, sent });
    if (proof.stored !== true || typeof proof.remaining !== "boolean" || typeof proof.waitMs !== "number") throw new Error("Catch-up remains unconfirmed");
    return { remaining: proof.remaining, waitMs: proof.waitMs };
  }
}
