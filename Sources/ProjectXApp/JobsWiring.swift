import AppKit
import ProjectXCore

/// Jobs at run time (#319): the script runner, `jobs.toml` and its watcher, the scheduler, and the system events that
/// re-arm it. Started after `engine.resume()` in every mode; offline lists jobs and runs none (open question 16).
extension AppModel {
    /// `scripts`: `~/Yorozu/jobs` for the live default data, `<data root>/jobs` for fixture and `PROJECTX_DATA` runs.
    func startJobs(_ engine: Engine, root: URL, scripts: URL) async {
        let file = JobsFile.url(in: root), runner = ScriptRunner(root: scripts)
        await engine.configureJobs(runner: runner,file: file) { edit in try JobsFile.update(file) { try edit(&$0) } }
        let scheduler = JobScheduler(engine: engine,file: file)
        jobRunner = runner; jobScheduler = scheduler
        // One consumer, so sets arrive in file order.
        let (updates,sink) = AsyncStream<JobsWatcher.Update>.makeStream()
        jobsConsumer = Task { [weak self] in
            for await update in updates {
                await engine.jobs(update.jobs); await scheduler.update(update.jobs)
                await self?.reportJobs(update.error,engine: engine)
            }
        }
        let watcher = JobsWatcher(file: file) { sink.yield($0) }
        jobsWatcher = watcher; watcher.start()
        func observe(_ center: NotificationCenter,_ name: Notification.Name,clock: Bool = false,zone: Bool = false) -> (NotificationCenter,NSObjectProtocol) {
            (center,center.addObserver(forName: name,object: nil,queue: nil) { _ in
                if zone { NSTimeZone.resetSystemTimeZone() }
                Task { await scheduler.rearm(clockChanged: clock) }
            })
        }
        jobObservers = [observe(NSWorkspace.shared.notificationCenter,NSWorkspace.didWakeNotification),
                        observe(.default,.NSSystemClockDidChange,clock: true),observe(.default,.NSSystemTimeZoneDidChange,zone: true)]
    }

    /// Quit: no new fires, and running scripts end now. Synchronous, because the process may exit before a task runs.
    func stopJobs() {
        for (center,token) in jobObservers { center.removeObserver(token) }; jobObservers = []
        jobsWatcher?.stop(); jobsConsumer?.cancel()
        if let jobScheduler { Task { await jobScheduler.stop() } }
        jobRunner?.terminateAll()
    }

    /// An invalid `jobs.toml` keeps the last valid set; one notice per distinct problem: a `job_note` in the job's
    /// sub-chat when one bound job is at fault, else a `config_invalid` failure in the main timeline.
    private func reportJobs(_ problem: ConfigError?,engine: Engine) async {
        guard problem != lastJobsError else { return }
        lastJobsError = problem
        guard let problem else { return }
        var params = ["file": problem.file,"reason": problem.reason]; params["line"] = problem.line.map(String.init); params["key"] = problem.key
        let body = "Jobs not updated: \(problem.localizedDescription). The last valid jobs keep running until the file is fixed."
        if let id = problem.jobID, let topic = try? await engine.store.job(id)?.topicID {
            params["job"] = id
            _ = try? await engine.store.message(role: "assistant",body: body,topic: topic,kind: "job_note",notice: Notice(.configInvalid,params))
        } else {
            _ = try? await engine.store.message(role: "assistant",body: body,kind: "failure",notice: Notice(.configInvalid,params))
        }
    }
}
