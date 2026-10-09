import SwiftUI
import AppKit
import ProjectXCore

/// A notice in the user's language; any other message as stored.
func notice(_ m: Message) -> String { m.notice.map { NoticeText.text(code: $0.code,params: $0.params,fallback: m.body) } ?? m.body }

extension Message {
    /// How a row draws in the popover.
    enum Style { case user, answer, question, system, failure }
    var style: Style {
        if role == "user" { return .user }
        if kind == "question" || notice.map({ [Notice.Code.question,.questionTopic,.questionTask].map(\.rawValue).contains($0.code) }) == true { return .question }
        if kind == "failure" { return .failure }
        if notice != nil || ["acknowledgment","memory_receipt","approval_request"].contains(kind) { return .system }
        return .answer
    }
    /// A result stored with Store's "Regarding “…”:" header carries its own context, so it gets no reply header.
    var hasStoredHeader: Bool { body.hasPrefix("Regarding “") && body.contains("”:\n\n") }
    /// What Copy puts on the pasteboard: the answer alone, without a stored "Regarding “…”:" header.
    var copyText: String {
        guard hasStoredHeader, let r = body.range(of: "”:\n\n") else { return body }
        return String(body[r.upperBound...])
    }
    var date: Date { Date(timeIntervalSince1970: created) }
}

/// The popover's colours that the system has no name for: the user bubble and the failure amber (approved design).
enum ChatPalette {
    /// Vermilion that keeps white text legible in dark mode, where the accent itself is lighter.
    static let bubble = dynamic(light: (0.737,0.176,0.110),dark: (0.722,0.220,0.165))
    static let warning = dynamic(light: (0.604,0.322,0.0),dark: (0.941,0.639,0.251))
    private static func dynamic(light: (CGFloat,CGFloat,CGFloat),dark: (CGFloat,CGFloat,CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua,.darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0,green: c.1,blue: c.2,alpha: 1)
        })
    }
}

/// One message in the main timeline, drawn by its style. `reveal` scrolls to another message (the request a reply answers).
struct MessageRow: View {
    let message: Message
    /// The request this answer replies to, when it is on the timeline.
    let request: Message?
    let highlighted: Bool
    let reveal: (String) -> Void
    private enum Metrics {
        static let cardRadius: CGFloat = 14, bubbleRadius: CGFloat = 16, ring: CGFloat = 2
        static let bubbleShare: CGFloat = 0.8
    }
    var body: some View {
        content
            .help(Text(message.date,format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute().second()))
            .contextMenu { Button("Copy") { _ = Pasteboard.copy(message.style == .answer ? message.copyText : message.body) } }
    }
    @ViewBuilder private var content: some View {
        switch message.style {
        case .user:
            Text(message.body).textSelection(.enabled).foregroundStyle(.white)
                .padding(.horizontal,11).padding(.vertical,7)
                .background(ChatPalette.bubble,in: RoundedRectangle(cornerRadius: Metrics.bubbleRadius,style: .continuous))
                .overlay { ring(Metrics.bubbleRadius) }
                .containerRelativeFrame(.horizontal,alignment: .trailing) { width,_ in width * Metrics.bubbleShare }
                .frame(maxWidth: .infinity,alignment: .trailing)
        case .answer: AnswerCard(message: message,request: message.hasStoredHeader ? nil : request,reveal: reveal).overlay { ring(Metrics.cardRadius) }
        case .question:
            VStack(alignment: .leading,spacing: 4) {
                Label("Question",systemImage: "questionmark.bubble").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                MarkdownBlocks(notice(message))
            }.card(radius: Metrics.cardRadius).overlay { ring(Metrics.cardRadius) }
        case .system, .failure: SystemRow(message: message).overlay { ring(Metrics.cardRadius / 2) }
        }
    }
    @ViewBuilder private func ring(_ radius: CGFloat) -> some View {
        if highlighted { RoundedRectangle(cornerRadius: radius,style: .continuous).strokeBorder(Color.accentColor,lineWidth: Metrics.ring) }
    }
}

private extension View {
    /// An answer or question card: system material with a hairline edge.
    func card(radius: CGFloat) -> some View {
        padding(.horizontal,11).padding(.vertical,9).frame(maxWidth: .infinity,alignment: .leading)
            .background(.regularMaterial,in: RoundedRectangle(cornerRadius: radius,style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius,style: .continuous).strokeBorder(.separator,lineWidth: 0.5) }
    }
}

/// An answer: a quoted reply header that jumps to the request, the body, and a Copy pill on hover.
private struct AnswerCard: View {
    let message: Message
    let request: Message?
    let reveal: (String) -> Void
    @State private var hovering = false
    private enum Metrics { static let radius: CGFloat = 14, headerRadius: CGFloat = 7 }
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            if let request {
                Button { reveal(request.id) } label: {
                    Label { Text(verbatim: "“\(request.body.split(separator: "\n").first.map(String.init) ?? request.body)”").lineLimit(1).truncationMode(.tail) }
                        icon: { Image(systemName: "arrowshape.turn.up.left") }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal,7).padding(.vertical,3)
                        .background(.quaternary,in: RoundedRectangle(cornerRadius: Metrics.headerRadius,style: .continuous))
                }.buttonStyle(.plain).help("Show the request").accessibilityLabel("Show the request")
            }
            MarkdownBlocks(message.body)
        }
        .card(radius: Metrics.radius)
        .overlay(alignment: .topTrailing) { if hovering { CopyButton(text: message.copyText).alignmentGuide(.top) { $0.height / 2 }.padding(.trailing,10) } }
        .onHover { hovering = $0 }
    }
}

/// Acknowledgments, receipts, approvals, notices and failures: compact, with an icon and, when the notice holds a raw
/// error, a Details disclosure. Failures read in plain language with the amber warning icon.
private struct SystemRow: View {
    let message: Message
    @State private var open = false
    private enum Metrics { static let detailRadius: CGFloat = 7 }
    var body: some View {
        let failure = message.style == .failure, detail = message.notice.flatMap { NoticeText.details($0.params) }
        VStack(alignment: .leading,spacing: 5) {
            HStack(alignment: .firstTextBaseline,spacing: 6) {
                Image(systemName: failure ? "exclamationmark.triangle" : icon).foregroundStyle(failure ? ChatPalette.warning : .secondary)
                    .accessibilityLabel(failure ? Text("Problem") : Text("Note"))
                Text(notice(message)).foregroundStyle(failure ? .primary : .secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity,alignment: .leading)
                if detail != nil {
                    Button { withAnimation(.snappy) { open.toggle() } } label: {
                        HStack(spacing: 2) { Text("Details"); Image(systemName: "chevron.right").imageScale(.small).rotationEffect(.degrees(open ? 90 : 0)) }
                    }.buttonStyle(.plain).foregroundStyle(Color.accentColor).accessibilityValue(open ? Text("Expanded") : Text("Collapsed"))
                }
            }
            if open, let detail {
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity,alignment: .leading).padding(.horizontal,8).padding(.vertical,6)
                    .background(.quaternary.opacity(0.5),in: RoundedRectangle(cornerRadius: Metrics.detailRadius,style: .continuous))
            }
        }.font(.callout).padding(.horizontal,4)
    }
    private var icon: String {
        switch message.kind { case "memory_receipt": "brain"; case "approval_request": "hand.raised"; default: "info.circle" }
    }
}

/// Copy with feedback: "Copied", or "Copy failed" in amber, for two seconds, announced to VoiceOver.
struct CopyButton: View {
    let text: String
    @State private var copied: Bool?
    var body: some View {
        Button {
            let ok = Pasteboard.copy(text); copied = ok
            Task { try? await Task.sleep(for: .seconds(2)); if copied == ok { copied = nil } }
        } label: {
            Label(copied == nil ? "Copy" : copied! ? "Copied" : "Copy failed",systemImage: copied == nil ? "doc.on.doc" : copied! ? "checkmark" : "exclamationmark.triangle")
                .font(.caption).padding(.horizontal,8).padding(.vertical,3)
                .background(.thickMaterial,in: Capsule()).overlay { Capsule().strokeBorder(.separator,lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.12),radius: 4,y: 2)
        }.buttonStyle(.plain).foregroundStyle(copied == false ? ChatPalette.warning : .primary)
            .help("Copy answer").accessibilityLabel(copied == nil ? "Copy answer" : copied! ? "Answer copied" : "Copy failed")
    }
}

enum Pasteboard {
    @MainActor static func copy(_ text: String) -> Bool {
        let board = NSPasteboard.general; board.clearContents()
        let ok = board.setString(text,forType: .string)
        NSAccessibility.post(element: NSApp as Any,notification: .announcementRequested,userInfo: [.announcement: ok ? "Copied" : "Copy failed",.priority: NSAccessibilityPriorityLevel.high.rawValue])
        return ok
    }
}

/// A day's first message: "Today", "Yesterday", or the date, between hairlines.
struct DaySeparator: View {
    let day: Date
    var body: some View {
        HStack(spacing: 8) {
            line; Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).fixedSize(); line
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
    private var line: some View { Rectangle().fill(.separator).frame(height: 0.5) }
    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let sameYear = calendar.isDate(day,equalTo: Date(),toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide) : .dateTime.weekday(.wide).day().month(.wide).year())
    }
}
