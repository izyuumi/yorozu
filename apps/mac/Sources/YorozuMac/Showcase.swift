import AppKit
import SwiftUI
import YorozuShared

/// Test harness only, and inert unless a `-yorozuShowcase` or `-yorozuScene` argument was
/// passed: state seeded on this Mac alone, so a screenshot needs no provider and no phone.
///
/// Same argument names and the same scene names as the phone's ``E2EHarness``, because they
/// draw the same shared views and the two sets of screenshots are meant to be comparable.
/// Nothing here ships in a view — it hangs off ``ChatModel``'s hooks, exactly as the phone's
/// harness does.
@MainActor
enum Showcase {
    /// Whether the app was launched to be screenshotted. What puts the window number on stdout
    /// and what tells ``LocalChat`` to leave the seeded threads alone.
    static var active: Bool {
        launchArgument("yorozuShowcase") != nil || launchArgument("yorozuScene") != nil
    }

    static func attach(to model: ChatModel) {
        guard active else { return }
        // `-yorozuAppearance light|dark`. AppKit takes the appearance from the system and a
        // screenshot script has no business changing the system, so the one scene that is
        // about the other appearance asks for it here instead.
        switch launchArgument("yorozuAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        // The Mac behind a screenshot has an empty state directory, so the runtime's own
        // `thread_list` is empty too and would wipe the seeded threads out from under the view.
        // Re-seeded on every list rather than once, for that reason — and chained onto whatever
        // ``LocalChat`` already put there rather than over it.
        let existing = model.onThreads
        let seed = { [weak model] in
            existing?()
            guard let model else { return }
            self.seed(model)
        }
        model.onThreads = seed
        seed()
    }

    /// See the `default` case below.
    private static var approvalDraft: String?

    private static func seed(_ model: ChatModel) {
        switch launchArgument("yorozuShowcase") {
        case nil:
            // `-yorozuScene` on its own: a finished conversation in a thread of its own, plus
            // the one piece of view state the scene is about. Applied by ``ChatShowcase``,
            // which the composer and the search field read on appearing.
            break
        case "threads":
            model.previewThreads()
        case "queued":
            model.previewThreads()
            model.previewQueued(in: model.threads[0].id)
        case "model":
            model.previewThreads()
            guard let thread = model.threads.first?.id else { return }
            model.previewChat(in: thread)
            model.previewModels(in: thread)
            // The Mac can open its own menus, so unlike the phone it needs no popover stand-in.
        case "tools":
            model.previewThreads()
            model.previewTools(in: model.threads[0].id)
        case "link":
            model.previewThreads()
            LinkPreviewStore.shared.preload(
                LinkPreview(
                    title: "Roast chicken with lemon and thyme",
                    host: "cooking.example.com",
                    icon: icon()
                ),
                for: URL(string: "https://cooking.example.com/roast-chicken")!
            )
            model.previewLink(in: model.threads[0].id)
        default:
            // The one scene whose thread is a draft rather than a synced one. Remembered, so
            // re-seeding on a later thread list does not leave a second empty draft behind —
            // a draft is not in the runtime's list and so is never the thing that got wiped.
            let draft = approvalDraft ?? model.newDraft().id
            approvalDraft = draft
            model.previewApproval(in: draft)
        }
        if let scene = launchArgument("yorozuScene") {
            model.previewChat(in: model.threads.first?.id ?? model.newDraft().id)
            switch scene {
            case "dictation":
                ChatShowcase.dictation = [0.2, 0.5, 0.8, 0.6, 0.9, 0.4, 0.7, 1.0, 0.5, 0.3, 0.6, 0.85]
            case "search":
                ChatShowcase.search = "invoice"
            case "reply":
                ChatShowcase.quote =
                    "The April invoice is still open: it was issued on the second and the terms on it are thirty days."
            default:
                break
            }
        }
    }

    /// A stand-in favicon, drawn rather than bundled: a screenshot should not need a real site's
    /// icon, and the app should not ship one. The phone's harness draws the same square.
    private static func icon() -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            ("C" as NSString).draw(
                at: NSPoint(x: 9, y: 5),
                withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 20),
                    .foregroundColor: NSColor.white,
                ]
            )
            return true
        }
        guard let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }
}

/// Prints the chat window's number, which is the id `screencapture -l` takes.
///
/// `scripts/mac-screens.sh` needs it and the alternatives are worse: an AppleScript `id of
/// window 1` needs scripting support this app does not have, and walking
/// `CGWindowListCopyWindowInfo` from outside needs Screen Recording for the shell as well as
/// for `screencapture`. The window knows its own number, so it says so.
///
/// Inert unless the app was launched to be screenshotted — see ``Showcase/active``.
struct WindowNumberReporter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Reporter() }

    func updateNSView(_ view: NSView, context: Context) {}

    /// Zero, explicitly. Left to itself a representable is measured by its view's `fittingSize`,
    /// and a bare `NSView` has no opinion about that — which SwiftUI reads as "as big as you
    /// like" and hands the whole window's content the result. That is a nineteen-hundred-point
    /// split view inside a five-hundred-point window, with everything below the fold clipped
    /// away and nothing to scroll it back. This reports what it actually occupies.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        .zero
    }

    private final class Reporter: NSView {
        private var reported = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard Showcase.active, !reported, let number = window?.windowNumber else { return }
            reported = true
            // Flushed like the other YOROZU-MAC lines: stdout is block-buffered whenever it is
            // not a terminal, and the harness kills the app rather than asking it to exit.
            print("YOROZU-MAC window=\(number)")
            fflush(stdout)
        }
    }
}
