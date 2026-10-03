import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Opt-in presentation only. The host owns this thread and all of its persisted state.
public enum SecretaryUI {
    public static var enabled: Bool { Bundle.main.infoDictionary?["YorozuSecretaryEnabled"] as? Bool == true }
    public static let threadID = "yorozu-secretary-v1"
    public static let languageKey = "secretaryInterfaceLanguage"
}

public enum SecretaryLanguage: String, CaseIterable {
    case system, english, japanese

    public var locale: Locale {
        switch self {
        case .system: Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
        case .english: Locale(identifier: "en")
        case .japanese: Locale(identifier: "ja")
        }
    }
}

/// A separate preference leaves the system language and existing app preferences intact.
public struct SecretaryLocale: ViewModifier {
    @AppStorage(SecretaryUI.languageKey) private var language = SecretaryLanguage.system
    public init() {}
    public func body(content: Content) -> some View {
        if SecretaryUI.enabled { content.environment(\.locale, language.locale) }
        else { content }
    }
}

private struct SecretaryPresentationKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var secretaryPresentation: Bool {
        get { self[SecretaryPresentationKey.self] }
        set { self[SecretaryPresentationKey.self] = newValue }
    }
}

struct SecretaryGreeting: View {
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(spacing: LayoutMetrics.stack) {
            YorozuMark(dimension: 48).accessibilityHidden(true)
            Text(locale.secretaryText("What can I help you with?", "今日は何をお手伝いしましょうか？"))
                .font(.title2.weight(.medium))
            Text(locale.secretaryText("A place to think, write, and get things done.", "考えること、書くこと、日々の仕事を一緒に。"))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Locale {
    func secretaryText(_ english: String, _ japanese: String) -> String {
        language.languageCode?.identifier == "ja" ? japanese : english
    }
}

/// Uses the same ChatView as History: drafts, attachments, approvals and Stop retain
/// their production behavior. A missing host-created thread never becomes a new draft.
public struct SecretaryChatView: View {
    public let model: ChatModel
    private let hostLabel: String?
    private let onHistory: () -> Void
    @Environment(\.locale) private var locale
    @AppStorage(SecretaryUI.languageKey) private var language = SecretaryLanguage.system

    public init(model: ChatModel, hostLabel: String? = nil, onHistory: @escaping () -> Void) {
        self.model = model
        self.hostLabel = hostLabel
        self.onHistory = onHistory
    }

    private var thread: ThreadSummary? { model.threads.first { $0.id == SecretaryUI.threadID } }
    private var connected: Bool { model.link.state == .connected }
    private var connectionLabel: String {
        connected ? locale.secretaryText("Connected", "接続済み")
            : model.state == .closed ? locale.secretaryText("Disconnected", "未接続")
            : locale.secretaryText("Connecting…", "接続中…")
    }
    private var historyPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        .topBarLeading
        #endif
    }

    public var body: some View {
        Group {
            if let thread {
                ChatView(model: model, thread: thread)
                    .environment(\.secretaryPresentation, true)
                    .modifier(SecretaryColumn())
                    .id(thread.id)
            } else {
                ContentUnavailableView {
                    Label("Yorozu", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(locale.secretaryText("Waiting for your host to prepare Yorozu. Your saved chats are available in History.",
                        "ホストがYorozuを準備するまでお待ちください。保存済みのチャットは履歴から開けます。"))
                }
            }
        }
        .background(YorozuPalette.canvas)
        .navigationTitle("Yorozu")
        .toolbar {
            ToolbarItem(placement: historyPlacement) {
                Button(locale.secretaryText("History", "履歴"), systemImage: "clock.arrow.circlepath", action: onHistory)
                    .accessibilityIdentifier("secretary-history")
            }
            ToolbarItem {
                Label(connectionLabel, systemImage: connected ? "checkmark.circle" : "circle.dotted")
                    .font(.callout).foregroundStyle(.secondary)
                    .help(hostLabel.map { "\($0) · \(connectionLabel)" } ?? connectionLabel)
            }
            ToolbarItem {
                Menu(locale.secretaryText("More", "その他"), systemImage: "ellipsis") {
                    if let hostLabel { Text(hostLabel) }
                    Button(locale.secretaryText("Reconnect", "再接続"), systemImage: "arrow.clockwise") { model.reconnect() }
                    Picker(locale.secretaryText("Language", "言語"), selection: $language) {
                        Text(locale.secretaryText("System", "システムに合わせる")).tag(SecretaryLanguage.system)
                        Text(verbatim: "English").tag(SecretaryLanguage.english)
                        Text(verbatim: "日本語").tag(SecretaryLanguage.japanese)
                    }
                }
                .accessibilityIdentifier("secretary-more")
            }
        }
        .onChange(of: model.listed, initial: true) { _, _ in selectThread() }
        .onChange(of: thread?.id) { _, _ in selectThread() }
        .onDisappear {
            if model.openThread == SecretaryUI.threadID { model.openThread = nil }
            Task { await model.flushCache() }
        }
    }

    private func selectThread() {
        guard model.listed, thread != nil else { return }
        model.openThread = SecretaryUI.threadID
    }
}

/// The reference's reading measure follows the native body font on both platforms.
private struct SecretaryColumn: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var width: CGFloat {
        #if os(macOS)
        let font = NSFont.preferredFont(forTextStyle: .body)
        #else
        let font = UIFont.preferredFont(forTextStyle: .body)
        #endif
        return (String(repeating: "0", count: 88) as NSString).size(withAttributes: [.font: font]).width
    }
    func body(content: Content) -> some View {
        content.frame(maxWidth: width).frame(maxWidth: .infinity)
    }
}
