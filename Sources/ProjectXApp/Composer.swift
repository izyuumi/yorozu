import SwiftUI
import AppKit
import ProjectXCore
import UniformTypeIdentifiers

/// The message field, the attach and send buttons, the key hint, the composer's files and the over-limit hint (approved design).
struct Composer: View {
    @ObservedObject var model: AppModel
    /// The tallest the field grows before it scrolls, from the popover's height; the file list shares it.
    let maxHeight: CGFloat
    let send: () -> Void
    /// `Engine.send` takes up to 6,000 UTF-8 bytes (none when files are attached).
    static let byteLimit = 6_000
    private enum Metrics { static let fieldRadius: CGFloat = 15, sendSide: CGFloat = 28, buttonRadius: CGFloat = 7 }
    var body: some View {
        // Blocked (#317): nothing could answer, so the field and Send are off and the reason shows with Fix….
        let blocked = model.readiness.flatMap { $0.state == .blocked ? $0.problem : nil }
        let bytes = model.draft.utf8.count, enabled = model.runtimeMode.permitsInput(fixtureAcknowledged: model.fixtureAcknowledged) && blocked == nil
        let hasContent = !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.files.isEmpty
        let canSend = model.ready && !model.submitting && enabled && bytes <= Self.byteLimit && hasContent && model.files.count <= DraftFile.countLimit
        VStack(alignment: .leading,spacing: 6) {
            if let blocked {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityHidden(true)
                    Text(verbatim: blocked.title).frame(maxWidth: .infinity,alignment: .leading).help(blocked.detail.isEmpty ? blocked.title : blocked.detail)
                    FixButton(model: model,fix: blocked.fix).controlSize(.small)
                }.font(.callout)
            }
            if bytes > Self.byteLimit {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(ChatPalette.warning).accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text("\(bytes.formatted()) bytes. The limit is \(Self.byteLimit.formatted()).").fontWeight(.semibold)
                        Text("Shorten it, or send it as a text file.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity,alignment: .leading).accessibilityElement(children: .combine)
                    Button { model.draftToTextFile() } label: { Label("Send as Text File",systemImage: "doc.text") }
                        .controlSize(.small).disabled(!enabled)
                }.font(.callout)
            }
            if let notice = model.fileNotice {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(ChatPalette.warning).accessibilityHidden(true)
                    Text(notice).frame(maxWidth: .infinity,alignment: .leading)
                    Button { model.fileNotice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
                }.font(.callout)
            }
            if !model.files.isEmpty {
                let rows = VStack(spacing: 4) {
                    ForEach($model.files) { $file in
                        DraftFileRow(file: file,sendOriginal: $file.sendOriginal) { model.removeFile(file.id) }
                    }
                }
                ViewThatFits(in: .vertical) { rows; ScrollView { rows } }.frame(maxHeight: maxHeight)
            }
            HStack(alignment: .bottom,spacing: 6) {
                Button { model.pickFiles() } label: {
                    Image(systemName: "paperclip").fontWeight(.semibold).frame(width: Metrics.sendSide,height: Metrics.sendSide).contentShape(Circle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(!enabled).help("Attach files").accessibilityLabel("Attach files")
                ComposerField(text: $model.draft,placeholder: model.runtimeMode == .fixture ? String(localized: "Synthetic test message, no AI") : String(localized: "Message Yorozu"),
                              enabled: enabled,maxHeight: maxHeight,sendKey: { [model] in model.sendKey },submit: { if canSend { send() }; return canSend },
                              take: { [model] board in enabled && model.attach(from: board) })
                    .padding(.horizontal,12).padding(.vertical,6)
                    .background(.background,in: RoundedRectangle(cornerRadius: Metrics.fieldRadius,style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Metrics.fieldRadius,style: .continuous).strokeBorder(.separator,lineWidth: 0.5) }
                Button(action: send) {
                    Image(systemName: "arrow.up").fontWeight(.bold).frame(width: Metrics.sendSide,height: Metrics.sendSide)
                        .background(canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),in: Circle())
                        .foregroundStyle(canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }.buttonStyle(.plain).disabled(!canSend).help(model.runtimeMode.sendLabel).accessibilityLabel(model.runtimeMode.sendLabel)
            }
            Text(model.sendKey == .cmdEnter || model.draft.contains("\n") ? String(localized: "⌘↩ to send · ↩ for a new line") : String(localized: "↩ to send · ⇧↩ for a new line"))
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity,alignment: .trailing).padding(.trailing,Metrics.sendSide + 6)
        }
        .padding(.horizontal,10).padding(.vertical,8)
    }
}

/// An `NSTextView` message field. Smart Enter: Return sends while the draft is one line; once it has a newline, Return
/// adds lines and ⌘Return sends. `send_key = "cmd-enter"` makes Return always a new line. Never sends while an input
/// method is composing (that Return confirms the conversion). Grows with its text up to `maxHeight`, then scrolls.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let enabled: Bool
    let maxHeight: CGFloat
    let sendKey: () -> Config.SendKey
    /// Returns whether the message went; an Enter that sends nothing is swallowed.
    let submit: () -> Bool
    /// A paste or drop with files or image data: returns whether it became an attachment (else the text view takes it).
    let take: (NSPasteboard) -> Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body); view.textColor = .labelColor
        view.drawsBackground = false; view.isRichText = false; view.allowsUndo = true
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = .width
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel(placeholder)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView,context: Context) {
        guard let view = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.text = $text
        view.sendKey = sendKey; view.submit = submit; view.take = take
        if view.string != text, !view.hasMarkedText() { view.string = text; view.needsDisplay = true }
        if view.placeholder != placeholder { view.placeholder = placeholder; view.setAccessibilityLabel(placeholder); view.needsDisplay = true }
        view.isEditable = enabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize,nsView scroll: NSScrollView,context: Context) -> CGSize? {
        guard let width = proposal.width, let view = scroll.documentView as? ComposerTextView,
              let layout = view.layoutManager, let container = view.textContainer, let font = view.font else { return nil }
        container.containerSize = NSSize(width: width,height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: font)
        let height = max(layout.usedRect(for: container).height,line)
        return CGSize(width: width,height: min(height,max(line,maxHeight)).rounded(.up))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

final class ComposerTextView: NSTextView {
    var placeholder = ""
    var sendKey: () -> Config.SendKey = { .smart }
    var submit: () -> Bool = { false }
    var take: (NSPasteboard) -> Bool = { _ in false }
    private var keyObserver: NSObjectProtocol?

    override func keyDown(with event: NSEvent) {
        // Return (36) or the keypad's Enter (76), outside an input method's composition.
        guard event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad,.function,.capsLock])
        let enterSends = sendKey() == .smart && !string.contains("\n")
        if modifiers == .command || (modifiers.isEmpty && enterSends) { _ = submit(); return }
        if modifiers == .shift { return insertNewline(nil) }
        super.keyDown(with: event)
    }

    // Files and images pasted or dropped onto the field attach instead of inserting a path (#316).
    override func paste(_ sender: Any?) { if !take(.general) { super.paste(sender) } }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { take(sender.draggingPasteboard) || super.performDragOperation(sender) }
    /// A plain-text view disables Paste for a pasteboard holding only an image; attaching makes it useful.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, NSPasteboard.general.canReadItem(withDataConformingToTypes: [UTType.fileURL.identifier,UTType.image.identifier]) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func didChangeText() { super.didChangeText(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        NSAttributedString(string: placeholder,attributes: [.font: font ?? .preferredFont(forTextStyle: .body),.foregroundColor: NSColor.placeholderTextColor])
            .draw(at: NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),y: textContainerOrigin.y))
    }

    /// Takes the keyboard whenever the popover opens with nothing else focused, so typing goes straight in.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,object: window,queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusIfIdle() }
        }
        focusIfIdle()
    }
    private func focusIfIdle() {
        guard let window, window.firstResponder === window || window.firstResponder == nil else { return }
        window.makeFirstResponder(self)
    }
}
