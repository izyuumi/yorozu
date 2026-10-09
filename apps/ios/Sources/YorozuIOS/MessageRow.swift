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
        } else if bubble.notice != nil || ["acknowledgment", "memory_receipt", "approval_request"].contains(bubble.kind ?? "") {
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

    /// Raw text of a notice (an error, a config problem, skipped files), shown only under Details.
    var errorDetail: String? { notice.flatMap { NoticeText.details($0.params) } }

    /// What Copy and Share take: the answer only (never the reply header), plus a failure's details.
    var copyText: String { errorDetail.map { "\(shownText)\n\n\($0)" } ?? shownText }
}

/// Exact and per-day times in the phone's locale ("Today at 09:12", "今日 9:12").
@MainActor
enum MessageTime {
    static let day = formatter(time: .short)
    static let exact = formatter(time: .medium)

    static func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts) / 1000) }

    /// The delay line's times: the time today, with the date on any other day (as on the Mac).
    static func short(_ ts: Int) -> String {
        let date = date(ts)
        return date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    private static func formatter(time: DateFormatter.Style) -> DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = time
        f.doesRelativeDateFormatting = true
        return f
    }
}

/// The quoted line above an answer: the request, which scrolls to it, or, when the request is not on the phone (a
/// job run's trigger stays on the Mac), the topic's label, which for a job is its name, as plain text.
struct ReplyHeader {
    let text: String
    let revealable: Bool
}

/// One timeline row: the user's vermilion bubble, an answer or question card in the system's
/// grouped fill, or a compact system row for notices and failures. Long-press: Copy, Share, Show Details.
struct MessageRow: View {
    let bubble: PhoneModel.Bubble
    /// The reply header: the message this one answers, or a job's name.
    let header: ReplyHeader?
    /// A user message's mark (#314).
    var delivery: Delivery?
    let onShowRequest: () -> Void
    let onShowDetails: () -> Void
    var onResend: () -> Void = {}
    var onDelete: () -> Void = {}

    @State private var expanded = false
    @State private var markDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                if let delivery { mark(delivery) }
            }
            // One element: "You: <text>", the status word as its value, the mark's choices as actions.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("You: \(bubble.text)"))
            .accessibilityValue(delivery?.word ?? "")
            .modifier(MarkActions(delivery: delivery, onDetails: { markDetails = true }, onResend: onResend, onDelete: onDelete))
        }
    }

    /// The mark under the bubble: icon only, in the text colour (red when not delivered). Tap for details.
    private func mark(_ delivery: Delivery) -> some View {
        Button { markDetails = true } label: {
            Image(systemName: delivery.symbol)
                .symbolEffect(.rotate, isActive: delivery.inFlight && !reduceMotion)
                .foregroundStyle(delivery.state == .notDelivered ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .font(.caption)
                .padding(.vertical, LayoutMetrics.hair)
                .padding(.leading, LayoutMetrics.inner)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $markDetails) {
            VStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                DeliveryRows(delivery: delivery, onResend: onResend, onDelete: onDelete)
            }
            .padding(LayoutMetrics.gutter)
            .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder private var answer: some View {
        if let header {
            let quote = Label {
                Text(verbatim: "“\(header.text.replacingOccurrences(of: "\n", with: " "))”")
                    .lineLimit(1)
            } icon: {
                Image(systemName: "arrowshape.turn.up.left")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, LayoutMetrics.inner)
            .padding(.vertical, LayoutMetrics.tight)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: quoteRadius, style: .continuous))
            if header.revealable {
                Button(action: onShowRequest) { quote }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show the request")
                    .accessibilityValue(header.text)
            } else {
                quote.accessibilityLabel(Text("In reply to \(header.text)"))
            }
        }
        MarkdownBlocks(bubble.text)
    }

    @ViewBuilder private var question: some View {
        Label("Question", systemImage: "questionmark.bubble")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
        MarkdownBlocks(bubble.shownText)
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

/// VoiceOver's actions on a user bubble: Details, plus Resend and Delete when it was not delivered.
private struct MarkActions: ViewModifier {
    let delivery: Delivery?
    let onDetails: () -> Void
    let onResend: () -> Void
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        if let delivery {
            if delivery.state == .notDelivered {
                content
                    .accessibilityAction(named: Text("Details"), onDetails)
                    .accessibilityAction(named: Text("Resend"), onResend)
                    .accessibilityAction(named: Text("Delete"), onDelete)
            } else {
                content.accessibilityAction(named: Text("Details"), onDetails)
            }
        } else {
            content
        }
    }
}

/// A user message's states with their times, and Resend / Delete when it was not delivered: the
/// mark's popover and the Details sheet.
struct DeliveryRows: View {
    let delivery: Delivery
    let onResend: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if delivery.state == .sending {
            Label(delivery.word, systemImage: delivery.symbol).foregroundStyle(.secondary)
        }
        row("Sent", delivery.sentAt)
        if let delivered = delivery.deliveredAt {
            row("Delivered", delivered)
            if let expires = delivery.expiresAt {
                Text("Held by the relay until your Mac is online · expires \(MessageTime.exact.string(from: MessageTime.date(expires)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let received = delivery.receivedAt {
            row("Received by Mac", received)
        }
        if let read = delivery.readAt { row("Read", read) }
        if delivery.delayed, let received = delivery.receivedAt {
            Text("Sent \(MessageTime.short(delivery.sentAt)) · delivered \(MessageTime.short(received))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if delivery.state == .notDelivered {
            Label { Text(delivery.notDelivered) } icon: {
                Image(systemName: delivery.symbol).foregroundStyle(.red)
            }
            Button("Resend", systemImage: "arrow.clockwise") {
                onResend()
                dismiss()
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                onDelete()
                dismiss()
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ ts: Int) -> some View {
        LabeledContent(title, value: MessageTime.exact.string(from: MessageTime.date(ts)))
    }
}

/// Show Details: the message and its exact time; a user message's states, times and choices.
struct MessageDetails: View {
    let bubble: PhoneModel.Bubble
    var delivery: Delivery?
    var onResend: () -> Void = {}
    var onDelete: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(bubble.shownText).lineLimit(6)
                }
                Section {
                    if let delivery {
                        DeliveryRows(delivery: delivery, onResend: onResend, onDelete: onDelete)
                    } else {
                        LabeledContent(bubble.user ? String(localized: "Sent") : String(localized: "Time"),
                                       value: MessageTime.exact.string(from: MessageTime.date(bubble.ts)))
                    }
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
