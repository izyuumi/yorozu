import Foundation

struct YorozuJob: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Hashable, Sendable { case turn, recording, transcribing, needsYou }
    enum State: String, Codable, Hashable, Sendable { case running, done, failed }

    var token: String
    var kind: Kind
    var state: State
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

    static func newToken() -> String {
        String((0..<16).map { _ in alphabet.randomElement()! })
    }
}

struct YorozuActivityState: Codable, Hashable, Sendable {
    var jobs: [YorozuJob]
    var updatedAt: Date? = nil

    var lastUpdate: Date? { updatedAt ?? jobs.map(YorozuJobs.recency).max() }
}

enum JobChange: Hashable, Sendable {
    case upsert(YorozuJob)
    case finish(token: String, state: YorozuJob.State)
    case remove(token: String)
}

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

enum YorozuJobs {
    static let limit = 8
    static let linger: TimeInterval = 120
    static let staleAfter: TimeInterval = 15 * 60

    enum Compact: Hashable, Sendable { case needsYou, timer(Date), count(Int), done }

    static func compact(_ jobs: [YorozuJob]) -> Compact {
        let running = jobs.filter { !$0.finished }
        if running.contains(where: { $0.kind == .needsYou }) { return .needsYou }
        return switch running.count {
        case 0: .done
        case 1: .timer(running[0].startedAt)
        default: .count(running.count)
        }
    }

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
        switch (job.state, job.kind) {
        case (.running, .needsYou): 0
        case (.failed, _): 1
        case (.running, _): 2
        case (.done, _): 3
        }
    }

    static func recency(_ job: YorozuJob) -> Date { job.finishedAt ?? job.startedAt }

    static func sorted(_ jobs: [YorozuJob]) -> [YorozuJob] {
        jobs.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if recency(a) != recency(b) { return recency(a) > recency(b) }
            return a.token < b.token
        }
    }

    static func capped(_ jobs: [YorozuJob], max: Int = limit) -> [YorozuJob] {
        Array(sorted(jobs).prefix(max))
    }

    static func pruned(_ jobs: [YorozuJob], now: Date) -> [YorozuJob] {
        jobs.filter { job in job.finishedAt.map { now < $0.addingTimeInterval(linger) } ?? true }
    }

    static func apply(_ current: [YorozuJob], _ change: JobChange?, now: Date) -> [YorozuJob] {
        let merged = change.map { merge(current, $0, now: now) } ?? current
        return capped(pruned(merged, now: now))
    }

    static func queued(_ change: JobChange?, label: ActivityLabels.Entry? = nil,
                       previews: @escaping () -> Bool = { WidgetStore.previews }, at url: URL? = ActivityLabelsStore.url)
        -> ([YorozuJob], Date) -> [YorozuJob] {
        return { current, now in
            let previews = previews()
            var next = current
            ActivityLabelsStore.update(previews: previews, at: url) { labels in
                if case .upsert(let job) = change, let label {
                    labels.upsert(token: job.token, convId: label.convId, kind: label.kind, title: label.title, previews: previews)
                }
                next = apply(current, change, now: now)
                labels.prune(keeping: Set(next.map(\.token)))
            }
            return next
        }
    }

    static func shouldEnd(_ jobs: [YorozuJob]) -> Bool { jobs.isEmpty }

    static func nextExpiry(_ jobs: [YorozuJob]) -> Date? {
        jobs.compactMap { $0.finishedAt?.addingTimeInterval(linger) }.min()
    }

    static func dismissal(_ jobs: [YorozuJob]) -> Date? {
        guard !jobs.isEmpty, jobs.allSatisfy(\.finished) else { return nil }
        return jobs.compactMap { $0.finishedAt?.addingTimeInterval(linger) }.max()
    }

    static func staleDate(_ jobs: [YorozuJob], now: Date) -> Date {
        dismissal(jobs) ?? now.addingTimeInterval(staleAfter)
    }

    static func keepsActivityInApp(_ jobs: [YorozuJob]) -> Bool {
        jobs.contains { !$0.finished && ($0.kind == .recording || $0.kind == .transcribing) }
    }
}

struct ActivityLabels: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var convId: String?
        var kind: YorozuJob.Kind
        var title: String?

        func label(previews: Bool) -> String? { previews ? title.flatMap { $0.isEmpty ? nil : $0 } : nil }
    }

    var entries: [String: Entry] = [:]

    mutating func upsert(token: String, convId: String?, kind: YorozuJob.Kind, title: String?, previews: Bool) {
        entries[token] = Entry(convId: convId, kind: kind, title: previews ? title : nil)
    }

    func tokens(for convId: String, kind: YorozuJob.Kind) -> [String] {
        entries.filter { $0.value.convId == convId && $0.value.kind == kind }.keys.sorted()
    }

    func token(for convId: String, kind: YorozuJob.Kind) -> String? { tokens(for: convId, kind: kind).first }

    mutating func prune(keeping tokens: Set<String>) {
        entries = entries.filter { tokens.contains($0.key) }
    }

    mutating func redact(previews: Bool) {
        guard !previews else { return }
        for token in entries.keys { entries[token]?.title = nil }
    }
}

enum ActivityLabelsStore {
    static let fileName = "ActivityLabels.json"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetStore.appGroup)?.appending(path: fileName)
    }

    static func read(from url: URL? = url) -> ActivityLabels {
        guard let url, let data = try? Data(contentsOf: url) else { return ActivityLabels() }
        return (try? JSONDecoder().decode(ActivityLabels.self, from: data)) ?? ActivityLabels()
    }

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
