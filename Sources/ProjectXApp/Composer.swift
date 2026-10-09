import SwiftUI
import AppKit
import ProjectXCore

/// The message field, the send button, the key hint and the over-limit hint (approved design).
struct Composer: View {
    @ObservedObject var model: AppModel
    /// The tallest the field grows before it scrolls, from the popover's height.
    let maxHeight: CGFloat
    let send: () -> Void
    /// `Engine.send` takes 1–6,000 UTF-8 bytes.
    static let byteLimit = 6_000
    private enum Metrics { static let fieldRadius: CGFloat = 15, sendSide: CGFloat = 28 }
    var body: some View {
        let bytes = model.draft.utf8.count, enabled = model.runtimeMode.permitsInput(fixtureAcknowledged: model.fixtureAcknowledged)
        let canSend = model.ready && !model.submitting && enabled && bytes <= Self.byteLimit && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading,spacing: 6) {
            if bytes > Self.byteLimit {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(ChatPalette.warning).accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text("\(bytes.formatted()) bytes. The limit is \(Self.byteLimit.formatted()).").fontWeight(.semibold)
                        Text("Shorten it to send it.").foregroundStyle(.secondary)
                    }
                }.font(.callout).accessibilityElement(children: .combine)
            }
            HStack(alignment: .bottom,spacing: 6) {
                ComposerField(text: $model.draft,placeholder: model.runtimeMode == .fixture ? String(localized: "Synthetic test message, no AI") : String(localized: "Message Yorozu"),
                              enabled: enabled,maxHeight: maxHeight,sendKey: { [model] in model.sendKey },submit: { if canSend { send() }; return canSend })
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
        view.sendKey = sendKey; view.submit = submit
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
