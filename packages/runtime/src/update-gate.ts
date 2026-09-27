import type { UpdateStatusData } from "@yorozu/shared";

export class UpdateGate {
  status: UpdateStatusData = { phase: "none" };
  private lastPoll = 0;
  private forced = false;
  private drainDeadline = 0;
  private pending: { updateId: string; since: number } | undefined;

  constructor(private postponedUntil = 0, pending?: { updateId: string; since: number }) {
    this.pending = pending;
  }

  queue(updateId: string, version: string, now = Date.now()): void {
    if (this.status.updateId === updateId) return;
    const changed = this.pending?.updateId !== updateId;
    if (changed) this.pending = { updateId, since: now };
    this.drainDeadline = 0;
    this.forced = false;
    this.status = { phase: "waiting", updateId, version };
    this.lastPoll = 0;
  }

  activity(): void {
    if (this.status.phase === "none" || this.status.phase === "installing" || this.draining) return;
    this.status = { ...this.status, phase: "waiting", deadline: undefined };
  }

  postpone(now: number): number {
    if (this.status.phase === "none" || this.status.phase === "installing") return this.postponedUntil;
    this.postponedUntil = now + 3_600_000;
    this.forced = false;
    this.drainDeadline = 0;
    this.status = { ...this.status, phase: "postponed", deadline: undefined, postponedUntil: this.postponedUntil };
    return this.postponedUntil;
  }

  installNow(): void {
    if (this.status.phase !== "none" && this.status.phase !== "installing") this.forced = true;
  }

  get draining(): boolean { return this.drainDeadline > 0 && this.status.phase !== "installing"; }

  poll(activeThreads: number | null, now: number): UpdateStatusData {
    if (this.status.phase === "none" || this.status.phase === "installing") return this.status;
    if (now - this.lastPoll > 3_000 || now < this.lastPoll) this.activity();
    this.lastPoll = now;
    const base = { updateId: this.status.updateId, version: this.status.version };
    if (activeThreads === null) this.status = this.drainDeadline && now >= this.drainDeadline
      ? { ...base, phase: "installing", deadline: this.drainDeadline }
      : { ...base, phase: "unknown", ...(this.drainDeadline ? { deadline: this.drainDeadline } : {}) };
    else if (!this.forced && this.postponedUntil > now) {
      this.status = { ...base, phase: "postponed", activeThreads, postponedUntil: this.postponedUntil };
    } else if (activeThreads > 0 && (this.forced || now >= (this.pending?.since ?? now) + 86_400_000 || this.drainDeadline > 0)) {
      if (!this.drainDeadline) this.drainDeadline = now + 300_000;
      const deadline = this.drainDeadline;
      this.status = { ...base, phase: now >= deadline ? "installing" : "draining", activeThreads, deadline };
    } else if (activeThreads > 0) this.status = { ...base, phase: "waiting", activeThreads };
    else if (this.drainDeadline || this.forced) this.status = { ...base, phase: "installing", activeThreads: 0 };
    else {
      const deadline = this.status.phase === "countdown" ? this.status.deadline! : now + 10_000;
      this.status = { ...base, phase: now >= deadline ? "installing" : "countdown", activeThreads, deadline };
    }
    return this.status;
  }

  cancel(): void {
    this.status = { phase: "none" };
    this.lastPoll = 0;
    this.forced = false;
    this.drainDeadline = 0;
  }
}
