#if os(macOS)
import AppKit
import SwiftUI

/// The main-chat shell reuses the Mac composer's input-method-aware key handling.
public struct AlphaComposer: View {
    @Binding private var text: String
    private let canSend: Bool
    private let canStop: Bool
    private let stopPending: Bool
    private let onSend: () -> Void
    private let onStop: () -> Void
    @FocusState private var focused: Bool

    public init(text: Binding<String>, canSend: Bool, canStop: Bool, stopPending: Bool,
                onSend: @escaping () -> Void, onStop: @escaping () -> Void) {
        _text = text
        self.canSend = canSend
        self.canStop = canStop
        self.stopPending = stopPending
        self.onSend = onSend
        self.onStop = onStop
    }

    public var body: some View {
        VStack(alignment: .leading) {
            TextField("Message Yorozu / よろずにメッセージ", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { text += "\n" }
                .accessibilityIdentifier("alpha-composer")
                .background(ComposerKeyMonitor(isActive: focused, sendModifiers: [],
                    onSend: { _ in
                        guard canSend else { return false }
                        onSend()
                        return true
                    }, onSendNextQueued: { false }, onPaste: nil, onPickerKey: nil,
                    onQuestionOption: { _ in false }, onPromptHistory: { _ in false }))
            HStack {
                Label("Text only in this alpha / このアルファ版はテキストのみ", systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if stopPending {
                    Label("Stop requested / 停止要求済み", systemImage: "hourglass")
                        .font(.caption)
                } else if canStop {
                    Button("Stop / 停止", systemImage: "stop.fill", action: onStop)
                        .accessibilityIdentifier("alpha-stop")
                }
                Button("Send / 送信", systemImage: "arrow.up", action: onSend)
                    .disabled(!canSend)
                    .accessibilityIdentifier("alpha-send")
                    .tint(YorozuPalette.vermilion)
            }
        }
        .padding()
        .background(YorozuPalette.paper, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius)
            .strokeBorder(YorozuPalette.rule))
        .onAppear { focused = true }
    }
}
#endif
