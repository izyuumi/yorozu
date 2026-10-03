import AppKit
import SwiftUI
import YorozuShared

private enum AlphaLanguage: String, CaseIterable {
    case system, english, japanese

    var isJapanese: Bool {
        self == .japanese || (self == .system && Locale.preferredLanguages.first?.hasPrefix("ja") == true)
    }
    var locale: Locale { Locale(identifier: isJapanese ? "ja" : "en") }
    func text(_ english: String, _ japanese: String) -> String { isJapanese ? japanese : english }

    // Existing transport messages remain unchanged; only their presentation is localized.
    func message(_ bilingual: String) -> String {
        let parts = bilingual.components(separatedBy: " / ")
        return parts.count == 2 ? parts[isJapanese ? 1 : 0] : bilingual
    }
}

@main
struct YorozuAlphaApp: App {
    @State private var model = AlphaChatModel(configuration: .launch())
    @AppStorage("uiLanguage", store: UserDefaults(suiteName: "to.yumi.yorozu.alpha.internal"))
    private var language = AlphaLanguage.system

    var body: some Scene {
        Window("Yorozu", id: "main-chat") {
            AlphaChatView(model: model, language: language)
                .environment(\.locale, language.locale)
                .onAppear { NSApp.activate(ignoringOtherApps: true); model.reconnect() }
                .onDisappear { model.close() }
        }
        .defaultSize(width: 900, height: 700)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu(language.text("Chat", "チャット")) {
                Button(language.text("Reconnect", "再接続")) { model.reconnect() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(language.text("Stop", "停止")) { model.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.canStop)
            }
        }
        Settings {
            Form {
                Picker(language.text("Language", "言語"), selection: $language) {
                    Text(language.text("System", "システムに合わせる")).tag(AlphaLanguage.system)
                    Text("English").tag(AlphaLanguage.english)
                    Text("日本語").tag(AlphaLanguage.japanese)
                }
                .accessibilityIdentifier("alpha-language")
                Text(language.text("Applies immediately to the app interface.", "アプリの表示にすぐ反映されます。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle(language.text("Settings", "設定"))
            .environment(\.locale, language.locale)
        }
        .defaultSize(width: 420, height: 200)
    }
}

private struct AlphaChatView: View {
    @Bindable var model: AlphaChatModel
    let language: AlphaLanguage

    // A typographic reading measure scales with the native body font, not a window-size guess.
    private var readingWidth: CGFloat {
        (String(repeating: "0", count: 88) as NSString)
            .size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .body)]).width
    }
    private var connectionLabel: String {
        if model.connecting { return language.text("Connecting…", "接続中…") }
        return model.ready ? language.text("Connected", "接続済み") : language.text("Disconnected", "未接続")
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.runs.isEmpty {
                VStack(spacing: LayoutMetrics.stack) {
                    YorozuMark(dimension: 48).accessibilityHidden(true)
                    Text(language.text("What can I help you with?", "今日は何をお手伝いしましょうか？"))
                        .font(.title2.weight(.medium))
                    Text(language.text("A place to think, write, and get things done.", "考えること、書くこと、日々の仕事を一緒に。"))
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                            ForEach(model.runs) { run in
                                MessageBubble(id: run.id, data: MessageData(role: .user, text: run.prompt))
                                AlphaTaskStatus(run: run, disconnected: !model.ready && !run.terminal, language: language)
                                if !run.answer.isEmpty {
                                    MessageBubble(id: "reply-\(run.id)", data: MessageData(role: .agent, text: run.answer,
                                        done: run.terminal, failed: run.kind == "failed", interrupted: run.kind == "stopped"),
                                        streaming: model.ready && !run.terminal, agentLabel: "Yorozu")
                                }
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }
                        .frame(maxWidth: readingWidth)
                        .padding()
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: model.events.last?.seq) { _, _ in scroll.scrollTo("latest", anchor: .bottom) }
                    .onAppear { scroll.scrollTo("latest", anchor: .bottom) }
                }
            }
            VStack(alignment: .leading) {
                if let failure = model.transportFailure {
                    Label(language.message(failure), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(YorozuPalette.warning)
                        .accessibilityIdentifier("alpha-connection-failure")
                } else if let notice = model.notice {
                    Text(language.message(notice)).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("alpha-notice")
                }
                if model.draft.utf8.count > 16000 {
                    Text(language.text("This message is too long. Please shorten it.", "メッセージが長すぎます。短くしてください。"))
                        .font(.caption).foregroundStyle(YorozuPalette.warning)
                }
                AlphaComposer(text: $model.draft, canSend: model.canSend, canStop: model.canStop,
                    stopPending: model.stopPending,
                    placeholder: language.text("Message Yorozu…", "Yorozuにメッセージ…"),
                    sendLabel: language.text("Send", "送信"), stopLabel: language.text("Stop", "停止"),
                    stopPendingLabel: language.text("Stopping…", "停止処理中…"),
                    onSend: model.send, onStop: model.stop)
            }
            .frame(maxWidth: readingWidth)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(YorozuPalette.canvas)
        .foregroundStyle(YorozuPalette.ink)
        .tint(YorozuPalette.vermilion)
        .navigationTitle("Yorozu")
        .toolbar {
            ToolbarItem {
                Label(connectionLabel, systemImage: model.ready ? "checkmark.circle" : "circle.dotted")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            ToolbarItem {
                Button(language.text("Reconnect", "再接続"), systemImage: "arrow.clockwise") { model.reconnect() }
                    .disabled(model.connecting)
                    .help(language.text("Reconnect", "再接続"))
                    .accessibilityIdentifier("alpha-reconnect")
            }
            ToolbarItem {
                Menu(language.text("More", "その他"), systemImage: "ellipsis") {
                    Button(language.text("Open workspace", "作業フォルダを開く"), systemImage: "folder") {
                        if let workspace = model.workspace { NSWorkspace.shared.open(URL(fileURLWithPath: workspace)) }
                    }
                    .disabled(model.workspace == nil)
                    Divider()
                    SettingsLink { Label(language.text("Settings…", "設定…"), systemImage: "gearshape") }
                }
                .help(language.text("More", "その他"))
                .accessibilityIdentifier("alpha-more")
            }
        }
    }
}

private struct AlphaTaskStatus: View {
    let run: AlphaRun
    let disconnected: Bool
    let language: AlphaLanguage
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading) {
                if let model = run.model { Text(language.text("Model: ", "モデル: ") + model) }
                if let detail = run.detail { Text(language.message(detail)).textSelection(.enabled) }
                Text(language.text("Task: ", "タスク: ") + run.id).font(.caption.monospaced()).textSelection(.enabled)
                Text(language.text("Worker updates: ", "作業の更新: ") + String(run.activityCount))
                if run.kind == "stop_requested", !disconnected {
                    Text(language.text("Waiting for the worker to stop.", "ワーカーの停止を確認しています。"))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.vertical, LayoutMetrics.tight)
        } label: {
            HStack {
                if !run.terminal && !disconnected { ProgressView().controlSize(.mini) }
                else { Image(systemName: run.kind == "completed" ? "checkmark.circle" : "exclamationmark.circle") }
                Text(disconnected ? language.text("Outcome unconfirmed", "結果未確認") : language.message(run.label))
                if let model = run.model { Text("· \(model)").foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("alpha-task-\(run.id)")
    }
}
