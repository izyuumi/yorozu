import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func job(_ token: String, _ kind: YorozuJob.Kind, _ state: YorozuJob.State = .running, at offset: TimeInterval = 0,
                 finished: TimeInterval? = nil, steps: Int? = nil) -> YorozuJob {
    YorozuJob(token: token, kind: kind, state: state, steps: steps, startedAt: t0 + offset, finishedAt: finished.map { t0 + $0 })
}

@Suite struct YorozuActivityTests {
    @Test func tokensAreRandomAndUrlSafe() {
        let a = YorozuJob.newToken(), b = YorozuJob.newToken()
        #expect(a.count == 16 && a != b)
        #expect(a.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func upsertIsIdempotent() {
        let turn = job("a", .turn, steps: 1)
        let once = YorozuJobs.merge([], .upsert(turn), now: t0)
        #expect(once == [turn])
        #expect(YorozuJobs.merge(once, .upsert(turn), now: t0 + 5) == once)
        var more = turn
        more.steps = 3
        #expect(YorozuJobs.merge(once, .upsert(more), now: t0) == [more])
    }

    @Test func finishingStampsOnce() {
        let start = [job("a", .turn)]
        let done = YorozuJobs.merge(start, .finish(token: "a", state: .done), now: t0 + 10)
        #expect(done.first?.state == .done && done.first?.finishedAt == t0 + 10)
        let again = YorozuJobs.merge(done, .finish(token: "a", state: .done), now: t0 + 50)
        #expect(again == done)
        let upserted = YorozuJobs.merge(done, .upsert(job("a", .turn, .done)), now: t0 + 60)
        #expect(upserted.first?.finishedAt == t0 + 10)
        let rerun = YorozuJobs.merge(done, .finish(token: "a", state: .running), now: t0 + 70)
        #expect(rerun.first?.finishedAt == nil)
        #expect(YorozuJobs.merge(start, .finish(token: "missing", state: .done), now: t0) == start)
        #expect(YorozuJobs.merge(start, .remove(token: "a"), now: t0).isEmpty)
    }

    @Test func sortsNeedsYouRecordingRunningThenFinished() {
        let jobs = [
            job("done-old", .turn, .done, finished: 5), job("turn-old", .turn, at: 1), job("rec", .recording, at: 2),
            job("ask", .needsYou, at: 0), job("turn-new", .transcribing, at: 3), job("failed-new", .turn, .failed, finished: 9),
        ]
        #expect(YorozuJobs.sorted(jobs).map(\.token) == ["ask", "rec", "turn-new", "turn-old", "failed-new", "done-old"])
        let tied = [job("b", .turn), job("a", .turn)]
        #expect(YorozuJobs.sorted(tied).map(\.token) == ["a", "b"])
    }

    @Test func capKeepsNeedsYouAndRecording() {
        var jobs = (0..<6).map { job("done\($0)", .turn, .done, finished: TimeInterval($0)) }
        jobs += (0..<4).map { job("turn\($0)", .turn, at: TimeInterval($0)) }
        jobs += [job("ask", .needsYou, at: -100), job("rec", .recording, at: -100)]
        let capped = YorozuJobs.capped(jobs)
        #expect(capped.count == YorozuJobs.limit)
        #expect(capped.map(\.token) == ["ask", "rec", "turn3", "turn2", "turn1", "turn0", "done5", "done4"])
        let many = (0..<10).map { job("ask\($0)", .needsYou, at: TimeInterval($0)) } + [job("turn", .turn, at: 100)]
        #expect(!YorozuJobs.capped(many).contains { $0.token == "turn" })
    }

    @Test func finishedJobsLingerTwoMinutes() {
        let jobs = [job("done", .turn, .done, finished: 0), job("failed", .turn, .failed, finished: 10), job("run", .turn)]
        #expect(YorozuJobs.pruned(jobs, now: t0 + 119.9).count == 3)
        #expect(YorozuJobs.pruned(jobs, now: t0 + 120).map(\.token) == ["failed", "run"])
        #expect(YorozuJobs.pruned(jobs, now: t0 + 130).map(\.token) == ["run"])
        #expect(YorozuJobs.nextExpiry(jobs) == t0 + 120)
        #expect(YorozuJobs.dismissal(jobs) == nil)
        #expect(YorozuJobs.dismissal(Array(jobs.prefix(2))) == t0 + 130)
        #expect(YorozuJobs.staleDate(jobs, now: t0) == t0 + YorozuJobs.staleAfter)
        #expect(YorozuJobs.staleDate(Array(jobs.prefix(2)), now: t0) == t0 + 130)
    }

    @Test func endsWhenNoJobsAreLeft() {
        let jobs = YorozuJobs.apply([job("a", .turn, .done, finished: 0)], nil, now: t0 + 120)
        #expect(YorozuJobs.shouldEnd(jobs))
        #expect(!YorozuJobs.shouldEnd([job("a", .turn)]))
        #expect(YorozuJobs.dismissal([]) == nil)
    }

    @Test func onlyRecordingKeepsTheActivityInTheApp() {
        #expect(!YorozuJobs.keepsActivityInApp([job("a", .turn), job("b", .needsYou)]))
        #expect(YorozuJobs.keepsActivityInApp([job("a", .transcribing)]))
        #expect(!YorozuJobs.keepsActivityInApp([job("a", .recording, .done, finished: 0)]))
    }

    @Test func onlyEventsWithoutAPushAlert() {
        #expect(JobEvent.reply.alert == nil)
        #expect(JobEvent.approval.alert == nil)
        #expect(JobEvent.failurePushed.alert == nil)
        #expect(JobEvent.transcriptReady.alert == .transcriptReady)
        #expect(JobEvent.recordingCap.alert == .recordingCap)
        #expect(JobEvent.localFailure.alert == .localFailure)
    }

    @Test func countsRunningJobs() {
        let jobs = [job("a", .turn), job("b", .transcribing), job("c", .recording), job("d", .needsYou), job("e", .turn, .done, finished: 0)]
        #expect(YorozuJobs.Counts(jobs) == YorozuJobs.Counts(running: 2, needsYou: 1, recording: 1))
        #expect(YorozuJobs.Counts([]) == YorozuJobs.Counts())
    }

    @Test func labelsKeepTitlesOnlyWithPreviews() {
        var labels = ActivityLabels()
        labels.upsert(token: "a", convId: "conv-a", kind: .turn, title: "Trip planning", previews: false)
        #expect(labels.entries["a"]?.title == nil)
        labels.upsert(token: "b", convId: "conv-b", kind: .turn, title: "Groceries", previews: true)
        #expect(labels.entries["b"]?.label(previews: true) == "Groceries")
        #expect(labels.entries["b"]?.label(previews: false) == nil)
        labels.redact(previews: false)
        #expect(labels.entries["b"]?.title == nil && labels.entries["b"]?.convId == "conv-b")
        #expect(labels.token(for: "conv-a", kind: .turn) == "a")
        #expect(labels.token(for: "conv-a", kind: .needsYou) == nil)
        labels.prune(keeping: ["b"])
        #expect(Set(labels.entries.keys) == ["b"])
    }

    @Test func labelsFileIsRedactedOnWrite() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ActivityLabels-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        ActivityLabelsStore.update(previews: true, at: url) { $0.upsert(token: "a", convId: "c", kind: .turn, title: "Trip", previews: true) }
        #expect(ActivityLabelsStore.read(from: url).entries["a"]?.title == "Trip")
        ActivityLabelsStore.update(previews: false, at: url) { _ in }
        #expect(ActivityLabelsStore.read(from: url).entries["a"]?.title == nil)
        #expect(try !String(decoding: Data(contentsOf: url), as: UTF8.self).contains("Trip"))
    }

    @Test func pushesUpdateTheActivity() {
        var labels = ActivityLabels()
        labels.upsert(token: "turn", convId: "conv", kind: .turn, title: nil, previews: false)
        let start = [job("turn", .turn)]
        let asked = YorozuJobs.pushed(.approval, convId: "conv", title: "Trip", previews: true, jobs: start, labels: &labels, now: t0)
        #expect(asked.map(\.kind) == [.needsYou, .turn])
        let ask = asked[0].token
        #expect(labels.entries[ask] == ActivityLabels.Entry(convId: "conv", kind: .needsYou, title: "Trip"))
        let twice = YorozuJobs.pushed(.approval, convId: "conv", title: "Trip", previews: true, jobs: asked, labels: &labels, now: t0 + 1)
        #expect(twice == asked)
        let replied = YorozuJobs.pushed(.reply, convId: "conv", title: nil, previews: true, jobs: asked, labels: &labels, now: t0 + 2)
        #expect(replied == [job("turn", .turn, .done, finished: 2)])
        #expect(Set(labels.entries.keys) == ["turn"])
        let failed = YorozuJobs.pushed(.failurePushed, convId: "conv", title: nil, previews: false, jobs: start, labels: &labels, now: t0)
        #expect(failed.first?.state == .failed)
        let unknown = YorozuJobs.pushed(.reply, convId: "other", title: nil, previews: false, jobs: start, labels: &labels, now: t0)
        #expect(unknown == start)
    }

    @Test func stateStaysSmallAndCarriesNoConversation() throws {
        var labels = ActivityLabels()
        var jobs: [YorozuJob] = []
        for index in 0..<12 {
            let job = YorozuJob(kind: .turn, steps: 999, startedAt: t0 + TimeInterval(index))
            labels.upsert(token: job.token, convId: "conversation-\(index)", kind: .turn, title: "Secret title \(index)", previews: true)
            jobs = YorozuJobs.apply(jobs, .upsert(job), now: t0)
        }
        jobs = YorozuJobs.apply(jobs, .finish(token: jobs[0].token, state: .failed), now: t0 + 1_000_000)
        #expect(jobs.count == YorozuJobs.limit)
        let data = try JSONEncoder().encode(YorozuActivityState(jobs: jobs))
        #expect(data.count < 2048)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("conversation-") && !text.contains("Secret") && !text.contains("convId") && !text.contains("title"))
    }
}
