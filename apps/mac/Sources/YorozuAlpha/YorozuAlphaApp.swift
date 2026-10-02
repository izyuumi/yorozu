import AppKit
import SwiftUI
import YorozuShared

@main
struct YorozuAlphaApp: App {
    @State private var model = AlphaChatModel(configuration: .launch())

    var body: some Scene {
        Window("Yorozu 0.6 — Internal Alpha", id: "main-chat") {
            AlphaChatView(model: model)
                .onAppear { NSApp.activate(ignoringOtherApps: true); model.reconnect() }
                .onDisappear { model.close() }
        }
        .defaultSize(width: 900, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Chat") {
                Button("Reconnect / 再接続") { model.reconnect() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Stop / 停止") { model.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.canStop)
            }
        }
    }
}

struct AlphaChatView: View {
    @Bindable var model: AlphaChatModel
    @State private var showsWorkspace = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                YorozuMark()
                VStack(alignment: .leading) {
                    Text("Yorozu / よろず").font(.headline)
                    Text("One continuous conversation / ひとつの会話").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.connecting ? "Connecting / 接続中" : model.ready ? "Connected / 接続済み" : "Disconnected / 未接続",
                    systemImage: model.ready ? "circle.fill" : "circle.dotted")
                    .font(.caption)
                    .foregroundStyle(model.ready ? YorozuPalette.sage : YorozuPalette.warning)
                Button("Reconnect / 再接続", systemImage: "arrow.clockwise") { model.reconnect() }
                    .disabled(model.connecting)
                    .accessibilityIdentifier("alpha-reconnect")
            }
            .padding()
            Divider()
            if let failure = model.transportFailure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(YorozuPalette.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("alpha-connection-failure")
            }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        if model.runs.isEmpty {
                            ContentUnavailableView("Start with Yorozu / よろずに依頼する", systemImage: "bubble.left.and.bubble.right",
                                description: Text("Ask for a small text file and checksum in the temporary workspace. / 一時作業フォルダに短いテキストファイルとチェックサムを作成できます。"))
                        }
                        ForEach(model.runs) { run in
                            MessageBubble(id: run.id, data: MessageData(role: .user, text: run.prompt))
                            AlphaTaskCard(run: run, disconnected: !model.ready && !run.terminal)
                            if !run.answer.isEmpty {
                                MessageBubble(id: "reply-\(run.id)", data: MessageData(role: .agent, text: run.answer,
                                    done: run.terminal, failed: run.kind == "failed", interrupted: run.kind == "stopped"),
                                    streaming: model.ready && !run.terminal, agentLabel: "Yorozu")
                            }
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }
                    .padding()
                }
                .onChange(of: model.events.last?.seq) { _, _ in scroll.scrollTo("latest", anchor: .bottom) }
                .onAppear { scroll.scrollTo("latest", anchor: .bottom) }
            }
            Divider()
            VStack(alignment: .leading) {
                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("alpha-notice")
                }
                if model.draft.utf8.count > 16000 {
                    Text("Message exceeds 16,000 UTF-8 bytes; shorten it / メッセージを短くしてください")
                        .font(.caption).foregroundStyle(YorozuPalette.warning)
                }
                AlphaComposer(text: $model.draft, canSend: model.canSend, canStop: model.canStop,
                    stopPending: model.stopPending, onSend: model.send, onStop: model.stop)
                HStack {
                    Text("Internal alpha · isolated temporary workspace / 内部アルファ版・一時フォルダ")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Workspace / 作業フォルダ", systemImage: "folder") { showsWorkspace.toggle() }
                        .disabled(model.workspace == nil)
                }
                if showsWorkspace, let workspace = model.workspace {
                    Text(workspace).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Open workspace in Finder / Finderで開く") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: workspace))
                    }
                }
            }
            .padding()
        }
        .background(YorozuPalette.canvas)
        .foregroundStyle(YorozuPalette.ink)
        .tint(YorozuPalette.vermilion)
    }
}

private struct AlphaTaskCard: View {
    let run: AlphaRun
    let disconnected: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                if !run.terminal && !disconnected { ProgressView().controlSize(.small) }
                else { Image(systemName: run.kind == "completed" ? "checkmark.circle" : "exclamationmark.circle") }
                Text(disconnected ? "Outcome unconfirmed / 結果未確認" : run.label).font(.subheadline.weight(.semibold))
                Spacer()
                Button(expanded ? "Less / 閉じる" : "Details / 詳細") { expanded.toggle() }
                    .font(.caption)
            }
            if run.kind == "stop_requested", !disconnected {
                Text("Waiting for worker cessation; the request alone does not confirm Stop. / ワーカー終了待ち。要求だけでは停止確認になりません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let detail = run.detail {
                Text(detail).font(.callout).textSelection(.enabled)
            }
            if expanded {
                Text("Task / タスク: \(run.id)").font(.caption.monospaced()).textSelection(.enabled)
                Text("Retained worker notifications / 保存された作業通知: \(run.activityCount)").font(.caption)
                Text("Verify files in the workspace before relying on the result. / 作業フォルダで成果物を確認してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(YorozuPalette.paper, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alpha-task-\(run.id)")
    }
}
