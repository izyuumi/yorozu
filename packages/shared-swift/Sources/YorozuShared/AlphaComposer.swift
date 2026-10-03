#if os(macOS)
import AppKit
import SwiftUI

/// The main-chat shell reuses the Mac composer's input-method-aware key handling.
public struct AlphaComposer: View {
    @Binding private var text: String
    private let canSend: Bool
    private let canStop: Bool
    private let stopPending: Bool
    private let placeholder: String
    private let sendLabel: String
    private let stopLabel: String
    private let stopPendingLabel: String
    private let onSend: () -> Void
    private let onStop: () -> Void
    @FocusState private var focused: Bool

    public init(text: Binding<String>, canSend: Bool, canStop: Bool, stopPending: Bool,
                placeholder: String = "Message Yorozu…", sendLabel: String = "Send",
                stopLabel: String = "Stop", stopPendingLabel: String = "Stopping…",
                onSend: @escaping () -> Void, onStop: @escaping () -> Void) {
        _text = text
        self.canSend = canSend
        self.canStop = canStop
        self.stopPending = stopPending
        self.placeholder = placeholder
        self.sendLabel = sendLabel
        self.stopLabel = stopLabel
        self.stopPendingLabel = stopPendingLabel
        self.onSend = onSend
        self.onStop = onStop
    }

    private var sendButton: some View {
        Button(sendLabel, systemImage: "arrow.up", action: onSend)
            .disabled(!canSend)
            .accessibilityIdentifier("alpha-send")
            .buttonBorderShape(.circle)
            .labelStyle(.iconOnly)
            .help(sendLabel)
    }

    private var stopButton: some View {
        Button(stopLabel, systemImage: "stop.fill", action: onStop)
            .accessibilityIdentifier("alpha-stop")
            .buttonBorderShape(.circle)
            .labelStyle(.iconOnly)
            .help(stopLabel)
    }

    public var body: some View {
        VStack(alignment: .leading) {
            TextField(placeholder, text: $text, axis: .vertical)
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
                Spacer()
                if stopPending {
                    Label(stopPendingLabel, systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                } else if canStop {
                    if #available(macOS 26.0, *) {
                        stopButton.buttonStyle(.glass)
                    } else {
                        stopButton.buttonStyle(.bordered)
                    }
                }
                if #available(macOS 26.0, *) {
                    sendButton.buttonStyle(.glassProminent)
                } else {
                    sendButton.buttonStyle(.borderedProminent)
                }
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
