import Foundation

/// One scheduled job: a `[jobs.<id>]` table in `jobs.toml` next to `config.toml` (#319).
public struct JobSpec: Codable, Sendable, Equatable {
    public enum Post: String, Codable, Sendable { case always, notable }
    /// `^[a-z0-9][a-z0-9-]{0,39}$`; also names `~/Yorozu/jobs/<id>/`.
    public var id: String
    public var name: String
    /// 5-field cron expressions in the Mac's time zone; a slot fires when any matches.
    public var schedule: [String]
    public var once = false, paused = false, retired = false
    public var post: Post = .always
    public var script: String?
    public var instruction: String?
    /// `always`, `changed`, or a regular expression the script output must match.
    public var aiWhen = "always"
    /// Script timeout in seconds.
    public var timeout = 600
    public var model: String?
    public var executor: String?
    public var topic: String?
    public init(id: String, name: String, schedule: [String]) { self.id = id; self.name = name; self.schedule = schedule }
}

extension Message {
    /// Job-topic kinds that stay in the job's sub-chat: the run trigger, the job's own input, a run result kept off the
    /// main timeline and skip notes (#319). The Mac's main chat and phones on 0.6 never show them.
    public static let jobOnlyKinds: Set<String> = ["job_run","job_input","job_result","job_note"]
    public var onMainTimeline: Bool { !Self.jobOnlyKinds.contains(kind) }
}
