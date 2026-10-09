import Foundation
import ProjectXCore

/// The binary's entry point: `Yorozu setup …` runs the setup CLI and exits; anything else starts the app.
@main enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "setup" else { ProjectXApp.main(); return }
        Task.detached { exit(await SetupCLI.run(Array(args.dropFirst()))) }
        dispatchMain()
    }
}

/// `Yorozu setup [--json]` prints the next step; `Yorozu setup answer <id> <value> [--json]` applies an answer and prints
/// the next one (#317). A thin shell over `SetupEngine`: no window, no Dock icon, no `app.lock`, no Store. Settings come
/// from the same data root as the app's (`PROJECTX_DATA`, `PROJECTX_MODE`).
enum SetupCLI {
    static func run(_ arguments: [String]) async -> Int32 {
        let json = arguments.contains("--json"), args = arguments.filter { $0 != "--json" }
        func fail(_ message: String, _ code: Int32) -> Int32 {
            if json { print(encode(["error": message])) } else { FileHandle.standardError.write(Data("error: \(message)\n".utf8)) }
            return code
        }
        let env = ProcessInfo.processInfo.environment
        let engine: SetupEngine
        do { engine = SetupEngine(dataRoot: try Config.dataRoot(env,bundleID: Bundle.main.bundleIdentifier ?? "to.yumi.yorozu").root,environment: env,executable: Bundle.main.executableURL) }
        catch { return fail(error.localizedDescription,1) }
        do {
            let report: SetupReport
            switch args.first {
            case nil: report = try await engine.evaluate()
            case "answer" where args.count == 3: report = try await engine.answer(args[1],args[2])
            default: return fail("usage: Yorozu setup [--json] | Yorozu setup answer <id> <value> [--json]",2)
            }
            print(json ? encode(object(report)) : text(report))
            return 0
        } catch ProjectError.invalid(let message) { return fail(message,2) }
        catch ProjectError.blocked(let message) { return fail(message,2) }
        catch { return fail(error.localizedDescription,1) }
    }

    /// One object: the steps, every check, and either the next question (with the write it would make) or `"done": true`
    /// plus the app-only steps left and where to finish them.
    static func object(_ r: SetupReport) -> [String:Any] {
        func fix(_ f: Readiness.Item.Fix) -> [String:Any] {
            switch f { case .step(let id): ["step": id]; case .copy(let t,let c): ["title": t,"copy": c]; case .open(let t,let u): ["title": t,"open": u.absoluteString] }
        }
        var out: [String:Any] = [
            "steps": r.steps.map { s in ["id": s.id,"title": s.title,"state": s.state.rawValue].merging(s.whereInApp.map { ["where": $0] } ?? [:]) { a,_ in a } },
            "checks": r.steps.flatMap { s in s.checks.map { c in
                ["step": s.id,"id": c.id,"title": c.title,"severity": c.severity.rawValue].merging((c.detail.isEmpty ? [:] : ["detail": c.detail] as [String:Any]).merging(c.fix.map { ["fix": fix($0)] } ?? [:]) { a,_ in a }) { a,_ in a }
            } },
        ]
        if let next = r.next, let q = next.question {
            out["step"] = next.id
            out["question"] = ["id": q.id,"text": q.text,"choices": q.choices,"default": q.default]
            if let plan = next.plan, SetupEngine.assisted.contains(q.id) { out["changes"] = plan.changes.map { ["path": $0.path,"old": $0.old as Any? ?? NSNull(),"new": $0.new as Any? ?? NSNull()] as [String:Any] }; out["confirm"] = plan.needsConfirmation; out["plan_digest"] = plan.digest }
        } else {
            out["done"] = true
            let left = r.inApp
            if !left.isEmpty { out["finish_in_app"] = left.map { ["id": $0.id,"title": $0.title,"where": $0.whereInApp ?? ""] } }
        }
        return out
    }

    static func text(_ r: SetupReport) -> String {
        var lines = ["Yorozu setup"]
        for s in r.steps where s.id != "done" {
            lines.append("  " + ["done": "done   ","needed": "needed ","app": "in app "][s.state.rawValue]! + s.title + (s.state == .app ? ": finish this in the Yorozu app (\(s.whereInApp ?? "the setup window"))" : ""))
            for c in s.checks {
                let fix = c.fix.map { f -> String in switch f { case .step(let id): " (setup step: \(id))"; case .copy(_,let cmd): " (run: \(cmd))"; case .open(_,let url): " (see \(url.absoluteString))" } } ?? ""
                lines.append("          " + (c.severity == .ok ? "ok  " : c.severity == .warning ? "warn" : "STOP") + "  " + c.title + fix)
            }
        }
        if let next = r.next, let q = next.question {
            if let plan = next.plan, SetupEngine.assisted.contains(q.id) { lines += ["","Changes to " + (q.id == "hermes_setup" ? "Yorozu's Hermes profiles" : "OpenClaw's config") + " (plan \(plan.digest)):"] + plan.changes.map { "  " + $0.line } + ["To apply exactly these changes, answer apply:\(plan.digest); if they change before then, setup refuses and asks you to look again."] }
            lines += ["",q.text,"Choices: " + q.choices.joined(separator: ", ") + " (default: \(q.default))","Answer with: Yorozu setup answer \(q.id) <choice>"]
        } else {
            lines += ["","Setup is done here."]
            lines += r.inApp.map { "Finish in the Yorozu app: \($0.title) (\($0.whereInApp ?? "the setup window"))." }
        }
        return lines.joined(separator: "\n")
    }

    static func encode(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object,options: [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])).map { String(decoding: $0,as: UTF8.self) } ?? "{}"
    }
}
