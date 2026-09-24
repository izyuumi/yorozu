import type { UpdateStatusData } from "@yorozu/shared";

export class UpdateGate {
  status: UpdateStatusData = { phase: "none" };
  private lastPoll = 0;

  constructor(private postponedUntil = 0) {}

  queue(updateId: string, version: string): void {
    if (this.status.updateId === updateId) return;
    this.status = { phase: "waiting", updateId, version };
    this.lastPoll = 0;
  }

  activity(): void {
    if (this.status.phase === "none" || this.status.phase === "installing") return;
    this.status = { ...this.status, phase: "waiting", deadline: undefined };
  }

  postpone(now: number): number {
    if (this.status.phase === "none" || this.status.phase === "installing") return this.postponedUntil;
    this.postponedUntil = now + 3_600_000;
    this.status = { ...this.status, phase: "postponed", deadline: undefined, postponedUntil: this.postponedUntil };
    return this.postponedUntil;
  }

  poll(activeThreads: number | null, now: number): UpdateStatusData {
    if (this.status.phase === "none" || this.status.phase === "installing") return this.status;
    if (now - this.lastPoll > 3_000 || now < this.lastPoll) this.activity();
    this.lastPoll = now;
    const base = { updateId: this.status.updateId, version: this.status.version };
    if (activeThreads === null) this.status = { ...base, phase: "unknown" };
    else if (this.postponedUntil > now) {
      this.status = { ...base, phase: "postponed", activeThreads, postponedUntil: this.postponedUntil };
    } else if (activeThreads > 0) this.status = { ...base, phase: "waiting", activeThreads };
    else {
      const deadline = this.status.phase === "countdown" ? this.status.deadline! : now + 10_000;
      this.status = { ...base, phase: now >= deadline ? "installing" : "countdown", activeThreads, deadline };
    }
    return this.status;
  }

  cancel(): void {
    this.status = { phase: "none" };
    this.lastPoll = 0;
  }
}
