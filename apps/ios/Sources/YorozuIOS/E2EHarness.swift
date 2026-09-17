import Foundation
import UIKit
import YorozuShared

/// A stand-in favicon for the showcase, drawn rather than bundled: a screenshot should not
/// need a real site's icon, and the app should not ship one.
@MainActor
private func showcaseIcon() -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { _ in
        UIColor.systemOrange.setFill()
        UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 32, height: 32), cornerRadius: 7).fill()
        ("C" as NSString).draw(
            at: CGPoint(x: 9, y: 4),
            withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 20),
                .foregroundColor: UIColor.white,
            ]
        )
    }
}

/// Four stand-in photos for the images showcase, drawn rather than bundled: a screenshot should
/// not need anybody's real kitchen, and the app should not ship one. Portrait and numbered, so
/// the grid's cells and the viewer's pages are told apart at a glance.
@MainActor
private func showcaseImages() -> [MessageAttachment] {
    let plates: [(String, UIColor)] = [
        ("kitchen.jpg", .systemTeal),
        ("tap-brass.jpg", .systemOrange),
        ("tap-chrome.jpg", .systemIndigo),
        ("sink.jpg", .systemPink),
    ]
    let size = CGSize(width: 900, height: 1200)
    return plates.enumerated().compactMap { index, plate in
        let (name, colour) = plate
        let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.9) { context in
            colour.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("\(index + 1)" as NSString).draw(
                at: CGPoint(x: 300, y: 420),
                withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 340),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                ]
            )
        }
        return MessageAttachment(name: name, mime: "image/jpeg", bytes: data)
    }
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
        // `-yorozuShowcase <what>`: state seeded on this device alone, so a screenshot needs no
        // relay and no model. Anything unrecognised is the approval card, which came first.
        switch launchArgument("yorozuShowcase") {
        case nil:
            break
        case "threads":
            model.previewThreads()
        case "chat":
            let seed = { [weak model] in
                model?.previewThreads()
                guard let thread = model?.threads.first?.id else { return }
                model?.previewChat(in: thread)
                model?.previewModels(in: thread)
            }
            seed()
            model.onThreads = seed
        case "activity":
            model.previewThreads()
            model.previewActivity(in: model.threads[0].id)
        case "queued":
            model.previewThreads()
            model.previewQueued(in: model.threads[0].id)
        case "share":
            model.previewThreads()
            ChatShowcase.share = true
            // The runtime behind a screenshot has no threads of its own, and its empty
            // `thread_list` would otherwise wipe the seeded ones out from under the picker.
            model.onThreads = { [weak model] in model?.previewThreads() }
        case "settings":
            model.previewThreads()
            model.onThreads = { [weak model] in model?.previewThreads() }
        case "pairing", "pairing-manual", "pairing-error":
            break
        case "model":
            // Re-seeded whenever the runtime sends a list, for the same reason as `share`: the
            // Mac behind a screenshot has no threads, and its empty `thread_list` would
            // otherwise wipe these out — along with the model this one is set to.
            let seed = { [weak model] in
                model?.previewThreads()
                guard let thread = model?.threads.first?.id else { return }
                model?.previewChat(in: thread)
                model?.previewModels(in: thread)
            }
            seed()
            model.onThreads = seed
            // Nothing on a simulator can open a menu, so the menu's own contents are drawn as
            // a popover over the button they hang off.
            ChatShowcase.modelMenu = true
        // The two t53 pictures: several photos in one message as a grid, and the viewer that
        // opens on one of them. Re-seeded on every thread list for the same reason as `share`.
        case "images", "images-viewer":
            ChatShowcase.imageViewer = launchArgument("yorozuShowcase") == "images-viewer"
            let images = showcaseImages()
            let seed = { [weak model] in
                model?.previewThreads()
                guard let thread = model?.threads.first?.id else { return }
                model?.previewImages(in: thread, images: images)
            }
            seed()
            model.onThreads = seed
        case "link":
            model.previewThreads()
            LinkPreviewStore.shared.preload(
                LinkPreview(title: "Roast chicken with lemon and thyme", host: "cooking.example.com", icon: showcaseIcon()),
                for: URL(string: "https://cooking.example.com/roast-chicken")!
            )
            model.previewLink(in: model.threads[0].id)
        // The v1.5 approval scenes, named as the Mac's are so the two sets of pictures compare.
        case "card":
            model.previewStructuredApproval(in: model.newDraft().id)
        case "rule-editor":
            ChatShowcase.ruleEditor = true
            model.previewStructuredApproval(in: model.newDraft().id)
        case "batch":
            model.previewBatchApproval(in: model.newDraft().id)
        case "proposal":
            model.previewRuleProposal(in: model.newDraft().id)
        case "question":
            model.previewQuestion(in: model.newDraft().id)
        case "progress":
            model.previewProgress(in: model.newDraft().id)
        default:
            model.previewApproval(in: model.newDraft().id)
        }
        // `-yorozuScene`: the same idea one step further — a finished conversation, plus the
        // one piece of view state each of these screenshots is about. Nothing here can tap a
        // magnifier, so search is seeded rather than performed.
        if let scene = launchArgument("yorozuScene") {
            if scene == "thread-search" {
                ThreadListShowcase.query = "invoice"
                let seed = { [weak model] in
                    model?.previewThreads()
                    guard let thread = model?.threads.first?.id else { return }
                    model?.previewChat(in: thread)
                }
                seed()
                model.onThreads = seed
            }
            // One thread for the whole scene: seeding the conversation into a fresh draft and
            // then the scene's own messages into whichever thread happened to be first put the
            // two halves of a picture in two different chats.
            let seeded = scene == "thread-search" ? nil : model.newDraft().id
            if scene != "empty", let seeded { model.previewChat(in: seeded) }
            switch scene {
            case "search":
                ChatShowcase.search = "invoice"
            case "reply":
                ChatShowcase.quote = "The April invoice is still open: it was issued on the second and the terms on it are thirty days."
            // The long reply held open, as the `plain` scene's "Read more" leaves it.
            case "expanded":
                ChatShowcase.expanded = true
            default:
                break
            }
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
