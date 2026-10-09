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
        guard recheckTask == nil else { return }
        recheckTask = Task {
            defer { recheckTask = nil }
            let h = launched?.config.harness ?? config.harness
            var r = runtimeMode == .live ? await Readiness.harness(h,rpc: gatewayRPC ?? GatewayRPC(target: h.gatewayURL)) : Readiness()
            r.items += [("harness.switch",switchNotice),("files",filesNotice)].compactMap { id,text in text.map { Readiness.Item(id: id,title: $0,severity: .warning) } }
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
    /// Fix…: a step opens the setup window there, a command goes to the clipboard, a link opens.
    func fix(_ fix: Readiness.Item.Fix) {
        switch fix {
        case .step(let id): openSetup(at: id)
        case .copy(_,let command): copyToClipboard(command)
        case .open(_,let url): NSWorkspace.shared.open(url)
        }
    }
    /// The step engine over this run's data root, Gateway client and what only the app knows (enrollment, paired phones).
    func setupEngine() -> SetupEngine? {
        guard let root = configFile?.deletingLastPathComponent() else { return nil }
        return SetupEngine(dataRoot: root,environment: environment,rpc: gatewayRPC,host: .init(enrolled: nativeEnrolled,paired: !relayStatus.devices.isEmpty),executable: Bundle.main.executableURL)
    }
}

func copyToClipboard(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType: .string) }

/// A core English sentence in the user's language when the string catalog has it, else as is.
func localized(_ english: String) -> String { Bundle.main.localizedString(forKey: english,value: english,table: nil) }

extension Readiness {
    /// `summary` in the user's language.
    var localizedSummary: String {
        switch state {
        case .ready: String(localized: "Ready")
        case .attention(let n): n == 1 ? String(localized: "1 item needs attention") : String(localized: "\(n) items need attention")
        case .blocked: localized(items.first { $0.severity == .blocking }?.title ?? "")
        }
    }
    /// The first item that is not OK, blocking first.
    var problem: Item? { items.first { $0.severity == .blocking } ?? items.first { $0.severity == .warning } }
}

/// The readiness dot: green Ready, orange attention, red Blocked, gray while unchecked.
struct ReadinessDot: View {
    let state: Readiness.State?
    private static let side: CGFloat = 6
    var body: some View {
        let color: Color = switch state { case nil: .gray; case .ready: .green; case .attention: .orange; case .blocked: .red }
        Circle().fill(color).frame(width: Self.side,height: Self.side).accessibilityHidden(true)
    }
}

/// Fix… for a readiness item: opens the setup step, copies the command (saying so for a moment) or opens the link.
struct FixButton: View {
    @ObservedObject var model: AppModel
    let fix: Readiness.Item.Fix
    @State private var copied = false
    var body: some View {
        Button(copied ? "Copied" : "Fix…") {
            model.fix(fix)
            guard case .copy = fix else { return }
            copied = true
            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
        }.help(Self.help(fix))
    }
    static func help(_ fix: Readiness.Item.Fix) -> String {
        switch fix { case .step: String(localized: "Open setup at this step"); case .copy(_,let command): String(localized: "Copy: \(command)"); case .open(_,let url): url.absoluteString }
    }
}
