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
        } else if bubble.notice != nil || ["acknowledgment", "memory_receipt", "approval_request", "job_note"].contains(bubble.kind ?? "") {
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
/// grouped fill, or a compact system row for notices and failures. Long-press: Reply, Copy, Share, Select Text, Show Details;
/// a left-to-right swipe also replies.
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
    /// Starts a reply to this message; nil where replying is not offered.
    var onReply: (() -> Void)?

    @State private var expanded = false
    @State private var markDetails = false
    @State private var selecting = false
    /// The row's horizontal pull while a reply swipe runs.
    @State private var pull: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bubbleRadius: CGFloat = 20
    private let cardRadius: CGFloat = 22
    private let quoteRadius: CGFloat = 10
    /// How far a swipe must pull the row to reply, and the most it moves.
    private let replyThreshold: CGFloat = 64
    private let maxPull: CGFloat = 88

    var body: some View {
        content
            .contextMenu {
                if let onReply { Button("Reply", systemImage: "arrowshape.turn.up.left", action: onReply) }
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = bubble.copyText }
                ShareLink(item: bubble.copyText)
                Button("Select Text", systemImage: "selection.pin.in.out") { selecting = true }
                Button("Show Details", systemImage: "info.circle", action: onShowDetails)
            }
            .modifier(ReplySwipe(enabled: onReply != nil, pull: $pull,
                                 threshold: replyThreshold, maxPull: maxPull, reduceMotion: reduceMotion) { onReply?() })
            .accessibilityActions {
                if let onReply { Button("Reply", action: onReply) }
            }
            .sheet(isPresented: $selecting) { SelectTextSheet(text: bubble.copyText) }
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
                // A reply: the quoted message it answers, as on a result.
                if let header { quote(header) }
                // Files above the text, each its own element: they open on tap.
                if !bubble.files.isEmpty { AttachmentsView(files: bubble.files) }
                VStack(alignment: .trailing, spacing: LayoutMetrics.tight) {
                    if !bubble.text.isEmpty {
                        Text(bubble.text)
                            .foregroundStyle(.white)
                            .tint(.white)
                            .padding(.horizontal, LayoutMetrics.stack)
                            .padding(.vertical, LayoutMetrics.inner)
                            .background(YorozuPalette.bubble, in: RoundedRectangle(cornerRadius: bubbleRadius, style: .continuous))
                    }
                    if let delivery { mark(delivery) }
                }
                // One element: "You: <text>", the status word as its value, the mark's choices as actions.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(bubble.text.isEmpty ? Text("You sent ^[\(bubble.files.count) file](inflect: true)") : Text("You: \(bubble.text)"))
                .accessibilityValue(delivery?.word ?? "")
                .modifier(MarkActions(delivery: delivery, onDetails: { markDetails = true }, onResend: onResend, onDelete: onDelete))
            }
        }
    }

    /// The mark under the bubble: icon only, in the text colour (red when not delivered). Tap for details.
    private func mark(_ delivery: Delivery) -> some View {
        Button { markDetails = true } label: {
            DeliveryMark(delivery: delivery)
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
        if let header { quote(header) }
        MarkdownBlocks(bubble.text)
        if !bubble.files.isEmpty { AttachmentsView(files: bubble.files) }
    }

    /// The reply header: the quoted first line of the message this one answers, which scrolls to it when held.
    @ViewBuilder private func quote(_ header: ReplyHeader) -> some View {
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
                .accessibilityLabel(bubble.user ? Text("Show the original message") : Text("Show the request"))
                .accessibilityValue(header.text)
        } else {
            quote.accessibilityLabel(Text("In reply to \(header.text)"))
        }
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

/// The mark under a user bubble, Signal-style: one dotted circle while Sending, one check circle once the relay has it
/// (Sent), two overlapping check circles once the host has it (Delivered), two filled ones once read (Read), and the
/// failure symbol in red. A custom component: it owns the overlap; its size follows the caption font.
struct DeliveryMark: View {
    let delivery: Delivery

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    /// A little over half a caption-sized circle: the two circles overlap by about 58%.
    @ScaledMetric(relativeTo: .caption) private var overlap: CGFloat = 7

    var body: some View {
        Group {
            switch delivery.step {
            case .sending:
                Image(systemName: "circle.dotted")
                    .symbolEffect(.rotate, isActive: delivery.inFlight && !reduceMotion)
            case .sent:
                Image(systemName: "checkmark.circle")
            case .delivered:
                pair("checkmark.circle")
            case .read:
                pair("checkmark.circle.fill")
            case .notDelivered:
                Image(systemName: "exclamationmark.circle")
            }
        }
        .font(.caption)
        .foregroundStyle(delivery.state == .notDelivered ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        .accessibilityElement()
        .accessibilityLabel(delivery.word)
    }

    /// Each circle has a 1-pixel outline; the front one knocks out the one behind it with a background-coloured disc,
    /// so the outlines do not cross.
    private func pair(_ symbol: String) -> some View {
        HStack(spacing: -overlap) {
            outlined(symbol)
            outlined(symbol)
                .background { Circle().fill(Color(.systemBackground)) }
        }
    }

    private func outlined(_ symbol: String) -> some View {
        Image(systemName: symbol).overlay { Circle().strokeBorder(lineWidth: 1 / displayScale) }
    }
}

/// Swipe left to right to reply, as in Messages: the row follows the finger (damped past the threshold), the reply
/// symbol fades in behind it, and crossing the threshold taps lightly. Only a mostly-horizontal rightward pan begins
/// (`ReplyPan`), so vertical scrolling is untouched; the pan runs alongside the scroll view's own.
private struct ReplySwipe: ViewModifier {
    let enabled: Bool
    @Binding var pull: CGFloat
    let threshold: CGFloat
    let maxPull: CGFloat
    let reduceMotion: Bool
    let onReply: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .offset(x: pull)
                .background(alignment: .leading) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(Double(min(pull / threshold, 1)))
                        .scaleEffect(pull >= threshold ? 1.15 : 1)
                        .offset(x: min(pull, threshold) - threshold + LayoutMetrics.inner)
                        .accessibilityHidden(true)
                }
                .sensoryFeedback(.impact(weight: .light), trigger: pull >= threshold) { _, armed in armed }
                .gesture(ReplyPan { dx in
                    let raw = max(dx, 0)
                    pull = raw <= threshold ? raw : min(threshold + (raw - threshold) / 3, maxPull)
                } onEnd: { completed in
                    if completed && pull >= threshold { onReply() }
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) { pull = 0 }
                })
        } else {
            content
        }
    }
}

/// The reply swipe's pan, a UIKit recognizer: it begins only for a pan moving right more than twice as fast as it
/// moves vertically, so any other drag fails it before it starts, and it recognises alongside the scroll view's pan.
/// A SwiftUI `DragGesture` on every row instead joined each scroll and held up the scroll view's pan and deceleration.
private struct ReplyPan: UIGestureRecognizerRepresentable {
    /// The pan's horizontal translation, on each move.
    let onChange: (CGFloat) -> Void
    /// The pan is over: true when it ended, false when cancelled.
    let onEnd: (Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .changed: onChange(pan.translation(in: pan.view).x)
        case .ended: onEnd(true)
        case .cancelled, .failed: onEnd(false)
        default: break
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x > 0 && velocity.x > abs(velocity.y) * 2
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
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
            if let upload = delivery.upload {
                ProgressView(value: upload) {
                    Label("Uploading ^[\(delivery.files) file](inflect: true)", systemImage: "arrow.up.circle")
                } currentValueLabel: {
                    Text(upload, format: .percent.precision(.fractionLength(0)))
                }
            } else {
                Label(delivery.word, systemImage: delivery.symbol).foregroundStyle(.secondary)
            }
        }
        row("Sent", delivery.sentAt)
        if let delivered = delivery.deliveredAt {
            row("Accepted by relay", delivered)
            if let expires = delivery.expiresAt {
                Text("Held by the relay until the host is online · expires \(MessageTime.exact.string(from: MessageTime.date(expires)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let received = delivery.receivedAt {
            row("Received by host", received)
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

/// Select Text: the message as plain text in a `UITextView`, where part of it can be selected
/// (SwiftUI's `textSelection` copies a `Text` only whole).
struct SelectTextSheet: View {
    let text: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .yorozuTint()
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .clear
        view.dataDetectorTypes = .link
        view.textContainerInset = UIEdgeInsets(top: LayoutMetrics.gutter, left: LayoutMetrics.gutter,
                                               bottom: LayoutMetrics.gutter, right: LayoutMetrics.gutter)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
