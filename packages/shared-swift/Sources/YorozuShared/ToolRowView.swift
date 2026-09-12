import SwiftUI

/// What a tool call looks like in a trace: one compact line — symbol, name, arguments, how it
/// went and how long it took — that opens to show the arguments in full and whatever the tool
/// printed. Consecutive calls arrive as a group, which starts collapsed behind "N steps",
/// because a turn that ran eight commands should not be eight screens of trace.

/// A run of tool calls, collapsed to one line until asked. A single call is shown outright:
/// there is nothing to collapse, and "1 step" is a worse row than the step itself.
public struct ToolGroupView: View {
    private let activities: [ToolActivity]
    @State private var expanded: Bool

    public init(activities: [ToolActivity], expanded: Bool = false) {
        self.activities = activities
        _expanded = State(initialValue: expanded)
    }

    /// A group is still working while any of its calls is.
    private var running: Bool { activities.contains { $0.running } }

    private var failed: Int { activities.filter { !$0.running && !$0.ok }.count }

    public var body: some View {
        if activities.count == 1, let only = activities.first {
            ToolRowView(activity: only)
        } else if !activities.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if running {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: failed > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(summary)
                .accessibilityHint(expanded ? "Hides the steps" : "Shows the steps")

                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(activities) { ToolRowView(activity: $0) }
                    }
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    /// "4 steps", and how it went once it is over: the two things worth knowing while collapsed.
    private var summary: String {
        let steps = "\(activities.count) steps"
        if running { return "\(steps) · working…" }
        return failed > 0 ? "\(steps) · \(failed) failed" : steps
    }
}

/// One tool call: the compact line, and what it did behind it.
public struct ToolRowView: View {
    private let activity: ToolActivity
    @State private var expanded: Bool
    /// Long output is cut until asked for, so one `cat` of a large file does not become the
    /// whole trace. The cap is on lines rather than characters: it is what the eye counts.
    @State private var showingAll = false

    private static let previewLines = 12
    /// Tall enough to read a stack trace in, short enough that the row is still a row.
    private static let maxOutputHeight: CGFloat = 260

    public init(activity: ToolActivity, expanded: Bool = false) {
        self.activity = activity
        _expanded = State(initialValue: expanded)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(expanded ? "Hides the details" : "Shows the arguments and output")

            if expanded { details }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: activity.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.name)
                    .font(.subheadline.weight(.medium))
                if !activity.argsSummary.isEmpty {
                    Text(activity.argsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let diff = outputDiff {
                Text(diff.counts)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let duration = activity.duration {
                Text(duration, format: .units(allowed: [.seconds, .milliseconds], width: .narrow))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            status
        }
        .contentShape(.rect)
    }

    @ViewBuilder private var status: some View {
        if activity.running {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: activity.ok ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(activity.ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .accessibilityLabel(activity.ok ? "done" : "failed")
        }
    }

    @ViewBuilder private var details: some View {
        Divider()
        if !activity.argsDetail.isEmpty {
            Text(activity.argsDetail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let output = activity.output, !output.isEmpty {
            // The first lines sit in the thread and scroll with it — a scroll view inside one
            // is a thing to fight with on a phone. Only "Show all" makes one, because that is
            // the case where the row would otherwise be as tall as the file.
            if showingAll {
                ScrollView {
                    body(of: output)
                }
                .frame(maxHeight: Self.maxOutputHeight)
            } else {
                body(of: output)
                if lineCount(output) > Self.previewLines {
                    Button("Show all \(lineCount(output)) lines") {
                        withAnimation(.snappy) { showingAll = true }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
        } else if !activity.running {
            Text("No output.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// What the tool printed: a coloured diff when that is what it is, and monospaced text
    /// otherwise, cut to the first lines until "Show all" asks for the rest.
    @ViewBuilder private func body(of output: String) -> some View {
        if let diff = outputDiff {
            DiffView(diff: diff, lines: visibleLineLimit)
        } else {
            Text(shown(output))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The tool's output read as a diff, when it is one: an edit is worth colouring.
    private var outputDiff: UnifiedDiff? { activity.output.flatMap(unifiedDiff(in:)) }

    private var visibleLineLimit: Int? { showingAll ? nil : Self.previewLines }

    private func lineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private func shown(_ text: String) -> String {
        guard let limit = visibleLineLimit else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > limit else { return text }
        return lines.prefix(limit).joined(separator: "\n")
    }
}

/// A unified diff, coloured: added lines green, removed red, hunk headers and file names
/// quiet. Monospaced, because a diff that does not line up is not a diff.
public struct DiffView: View {
    private let diff: UnifiedDiff
    /// How many lines to draw, or nil for all of them.
    private let lines: Int?

    public init(diff: UnifiedDiff, lines: Int? = nil) {
        self.diff = diff
        self.lines = lines
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.map { Array(diff.lines.prefix($0)) } ?? diff.lines) { line in
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(colour(line.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .background(background(line.kind))
            }
        }
        .textSelection(.enabled)
    }

    private func colour(_ kind: UnifiedDiff.Line.Kind) -> AnyShapeStyle {
        switch kind {
        case .added: AnyShapeStyle(.green)
        case .removed: AnyShapeStyle(.red)
        case .meta: AnyShapeStyle(.tertiary)
        case .context: AnyShapeStyle(.secondary)
        }
    }

    /// A tint behind the changed lines, so the shape of the edit reads before the text does.
    /// Kept faint: it sits on both a light and a dark background.
    private func background(_ kind: UnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.12)
        case .removed: .red.opacity(0.12)
        case .meta, .context: .clear
        }
    }
}
