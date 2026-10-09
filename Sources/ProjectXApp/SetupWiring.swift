import AppKit
import ProjectXCore
import SwiftUI
import YorozuWire

/// Readiness and setup at run time (#317): the check behind the status line, the composer and phones, Fix…, and the
/// setup window's engine.
extension AppModel {
    /// Checks readiness again: at launch, after a Gateway call fails, and before a send while not ready. One check at a
    /// time; phones get each change. Fixture and offline runs have no harness to check.
    func recheck() {
        guard recheckTask == nil else { recheckAgain = true; return }
        recheckTask = Task {
            defer { recheckTask = nil; if recheckAgain { recheckAgain = false; recheck() } }
            // The launched harness, against the settings in force now: Hermes's profiles follow [mcp_servers] and dev_repo.
            var c = config
            if let l = launched?.config.harness { let repo = c.harness.devRepo; c.harness = l; c.harness.devRepo = repo }
            var r = runtimeMode == .live ? await Readiness.harness(c,rpc: gatewayRPC ?? GatewayRPC(target: c.harness.gatewayURL)) : Readiness()
            if let switchNotice { r.items.append(Readiness.Item(id: "harness.switch",title: switchNotice,severity: .warning,fix: .step("harness"))) }
            // A fixed title: phones get titles, never the raw error.
            if let filesNotice { r.items.append(Readiness.Item(id: "files",title: String(localized: "Attachments are off this launch"),detail: filesNotice,severity: .warning)) }
            guard r != readiness else { return }
            readiness = r
            await publishReadiness(ReadinessData(r))
        }
    }
    /// A failure row newer than the last one the poll saw: a Gateway or harness call failed, so check again.
    func noteFailures(_ snapshot: Snapshot) {
        let last = snapshot.messages.last { $0.kind == "failure" && $0.notice?.params["error"] != nil }?.id ?? ""
        if let seen = lastFailureID, last != seen, !last.isEmpty { recheck() }
        lastFailureID = last
    }
    /// Opens the setup window, at `step` when given (a Fix… target).
    func openSetup(at step: String? = nil) { setupStep = step; setupRequests += 1 }
    /// The step engine over this run's data root, Gateway client and what only the app knows (enrollment, paired phones).
    func setupEngine() -> SetupEngine? {
        guard let root = configFile?.deletingLastPathComponent() else { return nil }
        return SetupEngine(dataRoot: root,environment: environment,rpc: gatewayRPC,host: .init(enrolled: nativeEnrolled,paired: !relayStatus.devices.isEmpty),executable: Bundle.main.executableURL)
    }
}

func copyToClipboard(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType: .string) }

extension Readiness {
    /// The first item that is not OK, blocking first.
    var problem: Item? { items.first { $0.severity == .blocking } ?? items.first { $0.severity == .warning } }
}

/// The readiness dot: green Ready, orange attention, red Blocked, gray while unchecked.
struct ReadinessDot: View {
    let state: Readiness.State?
    private static let side: CGFloat = 6
    var body: some View {
        let color: Color = switch state { case nil: .gray; case .ready: .green; case .attention: .orange; case .blocked: .red }
        let label = switch state {
        case nil: String(localized: "Checking")
        case .ready: String(localized: "Ready")
        case .attention(let n): n == 1 ? String(localized: "1 item needs attention") : String(localized: "\(n) items need attention")
        case .blocked: String(localized: "Blocked")
        }
        Circle().fill(color).frame(width: Self.side,height: Self.side).accessibilityElement().accessibilityLabel(label)
    }
}

/// Fix… for a readiness item: opens the setup window at the item's step, else at the harness step. Commands to copy and
/// links stay in the setup window, next to the item.
struct FixButton: View {
    @ObservedObject var model: AppModel
    let fix: Readiness.Item.Fix?
    var body: some View {
        Button("Fix…") { model.openSetup(at: step) }.help("Open setup at this step")
    }
    private var step: String { if case .step(let id)? = fix { id } else { "harness" } }
}
