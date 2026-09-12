import Foundation
import YorozuShared

/// Simulators have no camera, so the end-to-end harness injects the QR payload (and a first
/// message) as `-name value` launch arguments. Read straight from `ProcessInfo`: the
/// `UserDefaults` argument domain tries to property-list-parse the value first, and a pairing
/// string is not a plist.
func launchArgument(_ name: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "-\(name)"), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

/// Test harness only, and inert unless `-yorozuSend` was passed: it drives the first message and
/// prints the lines `apps/ios/e2e/run.sh` asserts on. It hangs off the model's hooks rather than
/// living inside it, so nothing about the harness ships in the shared model.
///
/// The model's closures hold it, and it holds the model weakly.
@MainActor
final class E2EHarness {
    private let autoSend: String
    private let autoThread: String?
    private weak var model: ChatModel?

    static func attach(to model: ChatModel) {
        // `-yorozuShowcase`: a local draft seeded with an approval card and a running turn, so
        // the composer and the card can be screenshotted with no relay and no model at all.
        if launchArgument("yorozuShowcase") != nil {
            model.previewApproval(in: model.newDraft().id)
        }
        guard let autoSend = launchArgument("yorozuSend") else { return }
        E2EHarness(model: model, autoSend: autoSend).wire()
    }

    private init(model: ChatModel, autoSend: String) {
        self.model = model
        self.autoSend = autoSend
        self.autoThread = launchArgument("yorozuThread")
    }

    private func wire() {
        model?.onPaired = { [self] in
            print("YOROZU-E2E paired")

            // A draft, exactly as the `+` button makes one: the message below is what creates it.
            if let draft = model?.newDraft() { model?.send(autoSend, in: draft.id) }
            // And a second, named thread, to prove `thread_create` and its sync as well.
            if let autoThread, let id = model?.createThread(title: autoThread) {
                model?.send(autoSend, in: id)
            }
        }
        model?.onEvent = { [self] event in
            switch event.payload {
            case .message(let data) where data.role == .agent:
                let title = model?.title(of: event.threadId) ?? event.threadId
                print("YOROZU-E2E-REPLY [\(title)] \(data.text)")
            case .toolCall(let data):
                print("YOROZU-E2E-TOOL \(data.name)")
            default:
                break
            }
        }
    }
}
