import Foundation

/// App-written notices (`messages.notice` `{code, params}`) as sentences in the user's language, at display time.
/// Shared by the Mac app and the iOS app, so codes are plain strings (iOS has no ProjectXCore); the codes are
/// `Notice.Code` in Sources/ProjectXCore/Models.swift. Raw error text never goes into the sentence: it is `details`.
enum NoticeText {
    /// The notice sentence for `code`, or `fallback` (the stored English body) for an unknown code, a missing
    /// parameter, or a code whose body carries content of its own (a clarify reply: `question` with no params).
    static func text(code: String, params: [String: String], fallback: String) -> String {
        // A failure with a known setup cause leads with what to fix; the raw error stays in Details.
        if ["routing_failed","task_failed","task_control_failed"].contains(code), let cause = plain(cause: params["cause"], subject: params["subject"]) {
            return cause + " " + text(code: code, params: params.filter { $0.key != "cause" }, fallback: fallback)
        }
        let name = params["name"]
        switch code {
        case "question_topic": return String(localized: "Which subject should this belong to?")
        case "question_task": return String(localized: "Which task do you mean?")
        case "routing_failed": return String(localized: "Yorozu couldn’t handle that message. Send it again to retry.")
        case "offline": return String(localized: "Offline mode: the message was saved, and no model was called.")
        case "task_failed": return String(localized: "That task failed. Say retry to try again.")
        case "task_overflow": return String(localized: "That task is too large for the model’s context, so retrying it unchanged would fail the same way. Start a new topic or shorten the request.")
        case "interrupted_by_restart": return String(localized: "That task was interrupted by a restart. Say retry to continue.")
        case "compaction_failed": return String(localized: "Yorozu couldn’t compact this topic’s session.")
        case "memory_skipped":
            guard let count = params["count"].flatMap(Int.init) else { return fallback }
            return String(localized: "Memory skipped \(count) note files that are too large or unreadable.")
        case "retry_running": return String(localized: "The earlier run is active or its status is unknown, so retry hasn’t started. That avoids running it twice.")
        case "retry_not_allowed":
            // Two stored bodies share this code without params; the job one is told apart by its English text.
            if fallback.hasPrefix("That job") { return String(localized: "That job no longer exists, so its script can’t run again.") }
            return String(localized: "Only failed or stopped work can be retried. Active work isn’t run twice.")
        case "correction_blocked": return String(localized: "The intended topic is still stopping earlier work. Your correction is kept in its history, and nothing was started twice.")
        case "earlier_stopped_with_change": return String(localized: "An earlier task here stopped with a saved change that never ran. Say retry to apply it first, then send this again.")
        case "earlier_finished_change": return String(localized: "The earlier task here finished before your saved change, so I’m applying that change now. Send this again once it’s done, or tell me to add it to that task.")
        case "earlier_running": return String(localized: "An earlier task here is still running, so I haven’t started this, to avoid running it twice. Say stop to end it, or send this again once it finishes.")
        case "earlier_unknown": return String(localized: "I can’t confirm whether an earlier task here is still running, so I haven’t started this, to avoid running it twice. Say stop to end it, or try again in a few minutes.")
        case "change_queued": return String(localized: "Added that to the task before it starts.")
        case "change_sent": return String(localized: "Sent that change to the running task.")
        case "change_held":
            // The executor sentence only when the body has it: a live-steer executor that missed the step has the plain one.
            // The executor's display name, else the id that older messages stored.
            if let executor = params["executorName"] ?? params["executor"], fallback.contains("can't take changes") { return String(localized: "\(executor) can’t take changes mid-run, so it gets this after its current run. Say stop to halt it now.") }
            return String(localized: "I’ll apply that right after the current step.")
        case "change_after_finish": return String(localized: "The earlier run finished before your change, so I’m applying it now.")
        case "not_running": return String(localized: "That isn’t running.")
        case "stopped": return String(localized: "Stopped.")
        case "stopping": return String(localized: "Stopping it; not confirmed yet.")
        case "moved": return String(localized: "Got it, moving that to the right topic.")
        case "moved_stopping": return String(localized: "Got it, moving that to the right topic. Stopping the earlier task (not confirmed yet).")
        case "correction_saved": return String(localized: "Saved that on the intended task, but its earlier run status is unknown. Say retry to check it and continue.")
        case "earlier_retired": return String(localized: "The earlier task here stopped without finishing, so I closed it and started your new request. Its history stays in this topic.")
        case "memory_forgotten": return String(localized: "Removed that memory from Markdown and refreshed its index. The chat history is unchanged.")
        case "amendment_unconfirmed": return String(localized: "The task finished without confirming your latest change. Its answer is in the sub-chat.")
        case "closed_too_long": return String(localized: "Yorozu was closed for more than 24 hours. Send this again if it still applies.")
        case "task_control_failed": return String(localized: "Yorozu couldn’t do that for the task.")
        case "config_invalid":
            guard let file = params["file"] else { return fallback }
            if (file as NSString).lastPathComponent == "jobs.toml" { return String(localized: "Jobs not updated: jobs.toml has a problem. The last valid jobs keep running until the file is fixed.") }
            if fallback.contains("default settings") { return String(localized: "Settings not applied: config.toml has a problem. Yorozu runs on its default settings until the file is fixed.") }
            return String(localized: "Settings not applied: config.toml has a problem. The last valid settings stay in force.")
        case "settings_changed":
            guard let keys = params["keys"] else { return fallback }
            return String(localized: "Settings changed: \(keys)")
        case "harness_busy": return String(localized: "The harness is busy, so nothing was started. Try again shortly.")
        case "run_interrupted": return String(localized: "The run ended before it finished. Say retry to run it again.")
        case "approval_requested": return String(localized: "The harness asked to approve a step, but approvals are off for Yorozu’s workers, so Yorozu denied it and stopped the task. Check the worker’s approvals setting, then say retry.")
        case "model_mismatch": return String(localized: "The harness ran another model than the one set, so its output wasn’t used.")
        case "harness_not_ready":
            // Without an error param the body is the only text naming what is missing.
            guard params["error"] != nil else { return fallback }
            return String(localized: "The harness or the executor isn’t ready for this.")
        case "job_approval_requested":
            // The body holds the script; keep it and localize the sentences around it.
            guard let name, let start = fallback.range(of: "\n\n"), let end = fallback.range(of: "\n\nSay yes to approve", options: .backwards), start.upperBound <= end.lowerBound else { return fallback }
            let head = fallback.contains("a changed script") ? String(localized: "“\(name)” has a changed script that needs your yes before it runs. YOLO doesn’t lift this.")
                : String(localized: "“\(name)” has a new script that needs your yes before it runs. YOLO doesn’t lift this.")
            var script = String(fallback[start.upperBound..<end.lowerBound])
            let full = "\n(The full script is in jobs.toml.)"
            if script.hasSuffix(full) { script = String(script.dropLast(full.count)) + "\n" + String(localized: "(The full script is in jobs.toml.)") }
            return head + "\n\n" + script + "\n\n" + String(localized: "Say yes to approve this exact script.")
        case "job_approved":
            guard let name else { return fallback }
            return String(localized: "Approved. “\(name)” runs this script from its next run.")
        case "job_approval_stale": return String(localized: "That script changed after the request, so it wasn’t approved. A new request shows the current script.")
        case "job_skipped":
            guard let reason = skipReason(params["reason"]) else { return fallback }
            guard let slot = params["slot"] else { return String(localized: "It didn’t run again.") + " " + reason }
            let when = ISO8601DateFormatter().date(from: slot)?.formatted(date: .abbreviated, time: .shortened) ?? slot
            return String(localized: "Skipped the run at \(when).") + " " + reason
        case "job_failed":
            guard let name else { return fallback }
            switch params["reason"] {
            case "timeout": return String(localized: "“\(name)” failed: its script ran past its time limit and was stopped. Its output is in the job’s chat.")
            case "exit": return String(localized: "“\(name)” failed: its script ended with an error. Its output is in the job’s chat.")
            default: return String(localized: "“\(name)” failed.")
            }
        case "job_interrupted":
            guard let name else { return fallback }
            return String(localized: "“\(name)”’s script was interrupted when Yorozu quit, and it won’t run again by itself. Say retry to run it again or stop to clear it.")
        default: return fallback // `question` (a clarify reply's own words) and codes newer than this build
        }
    }

    /// A known setup cause (`PlainError.cause` in Sources/ProjectXCore/PlainError.swift) as a sentence; nil for an unknown one.
    static func plain(cause: String?, subject: String?) -> String? {
        switch cause {
        case "openclaw_missing": String(localized: "OpenClaw or Node.js isn’t installed.")
        case "gateway_down": String(localized: "The OpenClaw Gateway isn’t running. Start it with `openclaw gateway run`.")
        case "agent_missing": String(localized: "Yorozu’s agent isn’t set up in OpenClaw.")
        case "personal_agent": String(localized: "Yorozu needs its own OpenClaw agent, not your main one. Set [harness] agent to a dedicated id.")
        case "gateway_target": subject.map { String(localized: "Nothing answers at \($0); check [harness] gateway_url") }
        case "model_not_allowed": subject.map { String(localized: "OpenClaw doesn’t allow \($0) for Yorozu.") }
        case "exec_markers": String(localized: "Yorozu was started from an agent’s shell; open it from Finder.")
        case "already_running": String(localized: "Yorozu is already running.")
        case "memory_file": subject.map { String(localized: "Yorozu’s memory can’t load \($0).") }
        default: nil
        }
    }

    /// The raw text for a Details disclosure: the error, else a config problem's place and reason, else skipped files.
    static func details(_ params: [String: String]) -> String? {
        if let error = params["error"], !error.isEmpty { return error }
        if let file = params["file"], let reason = params["reason"] {
            return (file as NSString).lastPathComponent + (params["line"].map { " line \($0)" } ?? "") + (params["key"].map { " (\($0))" } ?? "") + ": " + reason
        }
        return params["files"]
    }

    static func skipReason(_ reason: String?) -> String? {
        switch reason {
        case "overlap": String(localized: "The previous run is still going.")
        case "uncertain": String(localized: "An earlier run was interrupted and its state is unknown. Say retry or stop about it to resume the schedule.")
        case "needsApproval": String(localized: "Its script waits for your yes.")
        case "paused": String(localized: "The job is paused.")
        case "unavailable": String(localized: "Jobs can’t run here right now.")
        default: nil
        }
    }
}
