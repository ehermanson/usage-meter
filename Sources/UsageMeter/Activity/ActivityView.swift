import Charts
import SwiftUI

/// Which figure an activity tab leads with. The two tabs are one view over
/// one `ActivitySummary`; only the headline number, the chart's series, and
/// the providers' sort order change.
enum ActivityMetric {
    case tokens, cost

    /// What stands in for the chart when it would have nothing to plot: no
    /// activity at all, or on Cost, only models with no known price. Those
    /// cost nothing here, and a line at zero with no scale floats mid-chart
    /// and reads as a steady spend.
    func emptyChartNote(_ summary: ActivitySummary) -> String? {
        if summary.totalTokens == 0 { return "No activity in this range" }
        if self == .cost, summary.totalCost <= 0 { return "No priced activity in this range" }
        return nil
    }

    /// The providers the chart draws a line for: those with something to
    /// plot. On Cost, activity isn't enough: a provider whose models all
    /// lack a price would draw a flat line at $0 and list $0.00 in the
    /// hover card, which reads as idle rather than unpriced. The hero's
    /// note already says how much went unpriced. Empty only when
    /// `emptyChartNote` stands in for the chart, since a summary's totals
    /// are its providers' sums.
    func chartedProviders(_ summary: ActivitySummary) -> [ProviderActivity] {
        switch self {
        case .tokens: return summary.activeProviders
        case .cost: return summary.activeProviders.filter { $0.cost > 0 }
        }
    }

    /// How the providers card keys a provider's row to the chart: by the
    /// same rule the chart draws its lines by, so a solid dot always has a
    /// line to match.
    func key(for provider: ProviderActivity, in summary: ActivitySummary) -> ProviderMark.Key {
        chartedProviders(summary).contains { $0.name == provider.name } ? .charted : .uncharted
    }
}

/// The Tokens and Cost tabs: a range picker, a hero card with the range's
/// total and a small chart, and a card splitting the total by provider.
struct ActivityView: View {
    @Bindable var activity: ActivityStore
    let metric: ActivityMetric
    /// Accent and logo for a provider, from `UsageStore` so a provider looks
    /// the same here as on its limits card.
    let style: (String) -> (accent: Color, logoResource: String?)

    var body: some View {
        if let summary = activity.summary {
            if summary.providers.isEmpty {
                noSources
            } else {
                hero(summary)
                    .cardSurface()
                // A split needs something to split: with one provider active
                // in the range, its row would only repeat the hero.
                let active = summary.activeProviders
                if active.count > 1 {
                    providersCard(active, summary: summary)
                        .cardSurface()
                }
            }
        } else {
            // Until the launch's first scan lands. Opening the panel starts
            // it for someone who has used these tabs before; for anyone
            // else, the first visit to one does.
            LoadingRow("Reading session logs…")
        }
    }

    // MARK: - Range

    /// Shared by both tabs and persisted, so flipping between Tokens and Cost
    /// compares the same window. Changing it only re-aggregates records
    /// already in memory — the scan always covers the widest range. Mini and
    /// inside the card, a step below the tab bar: it scopes the numbers under
    /// it, not the panel.
    private var rangePicker: some View {
        SegmentedPicker(
            title: "Range", selection: $activity.range,
            options: ActivityRange.allCases.map { ($0, $0.label) }, size: .mini)
    }

    // MARK: - Hero

    private func hero(_ summary: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            rangePicker
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(summary))
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(caption(summary))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                // Its own line: tacked onto the caption it wraps mid-phrase
                // at this width.
                if let unpriced = unpricedNote(summary) {
                    Text(unpriced)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .help(
                metric == .cost
                    ? "What these tokens would cost at API list prices. Subscription plans "
                        + "aren't billed this way, so it's a measure of use, not a bill."
                    : "Input, output, and cache tokens the models processed, deduplicated "
                        + "across session logs.")

            VStack(alignment: .leading, spacing: 8) {
                Text(chartTitle(summary))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if let note = metric.emptyChartNote(summary) {
                    // Same footprint as the chart, so a quiet range doesn't
                    // make the panel jump when switching to it.
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: Self.chartHeight)
                } else {
                    ActivityChart(summary: summary, metric: metric, style: style)
                        .frame(height: Self.chartHeight)
                }
            }
        }
    }

    /// Tall enough for three gridlines and the date labels to breathe, short
    /// enough that the panel stays about as tall as the Limits tab.
    private static let chartHeight: CGFloat = 104

    private func headline(_ summary: ActivitySummary) -> String {
        switch metric {
        case .tokens: return Format.tokens(summary.totalTokens)
        case .cost: return Format.cost(summary.totalCost)
        }
    }

    /// "124 sessions", or for cost "124 sessions · API estimate".
    private func caption(_ summary: ActivitySummary) -> String {
        let sessions = Format.sessions(summary.sessions)
        return metric == .cost ? "\(sessions) · API estimate" : sessions
    }

    /// How much of the range the cost can't price, once that's big enough
    /// to show as a nonzero percentage. Tokens count every model, so the
    /// Tokens tab has nothing to exclude.
    private func unpricedNote(_ summary: ActivitySummary) -> String? {
        guard metric == .cost, summary.unpricedTokenShare >= 0.0005 else { return nil }
        return "Excludes \(Format.share(summary.unpricedTokenShare)) unpriced tokens"
    }

    private func chartTitle(_ summary: ActivitySummary) -> String {
        let cadence = summary.bucketUnit == .hour ? "Hourly" : "Daily"
        return "\(cadence) \(metric == .tokens ? "tokens" : "cost")"
    }

    // MARK: - Providers

    private func providersCard(
        _ providers: [ProviderActivity], summary: ActivitySummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(sorted(providers).enumerated()), id: \.element.id) {
                index, provider in
                if index > 0 {
                    Divider().opacity(0.4)
                }
                providerRow(provider, summary: summary)
            }
        }
    }

    /// Biggest first by the tab's own figure; ties keep registry order.
    private func sorted(_ providers: [ProviderActivity]) -> [ProviderActivity] {
        providers.enumerated()
            .sorted { a, b in
                let (x, y) = (value(of: a.element), value(of: b.element))
                return x != y ? x > y : a.offset < b.offset
            }
            .map(\.element)
    }

    private func value(of provider: ProviderActivity) -> Double {
        metric == .tokens ? Double(provider.tokens) : provider.cost
    }

    /// Dot (the chart's legend key, hollow for a provider it leaves out),
    /// logo, name and sessions, the figure on the right; underneath, the
    /// share of the whole and the other metric.
    private func providerRow(
        _ provider: ProviderActivity, summary: ActivitySummary
    )
        -> some View
    {
        let (accent, logoResource) = style(provider.name)
        let figure =
            metric == .tokens ? Format.tokens(provider.tokens) : Format.cost(provider.cost)
        let detail = detail(provider, summary: summary)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .rowMid, spacing: 6) {
                ProviderMark(
                    accent: accent, logoResource: logoResource,
                    key: metric.key(for: provider, in: summary))
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(provider.name)
                        .font(.system(size: 12, weight: .semibold))
                    Text(Format.sessions(provider.sessions))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Text(figure)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        // One VoiceOver stop per provider, read as a sentence rather than
        // five fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [provider.name, figure, Format.sessions(provider.sessions), detail]
                .joined(separator: ", "))
    }

    /// "94.7% of tokens · $1,101.11" or "87.5% of cost · 2.62B tokens". Only
    /// ever asked of active providers, so the range's total isn't zero.
    private func detail(_ provider: ProviderActivity, summary: ActivitySummary) -> String {
        switch metric {
        case .tokens:
            let share = Double(provider.tokens) / Double(summary.totalTokens)
            return "\(Format.share(share)) of tokens · \(Format.cost(provider.cost))"
        case .cost:
            let share = summary.totalCost > 0 ? provider.cost / summary.totalCost : 0
            return "\(Format.share(share)) of cost · \(Format.tokens(provider.tokens)) tokens"
        }
    }

    // MARK: - States

    /// Shown when neither tool has left a log on this Mac. A calm note, like
    /// the Limits tab's, rather than an error: there's simply nothing to add up.
    private var noSources: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No session logs found")
                .font(.system(size: 12, weight: .semibold))
            Text(
                "Tokens and cost are read from the logs Claude Code and Codex keep on this Mac. "
                    + "Neither has left one here yet."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

/// One area and line per provider, overlapping rather than stacked — the
/// point is how each provider's use moved, and a stack would bend the
/// smaller one around the larger. Hovering picks out a bucket: a rule, a dot
/// on each line, and a card with each provider's figure.
private struct ActivityChart: View {
    let summary: ActivitySummary
    let metric: ActivityMetric
    let style: (String) -> (accent: Color, logoResource: String?)

    /// The bucket under the pointer, nil when it's off the chart. An index
    /// rather than a date so a refresh that keeps the buckets keeps the
    /// hover; a range change resets it.
    @State private var hovered: Int?

    private struct Point: Identifiable {
        let id: Int
        let date: Date
        let value: Double
    }

    private struct Series: Identifiable {
        var id: String { name }
        let name: String
        let color: Color
        let logoResource: String?
        let points: [Point]
        let total: Double
    }

    /// Largest first, so a smaller provider's line is drawn over the larger
    /// one's fill instead of under it. Only the providers with something to
    /// plot (see `ActivityMetric.chartedProviders`): an idle one would be a
    /// flat line along the axis, keyed to nothing once the providers card is
    /// hidden.
    private var series: [Series] {
        metric.chartedProviders(summary)
            .map { provider in
                let values =
                    metric == .tokens ? provider.bucketTokens.map(Double.init) : provider.bucketCost
                let points = zip(summary.bucketStarts, values).enumerated().map {
                    Point(id: $0, date: $1.0, value: $1.1)
                }
                let (color, logo) = style(provider.name)
                return Series(
                    name: provider.name, color: color, logoResource: logo, points: points,
                    total: values.reduce(0, +))
            }
            .sorted { $0.total > $1.total }
    }

    var body: some View {
        let series = series
        // Dropped if the buckets changed under it; the reset below lands a
        // render later.
        let hovered = hovered.flatMap { i in
            summary.bucketStarts.indices.contains(i)
                && series.allSatisfy { $0.points.indices.contains(i) } ? i : nil
        }
        Chart {
            ForEach(series) { line in
                ForEach(line.points) { point in
                    AreaMark(
                        x: .value("Time", point.date), y: .value("Amount", point.value),
                        series: .value("Provider", line.name), stacking: .unstacked
                    )
                    .foregroundStyle(line.color.opacity(0.14))
                    // Monotone keeps the curve from overshooting below zero
                    // between a busy bucket and an idle one.
                    .interpolationMethod(.monotone)
                }
            }
            ForEach(series) { line in
                ForEach(line.points) { point in
                    LineMark(
                        x: .value("Time", point.date), y: .value("Amount", point.value),
                        series: .value("Provider", line.name)
                    )
                    .foregroundStyle(line.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                }
            }
            if let hovered {
                RuleMark(x: .value("Time", summary.bucketStarts[hovered]))
                    .foregroundStyle(Color.primary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                // Monotone curves pass through their points, so the dots sit
                // on the lines.
                ForEach(series) { line in
                    PointMark(
                        x: .value("Time", line.points[hovered].date),
                        y: .value("Amount", line.points[hovered].value)
                    )
                    .foregroundStyle(line.color)
                    .symbolSize(22)
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: xLabelDates) { value in
                AxisValueLabel(anchor: labelAnchor(value.index, of: value.count)) {
                    if let date = value.as(Date.self) {
                        Text(xLabel(date, isLast: value.index == value.count - 1))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.primary.opacity(0.1))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(yLabel(amount))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
                // A drawn card rather than `.help`: a system tooltip is one
                // fixed string per view, so it can't follow the pointer from
                // bucket to bucket.
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            self.hovered = bucket(nearestX: location.x - plot.minX, proxy: proxy)
                        case .ended:
                            self.hovered = nil
                        }
                    }
                if let hovered, let x = proxy.position(forX: summary.bucketStarts[hovered]) {
                    tooltip(at: hovered, series: series)
                        .frame(width: Self.tooltipWidth)
                        .offset(
                            x: tooltipX(ruleX: plot.minX + x, in: geo.size.width),
                            y: plot.minY + 2
                        )
                        .frame(
                            maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: summary.bucketStarts) { _, _ in self.hovered = nil }
        // Closing the panel under the pointer never sends the hover's end, so
        // without this the card would still be up when the panel reopens.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
            _ in self.hovered = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(series))
    }

    // MARK: - Hover

    private static let tooltipWidth: CGFloat = 146

    /// The bucket whose point is closest to the pointer, measured along x in
    /// plot coordinates.
    private func bucket(nearestX x: CGFloat, proxy: ChartProxy) -> Int? {
        summary.bucketStarts.indices.min { a, b in
            abs((proxy.position(forX: summary.bucketStarts[a]) ?? .infinity) - x)
                < abs((proxy.position(forX: summary.bucketStarts[b]) ?? .infinity) - x)
        }
    }

    /// Beside the rule, on whichever side has room — right while the pointer
    /// is in the chart's left part, left after — and kept inside the chart.
    private func tooltipX(ruleX: CGFloat, in width: CGFloat) -> CGFloat {
        let gap: CGFloat = 8
        let right = ruleX + gap
        let x = right + Self.tooltipWidth <= width ? right : ruleX - gap - Self.tooltipWidth
        return min(max(0, x), max(0, width - Self.tooltipWidth))
    }

    /// The bucket's date, then each provider's figure with its mark tinted
    /// to match its line (the chart has no other legend when the providers
    /// card is hidden), then the total when there's more than one.
    private func tooltip(at index: Int, series: [Series]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(tooltipTitle(summary.bucketStarts[index]))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(series) { line in
                tooltipRow(line.points[index].value) {
                    HStack(spacing: 5) {
                        if let logo = line.logoResource.flatMap(BrandLogo.image(named:)) {
                            Image(nsImage: logo)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 11, height: 11)
                                .foregroundStyle(line.color)
                        } else {
                            Circle().fill(line.color).frame(width: 6, height: 6)
                        }
                        Text(line.name)
                    }
                }
            }
            if series.count > 1 {
                Divider().opacity(0.5)
                tooltipRow(series.reduce(0) { $0 + $1.points[index].value }) {
                    Text("Total")
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .accessibilityHidden(true)
    }

    private func tooltipRow(
        _ value: Double, @ViewBuilder label: () -> some View
    ) -> some View {
        HStack(spacing: 6) {
            label()
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(format(value))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    /// "Sat, Sep 27" per day; "Sat, 3 PM" per hour, since the 24h range
    /// spans two days.
    private func tooltipTitle(_ date: Date) -> String {
        summary.bucketUnit == .hour
            ? date.formatted(.dateTime.weekday(.abbreviated).hour())
            : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func format(_ value: Double) -> String {
        metric == .tokens ? Format.tokens(Int(value.rounded())) : Format.cost(value)
    }

    // MARK: - Axes

    private var xDomain: ClosedRange<Date> {
        let first = summary.bucketStarts.first ?? .now
        let last = summary.bucketStarts.last ?? first
        return first...max(last, first.addingTimeInterval(1))
    }

    /// First, middle, and last bucket: enough to place the curve in time
    /// without crowding a chart this narrow.
    private var xLabelDates: [Date] {
        let starts = summary.bucketStarts
        guard starts.count > 2 else { return starts }
        return [starts[0], starts[(starts.count - 1) / 2], starts[starts.count - 1]]
    }

    /// The end labels hug the plot's edges instead of centering on them, so
    /// they can't hang past the chart and clip.
    private func labelAnchor(_ index: Int, of count: Int) -> UnitPoint {
        if index == 0 { return .topLeading }
        if index == count - 1 { return .topTrailing }
        return .top
    }

    /// "SEP 21" per day, "9 PM" per hour. 24h's last tick reads "Now": its
    /// hour is the one 24 hours after the first tick's, so as a clock time
    /// it would repeat the first label ("11 PM … 11 PM") and look like a
    /// mistake.
    private func xLabel(_ date: Date, isLast: Bool) -> String {
        if summary.bucketUnit == .hour {
            return isLast ? "Now" : date.formatted(.dateTime.hour())
        }
        return date.formatted(.dateTime.month(.abbreviated).day()).uppercased()
    }

    private func yLabel(_ amount: Double) -> String {
        metric == .tokens ? Format.tokensAxis(amount) : Format.costAxis(amount)
    }

    /// The chart as one sentence: what it plots, each provider's total, and
    /// the busiest bucket.
    private func accessibilitySummary(_ series: [Series]) -> String {
        let unit = summary.bucketUnit == .hour ? "Hourly" : "Daily"
        let noun = metric == .tokens ? "tokens" : "cost"
        let span: String
        switch summary.range {
        case .day: span = "24 hours"
        case .week: span = "7 days"
        case .month: span = "30 days"
        case .quarter: span = "90 days"
        }
        var parts = ["\(unit) \(noun) chart, last \(span)"]
        parts += series.map { "\($0.name) \(format($0.total))" }
        let combined = summary.bucketStarts.indices.map { i in
            series.reduce(0) { $0 + ($1.points.indices.contains(i) ? $1.points[i].value : 0) }
        }
        if let peak = combined.indices.max(by: { combined[$0] < combined[$1] }),
            combined[peak] > 0
        {
            let when =
                summary.bucketUnit == .hour
                ? summary.bucketStarts[peak].formatted(date: .omitted, time: .shortened)
                : summary.bucketStarts[peak].formatted(.dateTime.month(.wide).day())
            parts.append("Busiest \(summary.bucketUnit == .hour ? "hour" : "day") \(when)")
        }
        return parts.joined(separator: ". ")
    }
}
