import SwiftUI
import UIKit

/// How a message is drawn, from the Mac's kind and notice (docs/ios-relay-contract.md, "Notice codes").
enum RowStyle {
    case user, answer, question, system, failure

    init(_ bubble: PhoneModel.Bubble) {
        if bubble.user {
            self = .user
        } else if bubble.kind == "question" || bubble.notice?.code.hasPrefix("question") == true {
            self = .question
        } else if bubble.failed {
            self = .failure
        } else if bubble.notice != nil {
            self = .system
        } else {
            self = .answer
        }
    }
}

extension PhoneModel.Bubble {
    /// A notice in the phone's language; any other message as stored.
    var shownText: String {
        notice.map { NoticeText.text(code: $0.code, params: $0.params, fallback: text) } ?? text
    }

    /// Raw error text of a failure notice, shown only under Details.
    var errorDetail: String? { notice?.params["error"].flatMap { $0.isEmpty ? nil : $0 } }

    /// What Copy and Share take: the answer only (never the reply header), plus a failure's details.
    var copyText: String { errorDetail.map { "\(shownText)\n\n\($0)" } ?? shownText }
}

/// Exact and per-day times in the phone's locale ("Today at 09:12", "今日 9:12").
@MainActor
enum MessageTime {
    static let day = formatter(time: .short)
    static let exact = formatter(time: .medium)

    static func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts) / 1000) }

    private static func formatter(time: DateFormatter.Style) -> DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = time
        f.doesRelativeDateFormatting = true
        return f
    }
}

// RENDERER: stand-in for the shared block renderer. Replace the body with `MarkdownBlocks(text)` once
// `Sources/ProjectXApp/ChatMarkdown.swift` provides it.
struct MessageMarkdown: View {
    let text: String

    var body: some View { Text(AttributedString(chatMarkdown: text)) }
}

/// One timeline row: the user's vermilion bubble, an answer or question card in the system's
/// grouped fill, or a compact system row for notices and failures. Long-press: Copy, Share, Show Details.
struct MessageRow: View {
    let bubble: PhoneModel.Bubble
    /// The message this one answers, when held: drawn as the reply header.
    let request: PhoneModel.Bubble?
    let onShowRequest: () -> Void
    let onShowDetails: () -> Void

    @State private var expanded = false

    private let bubbleRadius: CGFloat = 20
    private let cardRadius: CGFloat = 22
    private let quoteRadius: CGFloat = 10

    var body: some View {
        content
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = bubble.copyText }
                ShareLink(item: bubble.copyText)
                Button("Show Details", systemImage: "info.circle", action: onShowDetails)
            }
    }

    @ViewBuilder private var content: some View {
        switch RowStyle(bubble) {
        case .user: user
        case .answer: card { answer }
        case .question: card { question }
        case .system: system
        case .failure: failure
        }
    }

    private var user: some View {
        HStack(spacing: 0) {
            // A bubble stops short of the far edge, so its side says who spoke even when it is long.
            Spacer(minLength: LayoutMetrics.section * 2)
            VStack(alignment: .trailing, spacing: LayoutMetrics.tight) {
                Text(bubble.text)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .padding(.horizontal, LayoutMetrics.stack)
                    .padding(.vertical, LayoutMetrics.inner)
                    .background(YorozuPalette.bubble, in: RoundedRectangle(cornerRadius: bubbleRadius, style: .continuous))
                // Refused by the Mac: why, as it said.
                if bubble.failed {
                    Label { Text(bubble.reason ?? String(localized: "Failed")) } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(YorozuPalette.warning)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var answer: some View {
        if let request {
            Button(action: onShowRequest) {
                Label {
                    Text(verbatim: "“\(request.shownText.replacingOccurrences(of: "\n", with: " "))”")
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, LayoutMetrics.inner)
                .padding(.vertical, LayoutMetrics.tight)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: quoteRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show the request")
            .accessibilityValue(request.shownText)
        }
        MessageMarkdown(text: bubble.text)
    }

    @ViewBuilder private var question: some View {
        Label("Question", systemImage: "questionmark.bubble")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
        MessageMarkdown(text: bubble.shownText)
    }

    private func card(@ViewBuilder _ inner: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.inner) { inner() }
            .padding(.horizontal, LayoutMetrics.stack)
            .padding(.vertical, LayoutMetrics.stack)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }

    private var system: some View {
        Label { Text(bubble.shownText) } icon: { Image(systemName: "info.circle") }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, LayoutMetrics.inner)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Amber, not red: kept apart from the accent and from "Not delivered" (#314).
    private var failure: some View {
        Label {
            VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                Text(bubble.shownText)
                if let detail = bubble.errorDetail {
                    Button {
                        withAnimation { expanded.toggle() }
                    } label: {
                        HStack(spacing: LayoutMetrics.hair) {
                            Text("Details")
                            Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityValue(expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
                    if expanded {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(YorozuPalette.warning)
        }
        .font(.footnote)
        .padding(.horizontal, LayoutMetrics.inner)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Show Details: the message and its exact time. #314 adds delivery and read times.
struct MessageDetails: View {
    let bubble: PhoneModel.Bubble

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(bubble.shownText).lineLimit(6)
                }
                Section {
                    LabeledContent(bubble.user ? String(localized: "Sent") : String(localized: "Time"),
                                   value: MessageTime.exact.string(from: MessageTime.date(bubble.ts)))
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .yorozuTint()
    }
}
