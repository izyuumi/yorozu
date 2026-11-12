import type { ActivityRecord, ActivityStorage } from "./activitystore.js";
import { applyTurn, cleanJobs, ENDED_LIMIT, holdFor, plan, tidy, type ActivityReport, type OwnerTurnChange, type WireJob } from "./liveactivity.js";

type Lifetime = { kind: "legacy" } | { kind: "seeded" | "ended"; record: ActivityRecord };
type Watch<Timer> = { lifetime: Lifetime; jobs: WireJob[]; sent: WireJob[]; turns: Record<string, string>; ended: string[]; replied?: string[]; capacityWarned?: boolean; pushedAt?: number; timer?: Timer };
type StoreHealth = { kind: "ready" } | { kind: "degraded" | "unavailable"; reason: string };
type Push = NonNullable<ReturnType<typeof plan>>;
const LOCKED = "another host holds the Live Activity state";
const tombstone = (record: ActivityRecord): ActivityRecord =>
  ({ device: record.device, activityId: record.activityId, requestedAtMs: record.requestedAtMs, kLast: record.kLast, terminal: true });
type Options<Timer> = {
  store: ActivityStorage;
  // The same paired-device list the relay allowlist announces; unlisted records are tombstoned at load.
  pairedDevices?: () => Promise<string[]>;
  liveTurn?: (convId: string) => Readonly<{ steps: number; startedAt: number }> | undefined;
  warn: (message: string) => void;
  send: (raw: string) => void;
  now: () => number;
  setTimer: (callback: () => void, delay: number) => Timer;
  clearTimer: (timer: Timer | undefined) => void;
};

export class ActivityWatch<Timer> {
  // Live Activities by device key, kept across sessions: the app is suspended while they matter.
  private activities = new Map<string, Watch<Timer>>();
  private records = new Map<string, ActivityRecord>();
  private queues = new Map<string, Promise<void>>();
  // One file holds all devices; serialize its writes as well as each device's reservations.
  private writes = Promise.resolve();
  private health: StoreHealth = { kind: "unavailable", reason: "Live Activity state not loaded" };
  private failures = 0;
  private options: Options<Timer>;
  private registered = false;
  private relayUp = false;
  private generation = 0;
  private lockBlocked = false;
  private restore?: Promise<void>;
  private stopped = false;
  private activityTimestamp = false;
  // A saved END whose send check failed; sent once at the next registration while its tombstone stands.
  private unsentEnd = new Map<string, { record: ActivityRecord; token: string; push: Push; k: number }>();
  // Forgets before load; applied to the loaded records instead of the empty pre-load map.
  private forgottenBeforeLoad = new Set<string>();
  private dropWarned = false;
  liveActivity = false;

  constructor(options: Options<Timer>) { this.options = options; }

  start(): Promise<void> {
    this.stopped = false;
    return this.restore ??= this.restoreState().finally(() => { this.restore = undefined; });
  }

  private async restoreState(): Promise<void> {
    try {
      if (!await this.options.store.acquire()) {
        this.health = { kind: "unavailable", reason: this.options.store.lockReason ?? LOCKED };
        this.lockBlocked = true;
        this.options.warn(this.health.reason);
        return;
      }
      if (this.stopped) { await this.options.store.release(); return; }
      this.lockBlocked = false;
      const loaded = await this.options.store.load();
      if (this.stopped) { await this.options.store.release(); return; }
      if (!loaded.ok) {
        this.health = { kind: "unavailable", reason: loaded.reason };
        this.options.warn(loaded.reason);
        return;
      }
      let paired: Set<string> | undefined;
      if (this.options.pairedDevices) {
        try { paired = new Set(await this.options.pairedDevices()); } catch {
          if (!this.stopped) this.options.warn("yorozu: Live Activity paired-device list unreadable; host writer stays off until the next relay registration");
          await this.options.store.release();
          if (this.stopped) return;
          this.health = { kind: "unavailable", reason: "Live Activity paired-device list unreadable" };
          // The next relayRegistered() retries the whole restore.
          this.lockBlocked = true;
          return;
        }
        if (this.stopped) { await this.options.store.release(); return; }
      }
      this.records = new Map(loaded.records.map((record) => [record.device, { ...record }]));
      for (const [device, watch] of this.activities) {
        if (watch.lifetime.kind !== "legacy") {
          this.options.clearTimer(watch.timer);
          this.activities.delete(device);
        }
      }
      let reconciled = false;
      for (const record of this.records.values()) {
        if (record.terminal || (!this.forgottenBeforeLoad.has(record.device) && (!paired || paired.has(record.device)))) continue;
        this.records.set(record.device, tombstone(record));
        reconciled = true;
      }
      for (const record of this.records.values()) {
        if (record.terminal || this.activities.get(record.device)?.lifetime.kind === "legacy") continue;
        const watch: Watch<Timer> = {
          lifetime: { kind: "seeded", record }, jobs: cleanJobs(record.rows!),
          sent: cleanJobs(record.sent!), turns: { ...record.bindings }, ended: [...(record.ended ?? [])],
          replied: [...(record.replied ?? [])],
        };
        const before = JSON.stringify(record);
        watch.jobs = watch.jobs.flatMap((job): WireJob[] => {
          if (job.kind !== "turn" || job.state !== "running") return [job];
          const convId = watch.turns[job.token];
          const live = convId && this.options.liveTurn?.(convId);
          if (live) return [{ token: job.token, kind: "turn", state: "running", steps: live.steps, startedAt: live.startedAt }];
          this.endTurn(watch, job.token);
          return [];
        });
        this.updateRecord(watch);
        reconciled ||= before !== JSON.stringify(record);
        this.activities.set(record.device, watch);
      }
      this.health = { kind: "ready" };
      this.dropWarned = false;
      this.forgottenBeforeLoad.clear();
      if (reconciled) {
        // A failure degrades through write(); the load itself stands.
        await this.write(() => this.options.store.save([...this.records.values()]), "(reconcile restored owners); nothing sent").catch(() => {});
      }
    } catch (error) {
      this.health = { kind: "unavailable", reason: `Live Activity state could not be loaded (${(error as NodeJS.ErrnoException)?.code ?? "UNKNOWN"})` };
      this.options.warn(this.health.reason);
    }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    this.relayDown();
    for (const watch of this.activities.values()) this.options.clearTimer(watch.timer);
    await this.restore;
    await Promise.all(this.queues.values());
    await this.writes;
    this.unsentEnd.clear();
    await this.options.store.release();
    this.health = { kind: "unavailable", reason: "Live Activity watch stopped" };
  }

  private canReserve(): boolean {
    return this.health.kind !== "unavailable" && this.registered && this.liveActivity && this.activityTimestamp;
  }

  get hostWriterReady(): boolean {
    return !this.stopped && this.health.kind === "ready" && this.registered && this.liveActivity && this.activityTimestamp;
  }

  relayConnecting({ liveActivity, activityTimestamp }: { liveActivity?: unknown; activityTimestamp?: unknown }): number {
    const generation = ++this.generation;
    this.relayUp = true;
    this.registered = false;
    this.liveActivity = liveActivity === true;
    this.activityTimestamp = activityTimestamp === true;
    return generation;
  }

  async relayRegistered(registration: number | { liveActivity?: unknown; activityTimestamp?: unknown }): Promise<void> {
    // Standalone callers can still register in one step; relay sockets announce devices between these steps.
    const generation = typeof registration === "number" ? registration : this.relayConnecting(registration);
    if (this.stopped || generation !== this.generation) return;
    if (this.restore) await this.restore;
    else if (this.health.kind === "unavailable" && this.lockBlocked) await this.start();
    if (this.stopped || generation !== this.generation) return;
    if (this.liveActivity && this.activityTimestamp) {
      for (const [device, { record, token, push, k }] of this.unsentEnd) {
        this.unsentEnd.delete(device);
        if (this.records.get(device) === record) this.sendPush(device, token, { ...push, timestamp: k });
      }
    }
    for (const [device, watch] of this.activities) {
      if (this.stopped || generation !== this.generation) return;
      if (watch.lifetime.kind === "seeded" && !watch.lifetime.record.terminal && watch.lifetime.record.token) {
        this.options.send(JSON.stringify({ type: "activityToken", device, token: watch.lifetime.record.token }));
      }
    }
    if (this.stopped || generation !== this.generation) return;
    this.registered = true;
    for (const [device, watch] of this.activities) {
      if (watch.lifetime.kind === "seeded" && !watch.lifetime.record.terminal) {
        this.push(device);
      }
    }
  }

  relayDown(): void {
    this.generation++;
    this.relayUp = false;
    this.registered = false;
    // Closing the relay leaves its last liveActivity gate and watches intact, as before.
  }

  private write(action: () => Promise<void>, failure: string): Promise<void> {
    const next = this.writes.then(action);
    this.writes = next.catch((error: unknown) => {
      const reason = `yorozu: Live Activity state save failed ${failure} (${(error as NodeJS.ErrnoException)?.code ?? "UNKNOWN"})`;
      this.health = { kind: "degraded", reason };
      this.failures++;
      for (const watch of this.activities.values()) {
        if (watch.lifetime.kind !== "seeded") continue;
        this.options.clearTimer(watch.timer);
        watch.timer = undefined;
      }
      this.options.warn(reason);
    });
    return next;
  }

  private persist(failure = "(record update after report/forget); nothing sent"): void {
    if (this.health.kind === "unavailable") return;
    void this.write(async () => {
      await this.options.store.save([...this.records.values()].map((record) => ({ ...record })));
      this.health = { kind: "ready" };
    },
      failure).catch(() => {});
  }

  private endTurn(watch: Watch<Timer>, token: string): void {
    if (!watch.ended.includes(token)) watch.ended.push(token);
    watch.turns = { ...watch.turns };
    delete watch.turns[token];
    watch.replied = watch.replied?.filter((replied) => replied !== token);
  }

  private finishTurn(watch: Watch<Timer>, job: WireJob, change: OwnerTurnChange["kind"], now: number): WireJob[] {
    const kind = watch.replied?.includes(job.token) ? "done" : change;
    this.endTurn(watch, job.token);
    return kind === "done" || kind === "failed" ? [{ ...job, state: kind, finishedAt: now }] : [];
  }

  private updateRecord(watch: Watch<Timer>): void {
    if (watch.lifetime.kind !== "seeded") return;
    const record = watch.lifetime.record;
    record.rows = watch.jobs;
    record.bindings = watch.turns;
    if (watch.ended.length) record.ended = [...watch.ended]; else delete record.ended;
    if (watch.replied?.length) record.replied = [...watch.replied]; else delete record.replied;
  }

  private admitReport(watch: Watch<Timer>, report: ActivityReport): void {
    const host = new Map(watch.jobs.filter((job) => job.kind === "turn").map((job) => [job.token, job]));
    const reported = cleanJobs(report.jobs);
    for (const token of host.keys()) {
      if (!reported.some((job) => job.kind === "turn" && job.token === token)) this.endTurn(watch, token);
    }
    const known = new Set([...host.keys(), ...watch.ended]);
    const turns: Record<string, string> = {};
    watch.jobs = reported.flatMap((job): WireJob[] => {
      if (job.kind !== "turn") return [job];
      const admitted = host.get(job.token);
      if (admitted) {
        if (admitted.state === "running") {
          const convId = watch.turns[job.token];
          if (!convId || !this.options.liveTurn?.(convId)) return this.finishTurn(watch, admitted, "gone", this.options.now());
          turns[job.token] = convId;
        }
        return [admitted];
      }
      const convId = report.turns[job.token];
      if (!convId || watch.ended.includes(job.token)) return [];
      if (known.size >= ENDED_LIMIT) {
        if (!watch.capacityWarned) {
          watch.capacityWarned = true;
          this.options.warn("yorozu: Live Activity turn capacity reached; unseen rows omitted");
        }
        return [];
      }
      known.add(job.token);
      const live = this.options.liveTurn?.(convId);
      if (!live) {
        this.endTurn(watch, job.token);
        return [];
      }
      turns[job.token] = convId;
      return [{ token: job.token, kind: "turn", state: "running", steps: live.steps, startedAt: live.startedAt }];
    });
    watch.turns = turns;
    this.updateRecord(watch);
  }

  forget(deviceKey: string, tellRelay: boolean): void {
    const watch = this.activities.get(deviceKey);
    this.options.clearTimer(watch?.timer);
    const record = this.records.get(deviceKey);
    this.activities.delete(deviceKey);
    this.unsentEnd.delete(deviceKey);
    // Before load the record map is not the file's; the load applies the mark.
    if (this.health.kind === "unavailable") this.forgottenBeforeLoad.add(deviceKey);
    // Revocation retains the redacted ordering tombstone.
    else if (record && !record.terminal) {
      this.records.set(deviceKey, tombstone(record));
      this.persist();
    }
    if (tellRelay) this.options.send(JSON.stringify({ type: "activityToken", device: deviceKey }));
  }

  tokenGone(deviceKey: string): void {
    const watch = this.activities.get(deviceKey);
    if (watch?.lifetime.kind === "legacy") return this.forget(deviceKey, false);
    const record = this.records.get(deviceKey);
    if (!record || record.terminal) return;
    delete record.token;
    this.options.clearTimer(watch?.timer);
    if (watch) watch.timer = undefined;
    this.persist("(clear expired activity token); nothing sent");
  }

  private push(deviceKey: string, fresh = true): void {
    const watch = this.activities.get(deviceKey);
    if (!watch || !this.relayUp || watch.lifetime.kind === "ended") return;
    if (watch.lifetime.kind === "seeded") {
      if (!this.canReserve() || !watch.lifetime.record.token || (!fresh && this.health.kind !== "ready")) return;
      const failures = this.failures;
      const previous = this.queues.get(deviceKey) ?? Promise.resolve();
      const next = previous.then(() => failures === this.failures ? this.reserve(deviceKey, watch) : undefined).catch(() => {});
      this.queues.set(deviceKey, next);
      void next.then(() => { if (this.queues.get(deviceKey) === next) this.queues.delete(deviceKey); });
      return;
    }
    const now = this.options.now();
    const next = plan(watch.sent, watch.jobs, now);
    if (!next || this.hold(deviceKey, watch, next.priority, now)) return;
    this.options.send(JSON.stringify({ type: "activityPush", device: deviceKey, ...next }));
    watch.sent = watch.jobs;
    watch.pushedAt = now;
    if (next.event === "end") this.activities.delete(deviceKey);
  }

  private hold(deviceKey: string, watch: Watch<Timer>, priority: 5 | 10, now: number): boolean {
    const hold = holdFor(priority, watch.pushedAt, now);
    if (hold > 0) {
      watch.timer ??= this.options.setTimer(() => {
        watch.timer = undefined;
        this.push(deviceKey, false);
      }, hold);
      return true;
    }
    this.options.clearTimer(watch.timer);
    watch.timer = undefined;
    return false;
  }

  private async reserve(deviceKey: string, watch: Watch<Timer>): Promise<void> {
    if (this.activities.get(deviceKey) !== watch || watch.lifetime.kind !== "seeded" || !this.canReserve()) return;
    const record = watch.lifetime.record;
    const token = record.token;
    if (record.terminal || !token) return;
    const now = this.options.now();
    const jobs = watch.jobs;
    const next = plan(watch.sent, jobs, now);
    if (!next || this.hold(deviceKey, watch, next.priority, now)) return;
    let saved = false;
    let endToken: string | undefined;
    let k = 0;
    const failures = this.failures;
    await this.write(async () => {
      if (failures !== this.failures || this.records.get(deviceKey) !== record || record.token !== token || !this.canReserve()) return;
      k = record.kLast + 1;
      if (!Number.isSafeInteger(k)) return;
      const reserved: ActivityRecord = next.event === "end"
        ? tombstone({ ...record, kLast: k })
        : { ...record, kLast: k, sent: jobs };
      // Burn before awaiting: a throw may happen after the file's rename.
      record.kLast = k;
      await this.options.store.save([...this.records.values()].map((row) => ({ ...(row === record ? reserved : row) })));
      // END goes to the activity's latest token, even one rotated during the save.
      endToken = record.token;
      record.terminal = reserved.terminal;
      if (record.terminal) {
        delete record.token;
        delete record.rows;
        delete record.bindings;
        delete record.sent;
        delete record.ended;
        delete record.replied;
      } else {
        record.sent = jobs;
      }
      this.health = { kind: "ready" };
      saved = true;
    }, "(reserve k for push); push not sent");
    if (!saved || this.records.get(deviceKey) !== record) return;
    // END belongs to the record generation, even when token rotation replaced its watch.
    const current = this.activities.get(deviceKey);
    if (record.terminal && current) {
      current.lifetime = { kind: "ended", record };
      current.jobs = [];
      current.sent = [];
      current.turns = {};
      current.ended = [];
      current.replied = [];
    }
    if (record.terminal) {
      if (!endToken) return;
      if (!this.hostWriterReady) {
        if (!this.stopped) this.unsentEnd.set(deviceKey, { record, token: endToken, push: next, k });
        return;
      }
      this.sendPush(deviceKey, endToken, { ...next, timestamp: k });
    } else {
      if (current !== watch || record.token !== token || !this.hostWriterReady) return;
      this.sendPush(deviceKey, token, { ...next, timestamp: k });
      watch.sent = jobs;
    }
    watch.pushedAt = now;
  }

  // The token right before the push binds it to this record, whatever the relay slot held (I1).
  private sendPush(deviceKey: string, token: string, push: Push & { timestamp: number }): void {
    this.options.send(JSON.stringify({ type: "activityToken", device: deviceKey, token }));
    this.options.send(JSON.stringify({ type: "activityPush", device: deviceKey, ...push }));
  }

  report(deviceKey: string, report: ActivityReport): void {
    if (this.stopped) return;
    // A Mode H report before load would be discarded by the swap; the app re-reports.
    if (this.health.kind === "unavailable" && report.activityId !== undefined && report.requestedAtMs !== undefined) {
      if (!this.dropWarned) this.options.warn("yorozu: Live Activity report dropped before state load");
      this.dropWarned = true;
      return;
    }
    const stored = this.records.get(deviceKey);
    if (!this.liveActivity && !stored) return;
    const old = this.activities.get(deviceKey);
    if (report.activityId !== undefined && report.requestedAtMs !== undefined) {
      // UUIDs compare case-insensitively; validation never trims or coerces wire fields.
      const activityId = report.activityId.toLowerCase();
      const same = stored?.activityId.toLowerCase() === activityId;
      if (stored && (same ? report.requestedAtMs !== stored.requestedAtMs : report.requestedAtMs <= stored.requestedAtMs)) {
        this.options.warn("yorozu: Live Activity report generation rejected");
        return;
      }
      if (same && stored.terminal) return;
      this.options.clearTimer(old?.timer);
      const seed = Math.ceil(report.requestedAtMs / 1000);
      const record: ActivityRecord = same ? stored : { device: deviceKey, activityId, requestedAtMs: report.requestedAtMs, kLast: seed, terminal: false };
      const seeded = same && old?.lifetime.kind === "seeded" ? old : undefined;
      const tokenChanged = record.token !== report.pushToken;
      // Rotation invalidates in-flight sends; pending retains content and only clears transport.
      const watch: Watch<Timer> = seeded
        ? (tokenChanged ? { ...seeded } : seeded)
        : { lifetime: { kind: "seeded", record }, jobs: cleanJobs(record.rows ?? []), sent: cleanJobs(record.sent ?? []), turns: { ...record.bindings }, ended: [...(record.ended ?? [])], replied: [...(record.replied ?? [])] };
      watch.timer = undefined;
      if (!seeded || report.pushToken) this.admitReport(watch, report);
      record.sent ??= watch.jobs;
      if (!seeded) watch.sent = record.sent;
      if (report.pushToken) record.kLast = Math.max(record.kLast, seed);
      if (report.pushToken) record.token = report.pushToken;
      else delete record.token;
      // An unsent END belongs to the tombstone this record replaces.
      if (record !== stored) this.unsentEnd.delete(deviceKey);
      this.records.set(deviceKey, record);
      this.activities.set(deviceKey, watch);
      this.persist();
      this.options.send(JSON.stringify({ type: "activityToken", device: deviceKey, token: report.pushToken }));
      this.push(deviceKey);
      return;
    }
    // Legacy reports retain their original token clearing and snapshot behavior.
    if (!this.liveActivity) return;
    if (!report.pushToken) return this.forget(deviceKey, true);
    this.forget(deviceKey, false);
    const jobs = cleanJobs(report.jobs);
    this.activities.set(deviceKey, { lifetime: { kind: "legacy" }, jobs, sent: jobs, turns: { ...report.turns }, ended: [], ...(old?.pushedAt !== undefined ? { pushedAt: old.pushedAt } : {}) });
    this.options.send(JSON.stringify({ type: "activityToken", device: deviceKey, token: report.pushToken }));
  }

  turn(convId: string, change: OwnerTurnChange): void {
    const now = this.options.now();
    for (const [deviceKey, watch] of this.activities) {
      if (watch.lifetime.kind === "ended") continue;
      if (!Object.values(watch.turns).includes(convId)) continue;
      if (watch.lifetime.kind === "seeded") {
        const live = this.options.liveTurn?.(convId);
        watch.jobs = tidy(watch.jobs.flatMap((job): WireJob[] => {
          if (job.kind !== "turn" || job.state !== "running" || watch.turns[job.token] !== convId) return [job];
          if (change.kind === "done" && !watch.replied?.includes(job.token)) (watch.replied ??= []).push(job.token);
          if (live) return [{ token: job.token, kind: "turn", state: "running", steps: live.steps, startedAt: live.startedAt }];
          return this.finishTurn(watch, job, change.kind, now);
        }), now);
        this.updateRecord(watch);
        if (change.kind !== "step" || !live) this.persist("(record update before reserve k for push); nothing sent");
      } else {
        if (change.kind === "settled") continue;
        watch.jobs = applyTurn(watch.jobs, watch.turns, convId, change, now);
      }
      this.push(deviceKey);
    }
  }
}
