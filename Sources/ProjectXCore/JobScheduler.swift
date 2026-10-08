import Foundation

/// Fires each job on its cron schedule (#319). Holds the last valid job set and sleeps until the earliest next fire.
/// It re-arms on a new set and on `rearm(clockChanged:)`, which the app calls after wake, a clock change and a time-zone
/// change (Core stays free of AppKit). A slot reached more than 60 s late is skipped silently and the next one counts
/// from now (open question 8). Overlap is the Engine's rule (`runJob` skips with a note). Paused and retired jobs never
/// fire; a one-shot that started is retired in `jobs.toml`. Offline mode needs nothing here: `runJob` runs nothing there.
public actor JobScheduler {
    private let engine: Engine
    private let file: URL
    private var specs: [JobSpec] = []
    /// Per job: the last slot fired or skipped; slots at or before it never fire. A job that is new, or whose schedule,
    /// pause or retirement changed, starts from the moment it changed.
    private var lastSlot: [String:Date] = [:]
    private var armedAs: [String:[String]] = [:]
    private var next: [String:Date] = [:]
    /// One-shots that started but `jobs.toml` does not yet show as retired; kept retired here and written again.
    private var retiring = Set<String>()
    private var loop: Task<Void,Never>?
    private var stopped = false

    public init(engine: Engine, file: URL) { self.engine = engine; self.file = file }

    /// Job id → next fire, for the Jobs list (`Engine.jobStatus(nextRuns:)`); paused and retired jobs have none.
    public var nextRuns: [String:Date] { next }

    /// A new valid set from `jobs.toml`.
    public func update(_ jobs: [JobSpec]) {
        let now = Date()
        retiring = retiring.filter { id in jobs.contains { $0.id == id && !$0.retired } }
        specs = jobs.map { var s = $0; if retiring.contains(s.id) { s.retired = true }; return s }
        if !retiring.isEmpty { writeRetired() }
        var armed: [String:[String]] = [:]
        for s in specs {
            let key = s.schedule + [s.paused ? "paused" : "", s.retired ? "retired" : ""]
            armed[s.id] = key
            if armedAs[s.id] != key { lastSlot[s.id] = now }
        }
        armedAs = armed; lastSlot = lastSlot.filter { armed[$0.key] != nil }
        rearm(at: now)
    }

    /// After wake, a clock change (`clockChanged`: a slot "fired" in a future the clock left counts from now) or a
    /// time-zone change (the caller resets `TimeZone` first, so slots stay at the same local time in the new zone).
    public func rearm(clockChanged: Bool = false) {
        let now = Date()
        if clockChanged { lastSlot = lastSlot.mapValues { min($0,now) } }
        rearm(at: now)
    }

    /// For good: nothing fires after this, even a re-arm already on its way.
    public func stop() { stopped = true; loop?.cancel(); loop = nil; next = [:] }

    private func rearm(at now: Date) {
        loop?.cancel(); loop = nil
        guard !stopped else { return }
        let calendar = Cron.calendar()
        next = [:]
        for s in specs where !s.paused && !s.retired {
            next[s.id] = Cron.next(after: max(now.addingTimeInterval(-60),lastSlot[s.id] ?? now),expressions: s.schedule,calendar: calendar)
        }
        guard let wake = next.values.min() else { loop = nil; return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0,wake.timeIntervalSinceNow)))
            await self?.tick()
        }
    }

    private func tick() {
        guard !Task.isCancelled else { return } // a newer arm replaced this one
        let now = Date()
        for s in specs { guard let slot = next[s.id], slot <= now else { continue }
            lastSlot[s.id] = slot
            guard now.timeIntervalSince(slot) <= 60 else { continue } // late: skipped silently
            Task { await self.fire(s,slot: slot) }
        }
        rearm(at: now)
    }

    private func fire(_ spec: JobSpec, slot: Date) async {
        guard case .started = await engine.runJob(spec,slot: slot), spec.once else { return }
        retiring.insert(spec.id)
        if let i = specs.firstIndex(where: { $0.id == spec.id }) { specs[i].retired = true }
        writeRetired(); rearm(at: Date())
    }

    /// Best effort: an invalid file refuses the write, and the next valid set tries again.
    private func writeRetired() {
        let ids = retiring
        _ = try? JobsFile.update(file) { jobs in for i in jobs.indices where ids.contains(jobs[i].id) { jobs[i].retired = true } }
    }
}
