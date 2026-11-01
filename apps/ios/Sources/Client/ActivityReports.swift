import Foundation
import YorozuWire

extension ActivityReport {
    /// The activity's jobs as the wire carries them, times in epoch milliseconds, and the conversation of each running
    /// turn among them (`turns`: job token → convId). Recording and transcription go along unchanged: the host keeps them
    /// as they are in every push, so a push never wipes a job only this device knows.
    init(pushToken: String?, activity jobs: [YorozuJob], turns: [String: String]) {
        let running = Set(jobs.filter { $0.kind == .turn && !$0.finished }.map(\.token))
        self.init(pushToken: pushToken, jobs: jobs.map(Job.init),
                  turns: turns.filter { running.contains($0.key) && WireEvent.isId($0.value) })
    }
}

extension ActivityReport.Job {
    init(_ job: YorozuJob) {
        self.init(token: job.token, kind: job.kind.rawValue, state: job.state.rawValue, steps: job.steps,
                  startedAt: Self.millis(job.startedAt), finishedAt: job.finishedAt.map(Self.millis))
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
