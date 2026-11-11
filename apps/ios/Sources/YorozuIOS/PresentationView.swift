import Charts
import SwiftUI
import YorozuWire

/// The card's own geometry; its width always comes from the row.
private enum CardMetrics {
    static let cellInset: CGFloat = 10
    static let cellTight: CGFloat = 5
    static let radius: CGFloat = 9
    static let chartHeight: CGFloat = 220
    static let areaOpacity: Double = 0.5
}

/// A reply's read-only card (capability `presentation`), after its text bubble (alone for a card-only reply): title and tone, then each
/// block. A block the reader couldn't check draws as its `alt`.
struct PresentationView: View {
    let card: Presentation

    var body: some View {
        let blocks = card.drawn
        VStack(alignment: .leading, spacing: LayoutMetrics.stack) {
            header
            ForEach(blocks.indices, id: \.self) { block(blocks[$0]) }
        }
        .padding(LayoutMetrics.stack)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
    }

    @ViewBuilder private var header: some View {
        let title = card.title.flatMap { $0.isEmpty ? nil : $0 }
        let tone = card.tone.flatMap(ToneStyle.init)
        if let title, let tone {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: tone.symbol).foregroundStyle(tone.color).accessibilityLabel(tone.name)
            }
            .textStyle(.headline)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        } else if let title {
            Text(verbatim: title).textStyle(.headline).accessibilityAddTraits(.isHeader)
        } else if let tone {
            Label(tone.name, systemImage: tone.symbol).textStyle(.headline).foregroundStyle(tone.color)
        }
    }

    @ViewBuilder private func block(_ block: Presentation.Block) -> some View {
        switch block {
        case .text(let text):
            MarkdownBlocks(text)
        case .context(let text):
            Text(verbatim: text).textStyle(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
        case .divider:
            Divider()
        case .table(let table, _):
            CardTable(table: table)
        case .chart(let chart, let alt):
            CardChart(chart: chart, alt: alt)
        case .unknown(let alt):
            Text(verbatim: alt ?? "").textSelection(.enabled)
        }
    }
}

/// A tone's symbol, colour and spoken name; neutral has none.
private struct ToneStyle {
    let symbol: String
    let color: Color
    let name: String

    init?(_ tone: Presentation.Tone) {
        switch tone {
        case .info: self.init(symbol: "info.circle.fill", color: .blue, name: String(localized: "Info"))
        case .success: self.init(symbol: "checkmark.circle.fill", color: .green, name: String(localized: "Success"))
        case .warning:
            self.init(symbol: "exclamationmark.triangle.fill", color: YorozuPalette.warning, name: String(localized: "Warning"))
        case .danger: self.init(symbol: "exclamationmark.octagon.fill", color: .red, name: String(localized: "Danger"))
        case .neutral: return nil
        }
    }

    private init(symbol: String, color: Color, name: String) {
        self.symbol = symbol
        self.color = color
        self.name = name
    }
}

/// A grid that scrolls sideways when it is wider than the card. VoiceOver reads the caption, the header row and
/// the row header column as headers, and each other cell with its row header and column header.
private struct CardTable: View {
    let table: Presentation.Table

    var body: some View {
        let numeric = table.headers.indices.map { column in
            table.rows.allSatisfy { if case .number = $0[column] { true } else { false } }
        }
        VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
            if let caption = table.caption, !caption.isEmpty {
                Text(verbatim: caption).textStyle(.subheadline, weight: .semibold).accessibilityAddTraits(.isHeader)
            }
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(table.headers.indices, id: \.self) { column in
                            cell(table.headers[column], trailing: numeric[column])
                                .fontWeight(.semibold)
                                .background(.fill.quaternary, in: Rectangle())
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    ForEach(table.rows.indices, id: \.self) { row in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            ForEach(table.headers.indices, id: \.self) { column in
                                if column == table.rowHeader {
                                    cell(text(row, column), trailing: false).fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                                } else {
                                    cell(text(row, column), trailing: numeric[column])
                                        .accessibilityLabel(Text(verbatim: spoken(row, column)))
                                }
                            }
                        }
                    }
                }
                .textStyle(.callout)
                .monospacedDigit()
                .clipShape(RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous).strokeBorder(.separator))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func text(_ row: Int, _ column: Int) -> String {
        table.rows[row][column].text
    }

    /// "Traveler A, Paid, 120": the cell with its row header and column header.
    private func spoken(_ row: Int, _ column: Int) -> String {
        ((table.rowHeader.map { [text(row, $0)] } ?? []) + [table.headers[column], text(row, column)]).joined(separator: ", ")
    }

    private func cell(_ text: String, trailing: Bool) -> some View {
        Text(verbatim: text)
            .padding(.horizontal, CardMetrics.cellInset)
            .padding(.vertical, CardMetrics.cellTight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: trailing ? .topTrailing : .topLeading)
    }
}

/// A Swift Charts plot. VoiceOver reads the block's `alt` (its title and data as text) and offers the data as an
/// audio graph through the chart descriptor.
private struct CardChart: View, AXChartDescriptorRepresentable {
    let chart: Presentation.Chart
    let alt: String?

    private struct Point: Identifiable {
        let id: Int
        let category: String
        let series: String
        let value: Double
    }

    private var categories: [String] { chart.categories ?? [] }
    private var series: [Presentation.Chart.Series] { chart.series ?? [] }
    private var segments: [Presentation.Chart.Segment] { chart.segments ?? [] }
    private var xTitle: String { chart.xLabel ?? String(localized: "Category") }
    private var yTitle: String { chart.yLabel ?? String(localized: "Value") }

    /// The decoder checked that every series has one value per category.
    private var points: [Point] {
        series.enumerated().flatMap { s, entry in
            categories.indices.map { Point(id: s * categories.count + $0, category: categories[$0], series: entry.name, value: entry.values[$0]) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
            if let title = chart.title, !title.isEmpty {
                Text(verbatim: title).textStyle(.subheadline, weight: .semibold).accessibilityAddTraits(.isHeader)
            }
            plot
                .chartLegend(chart.chartType == .pie || series.count > 1 ? .automatic : .hidden)
                .frame(height: CardMetrics.chartHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: alt ?? chart.title ?? ""))
                .accessibilityChartDescriptor(self)
        }
    }

    @ViewBuilder private var plot: some View {
        if chart.chartType == .pie {
            Chart(segments.indices, id: \.self) { index in
                SectorMark(angle: .value(yTitle, segments[index].value))
                    .foregroundStyle(by: .value(xTitle, segments[index].label))
            }
        } else {
            Chart(points) { point in
                let x = PlottableValue.value(xTitle, point.category), y = PlottableValue.value(yTitle, point.value)
                let name = PlottableValue.value(String(localized: "Series"), point.series)
                switch chart.chartType {
                case .line: LineMark(x: x, y: y).foregroundStyle(by: name)
                case .area: AreaMark(x: x, y: y, stacking: .unstacked).foregroundStyle(by: name).opacity(CardMetrics.areaOpacity)
                default: BarMark(x: x, y: y).foregroundStyle(by: name).position(by: name)
                }
            }
            .chartXAxisLabel { if let label = chart.xLabel { Text(verbatim: label) } }
            .chartYAxisLabel { if let label = chart.yLabel { Text(verbatim: label) } }
        }
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let pie = chart.chartType == .pie
        let values = pie ? segments.map(\.value) : series.flatMap(\.values)
        let low = min(0, values.min() ?? 0), high = max(low, values.max() ?? 0)
        let x = AXCategoricalDataAxisDescriptor(title: xTitle, categoryOrder: pie ? segments.map(\.label) : categories)
        let y = AXNumericDataAxisDescriptor(title: yTitle, range: low...high, gridlinePositions: []) { $0.formatted() }
        let data = pie
            ? [AXDataSeriesDescriptor(name: chart.title ?? "", isContinuous: false,
                dataPoints: segments.map { AXDataPoint(x: $0.label, y: $0.value) })]
            : series.map { entry in
                AXDataSeriesDescriptor(name: entry.name, isContinuous: chart.chartType != .bar,
                    dataPoints: zip(categories, entry.values).map { AXDataPoint(x: $0, y: $1) })
            }
        return AXChartDescriptor(title: chart.title, summary: alt, xAxis: x, yAxis: y, additionalAxes: [], series: data)
    }
}
