import SwiftUI
import YorozuWire

/// The one conversation: the Mac's main chat, a working indicator while it has a turn running,
/// and the composer.
struct ChatScreen: View {
    @Bindable var model: PhoneModel
    let onRepair: () -> Void

    @State private var settings = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                        ForEach(model.bubbles) { BubbleRow(bubble: $0).id($0.id) }
                        if model.working {
                            ProgressView().accessibilityLabel("Working…")
                        }
                    }
                    .padding(LayoutMetrics.gutter)
                    // Prose stops at a reading width; a no-op on a phone.
                    .frame(maxWidth: LayoutMetrics.readingWidth)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.bubbles.last?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    // Words as well as the dot, so the state is never told by colour alone.
                    if model.status != .connected {
                        Text(model.status.label)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let sendError = model.sendError {
                        Label { Text(sendError) } icon: {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        }
                        .font(.footnote)
                        .padding(.horizontal, LayoutMetrics.gutter)
                    }
                    Composer(text: $model.draft, working: model.working, enabled: model.canSend) {
                        Task { await model.send() }
                    }
                }
                .background(YorozuPalette.canvas.ignoresSafeArea(edges: .bottom))
            }
            .background(YorozuPalette.canvas.ignoresSafeArea())
            .navigationTitle("Yorozu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: Self.dot, height: Self.dot)
                        .accessibilityElement()
                        .accessibilityLabel(model.status.label)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { settings = true }
                }
            }
            .sheet(isPresented: $settings) {
                SettingsSheet(model: model) {
                    settings = false
                    onRepair()
                }
            }
        }
        .yorozuTint()
    }

    private static let dot: CGFloat = 8

    private var dotColor: Color {
        switch model.status {
        case .connected: YorozuPalette.sage
        case .hostOffline: YorozuPalette.warning
        case .failed: YorozuPalette.vermilion
        case .connecting, .offline: Color.secondary
        }
    }
}

/// The user's message as typed, in a vermilion bubble on the right; the Mac's as rendered Markdown.
private struct BubbleRow: View {
    let bubble: PhoneModel.Bubble

    var body: some View {
        HStack(spacing: 0) {
            // A bubble stops short of the far edge, so its side says who spoke even when it is long.
            if bubble.user { Spacer(minLength: LayoutMetrics.section * 2) }
            VStack(alignment: bubble.user ? .trailing : .leading, spacing: LayoutMetrics.tight) {
                Text(bubble.user ? AttributedString(bubble.text) : AttributedString(chatMarkdown: bubble.text))
                    .textSelection(.enabled)
                    .foregroundStyle(bubble.user ? Color.white : YorozuPalette.ink)
                    .tint(bubble.user ? Color.white : YorozuPalette.vermilion)
                    .padding(.horizontal, bubble.user ? LayoutMetrics.stack : 0)
                    .padding(.vertical, bubble.user ? LayoutMetrics.inner : 0)
                    .background(bubble.user ? YorozuPalette.vermilion : Color.clear,
                                in: RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous))
                if bubble.failed {
                    Label { Text(bubble.reason ?? String(localized: "Failed")) } icon: {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            if !bubble.user { Spacer(minLength: 0) }
        }
    }
}

/// Status, Repair, Remove and the version.
private struct SettingsSheet: View {
    let model: PhoneModel
    let onRepair: () -> Void

    @State private var removing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Status", value: model.status.label)
                    if let hostName = model.hostName { LabeledContent("Mac", value: hostName) }
                    if let failure = model.failure {
                        Text(failure).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Repair connection", action: onRepair)
                    Button("Remove host", role: .destructive) { removing = true }
                }
                Section {
                    LabeledContent("Version", value: Self.version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Remove host?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove host", role: .destructive) {
                    model.remove()
                    dismiss()
                }
            }
        }
        .yorozuTint()
    }

    private static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()
}
