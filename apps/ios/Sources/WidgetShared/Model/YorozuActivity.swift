import Foundation

/// One row of the app's single Live Activity. Keyed by an opaque random token, never by a conversation:
/// what the row is about lives only in the device's `ActivityLabels`, so a pushed state carries no
/// conversation, title, text or tool name.
struct YorozuJob: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Hashable, Sendable { case turn, recording, transcribing, needsYou }
    enum State: String, Codable, Hashable, Sendable { case running, done, failed }

    var token: String
    var kind: Kind
    var state: State
    /// Tool steps of a turn; a count only.
    var steps: Int?
    var startedAt: Date
    var finishedAt: Date?

    var id: String { token }
    var finished: Bool { state != .running }

    init(token: String = YorozuJob.newToken(), kind: Kind, state: State = .running, steps: Int? = nil,
         startedAt: Date, finishedAt: Date? = nil) {
        self.token = token
        self.kind = kind
        self.state = state
        self.steps = steps
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// 16 random url-safe characters.
    static func newToken() -> String {
        String((0..<16).map { _ in alphabet.randomElement()! })
    }
}

/// The Live Activity's whole content state. A push would replace it outright.
struct YorozuActivityState: Codable, Hashable, Sendable {
    var jobs: [YorozuJob]
}

/// A change from any job source: the app, the notification service, later a push.
enum JobChange: Hashable, Sendable {
    case upsert(YorozuJob)
    case finish(token: String, state: YorozuJob.State)
    case remove(token: String)
}

/// Events that touch a job. Only the ones no push already announces alert.
enum JobEvent: Hashable, Sendable {
    case reply, approval, failurePushed, transcriptReady, recordingCap, localFailure

    enum Alert: Hashable, Sendable { case transcriptReady, recordingCap, localFailure }

    var alert: Alert? {
        switch self {
        case .reply, .approval, .failurePushed: nil
        case .transcriptReady: .transcriptReady
        case .recordingCap: .recordingCap
        case .localFailure: .localFailure
        }
    }
}

/// The pure job math behind the Live Activity, keyed by token.
enum YorozuJobs {
    static let limit = 8
    /// A finished job stays this long as a tap target.
    static let linger: TimeInterval = 120
    /// A running activity without an update for this long shows as stale.
    static let staleAfter: TimeInterval = 15 * 60

    struct Counts: Codable, Hashable, Sendable {
        var running = 0
        var needsYou = 0
        var recording = 0

        init(running: Int = 0, needsYou: Int = 0, recording: Int = 0) {
            self.running = running
            self.needsYou = needsYou
            self.recording = recording
        }

        init(_ jobs: [YorozuJob]) {
            for job in jobs where !job.finished {
                switch job.kind {
                case .turn, .transcribing: running += 1
                case .recording: recording += 1
                case .needsYou: needsYou += 1
                }
            }
        }
    }

    /// Upserts by token; a finished state stamps `finishedAt` once, a running one clears it. Idempotent.
    static func merge(_ current: [YorozuJob], _ change: JobChange, now: Date) -> [YorozuJob] {
        var jobs = current
        switch change {
        case .upsert(var job):
            let existing = jobs.firstIndex { $0.token == job.token }
            job.finishedAt = job.finished ? existing.flatMap { jobs[$0].finishedAt } ?? job.finishedAt ?? now : nil
            if let existing { jobs[existing] = job } else { jobs.append(job) }
        case .finish(let token, let state):
            guard let index = jobs.firstIndex(where: { $0.token == token }) else { return jobs }
            jobs[index].state = state
            jobs[index].finishedAt = state == .running ? nil : jobs[index].finishedAt ?? now
        case .remove(let token):
            jobs.removeAll { $0.token == token }
        }
        return jobs
    }

    private static func rank(_ job: YorozuJob) -> Int {
        guard !job.finished else { return 3 }
        return switch job.kind {
        case .needsYou: 0
        case .recording: 1
        case .turn, .transcribing: 2
        }
    }

    private static func recency(_ job: YorozuJob) -> Date { job.finishedAt ?? job.startedAt }

    /// Needs you, recording, running, then finished; newest first within each.
    static func sorted(_ jobs: [YorozuJob]) -> [YorozuJob] {
        jobs.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if recency(a) != recency(b) { return recency(a) > recency(b) }
            return a.token < b.token
        }
    }

    /// At most `max`, dropping the oldest finished first, then the oldest running; needs-you and recording last.
    static func capped(_ jobs: [YorozuJob], max: Int = limit) -> [YorozuJob] {
        Array(sorted(jobs).prefix(max))
    }

    /// Finished jobs leave once they lingered `linger`.
    static func pruned(_ jobs: [YorozuJob], now: Date) -> [YorozuJob] {
        jobs.filter { job in job.finishedAt.map { now < $0.addingTimeInterval(linger) } ?? true }
    }

    /// The change applied, expired jobs gone, sorted and capped: what the activity shows next.
    static func apply(_ current: [YorozuJob], _ change: JobChange?, now: Date) -> [YorozuJob] {
        let merged = change.map { merge(current, $0, now: now) } ?? current
        return capped(pruned(merged, now: now))
    }

    static func shouldEnd(_ jobs: [YorozuJob]) -> Bool { jobs.isEmpty }

    /// When the next finished job expires, if any.
    static func nextExpiry(_ jobs: [YorozuJob]) -> Date? {
        jobs.compactMap { $0.finishedAt?.addingTimeInterval(linger) }.min()
    }

    /// With nothing running, the activity can end and let the system dismiss it when the last row expires.
    static func dismissal(_ jobs: [YorozuJob]) -> Date? {
        guard !jobs.isEmpty, jobs.allSatisfy(\.finished) else { return nil }
        return jobs.compactMap { $0.finishedAt?.addingTimeInterval(linger) }.max()
    }

    static func staleDate(_ jobs: [YorozuJob], now: Date) -> Date {
        dismissal(jobs) ?? now.addingTimeInterval(staleAfter)
    }

    /// Recording and transcription are not on screen in the app, so they keep the activity while it is in front.
    static func keepsActivityInApp(_ jobs: [YorozuJob]) -> Bool {
        jobs.contains { !$0.finished && ($0.kind == .recording || $0.kind == .transcribing) }
    }

    /// A push the notification service decrypted: a reply ends the conversation's turn and its approval, a
    /// failure fails the turn, an approval adds a needs-you row (one per conversation). Writes the new row's
    /// label into `labels`; returns the jobs unchanged when nothing applies.
    static func pushed(_ event: JobEvent, convId: String, title: String?, previews: Bool, jobs current: [YorozuJob],
                       labels: inout ActivityLabels, now: Date) -> [YorozuJob] {
        func running(_ kind: YorozuJob.Kind) -> String? {
            labels.tokens(for: convId, kind: kind).first { token in current.contains { $0.token == token && !$0.finished } }
        }
        var jobs = current
        switch event {
        case .reply:
            if let token = running(.turn) { jobs = merge(jobs, .finish(token: token, state: .done), now: now) }
            if let token = running(.needsYou) { jobs = merge(jobs, .remove(token: token), now: now) }
        case .failurePushed:
            if let token = running(.turn) { jobs = merge(jobs, .finish(token: token, state: .failed), now: now) }
        case .approval:
            guard running(.needsYou) == nil else { break }
            let job = YorozuJob(kind: .needsYou, startedAt: now)
            labels.upsert(token: job.token, convId: convId, kind: .needsYou, title: title, previews: previews)
            jobs = merge(jobs, .upsert(job), now: now)
        case .transcriptReady, .recordingCap, .localFailure:
            break
        }
        let next = apply(jobs, nil, now: now)
        labels.prune(keeping: Set(next.map(\.token)))
        return next
    }
}

/// What each job token is about, kept only on the device next to the widget snapshot: the conversation
/// to open and, only while message previews are on, its title.
struct ActivityLabels: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var convId: String?
        var kind: YorozuJob.Kind
        var title: String?

        /// The title, only while previews are on when the view draws.
        func label(previews: Bool) -> String? { previews ? title.flatMap { $0.isEmpty ? nil : $0 } : nil }
    }

    var entries: [String: Entry] = [:]

    mutating func upsert(token: String, convId: String?, kind: YorozuJob.Kind, title: String?, previews: Bool) {
        entries[token] = Entry(convId: convId, kind: kind, title: previews ? title : nil)
    }

    /// Tokens for a conversation's jobs of one kind, in a stable order.
    func tokens(for convId: String, kind: YorozuJob.Kind) -> [String] {
        entries.filter { $0.value.convId == convId && $0.value.kind == kind }.keys.sorted()
    }

    func token(for convId: String, kind: YorozuJob.Kind) -> String? { tokens(for: convId, kind: kind).first }

    mutating func prune(keeping tokens: Set<String>) {
        entries = entries.filter { tokens.contains($0.key) }
    }

    /// With previews off, no title stays stored.
    mutating func redact(previews: Bool) {
        guard !previews else { return }
        for token in entries.keys { entries[token]?.title = nil }
    }
}

/// The labels file in the App Group container, beside the widget snapshot and protected the same way.
enum ActivityLabelsStore {
    static let fileName = "ActivityLabels.json"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetStore.appGroup)?.appending(path: fileName)
    }

    static func read(from url: URL? = url) -> ActivityLabels {
        guard let url, let data = try? Data(contentsOf: url) else { return ActivityLabels() }
        return (try? JSONDecoder().decode(ActivityLabels.self, from: data)) ?? ActivityLabels()
    }

    /// Redacts to `previews`, then writes atomically when the bytes differ.
    @discardableResult
    static func write(_ labels: ActivityLabels, previews: Bool = WidgetStore.previews, to url: URL? = url) -> Bool {
        var labels = labels
        labels.redact(previews: previews)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let url, let data = try? encoder.encode(labels) else { return false }
        if (try? Data(contentsOf: url)) == data { return false }
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        return (try? data.write(to: url, options: options)) != nil
    }

    @discardableResult
    static func update(previews: Bool = WidgetStore.previews, at url: URL? = url, _ change: (inout ActivityLabels) -> Void) -> Bool {
        var labels = read(from: url)
        change(&labels)
        return write(labels, previews: previews, to: url)
    }
}
