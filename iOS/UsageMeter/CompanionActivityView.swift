import Charts
import CompanionKit
import SwiftUI

struct CompanionActivityView: View {
    let activity: CompanionActivity?
    @Binding var range: CompanionRange
    let cost: Bool
    @State private var selectedDate: Date?
    private var summary: CompanionActivityRange? { activity?.ranges.first { $0.range == range } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Time range", selection: $range) {
                ForEach(CompanionRange.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            if let summary, let activity {
                CompanionCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(cost ? "API-EQUIVALENT COST" : "PROCESSED TOKENS")
                            .font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(
                                .secondary)
                        Text(
                            cost
                                ? CompanionFormat.cost(summary.cost)
                                : CompanionFormat.tokens(summary.tokens)
                        )
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                        HStack(spacing: 7) {
                            Text("\(summary.sessions.formatted()) sessions")
                            Text("·")
                            Text(
                                range == .day
                                    ? "Last 24 hours"
                                    : "Last \(range.label.dropLast()) days, including today")
                        }.font(.caption).foregroundStyle(.secondary)
                        if cost {
                            Text("Estimated at API rates · USD").font(.caption).foregroundStyle(
                                .secondary)
                        }
                    }
                }
                if summary.tokens > 0 {
                    CompanionCard {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Text(cost ? "Cost over time" : "Token activity").font(.headline)
                                Spacer()
                                Text(range == .day ? "HOURLY" : "DAILY")
                                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            activityChart(summary)
                            selectionDetail(summary)
                            HStack(spacing: 16) {
                                ForEach(summary.providers) { provider in
                                    Label {
                                        Text(provider.name).font(.caption)
                                    } icon: {
                                        Circle().fill(Color.provider(provider.name)).frame(
                                            width: 6, height: 6)
                                    }
                                }
                            }.foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("BY PROVIDER").font(.caption.weight(.semibold)).tracking(1.2)
                            .foregroundStyle(.secondary).padding(.horizontal, 4)
                        ForEach(summary.providers) { provider in
                            providerCard(provider, summary: summary)
                        }
                    }
                } else {
                    CompanionCard {
                        ContentUnavailableView(
                            "No activity in this range", systemImage: "waveform.path",
                            description: Text(
                                "Try a longer range. Activity appears after Claude Code or Codex writes session logs on your Mac."
                            ))
                    }
                }
                if cost && summary.unpricedTokens > 0 {
                    Label(
                        "\(CompanionFormat.tokens(summary.unpricedTokens)) tokens have no known model price and are excluded from cost.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text("History observed")
                        Text(activity.capturedAt, style: .relative)
                        Text("ago")
                    }
                    Text(
                        "Calendar buckets use your Mac’s time zone (\(activity.timeZoneIdentifier))."
                    )
                    if Date.now.timeIntervalSince(activity.capturedAt) >= 600 {
                        Text("History is stale. Keep your Mac awake to receive new activity.")
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            } else {
                CompanionCard {
                    ContentUnavailableView(
                        "Waiting for activity", systemImage: "chart.xyaxis.line",
                        description: Text(
                            "Update the Mac app and keep iCloud sync enabled. Tokens and cost will arrive after its first session-log scan."
                        ))
                }
            }
        }
        .onChange(of: range) { selectedDate = nil }
        .onChange(of: cost) { selectedDate = nil }
    }

    private func providerCard(
        _ provider: CompanionProviderActivity, summary: CompanionActivityRange
    ) -> some View {
        let share =
            cost
            ? (summary.cost > 0 ? provider.cost / summary.cost : 0)
            : (summary.tokens > 0 ? Double(provider.tokens) / Double(summary.tokens) : 0)
        return CompanionCard {
            VStack(alignment: .leading, spacing: 14) {
                ProviderHeading(name: provider.name)
                HStack(alignment: .firstTextBaseline) {
                    Text(
                        cost
                            ? CompanionFormat.cost(provider.cost)
                            : CompanionFormat.tokens(provider.tokens)
                    )
                    .font(.title2.weight(.bold)).monospacedDigit()
                    Spacer()
                    Text(share.formatted(.percent.precision(.fractionLength(1))))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(
                            Color.provider(provider.name))
                }
                ProgressView(value: share).tint(.provider(provider.name))
                ViewThatFits(in: .horizontal) {
                    HStack {
                        providerDetail(provider); Spacer(); sessionCount(provider)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        providerDetail(provider); sessionCount(provider)
                    }
                }
            }
        }
    }
    private func providerDetail(_ provider: CompanionProviderActivity) -> some View {
        Text(
            cost
                ? "\(CompanionFormat.tokens(provider.tokens)) tokens"
                : "\(CompanionFormat.cost(provider.cost)) API equivalent"
        )
        .font(.caption).foregroundStyle(.secondary)
    }
    private func sessionCount(_ provider: CompanionProviderActivity) -> some View {
        Text("\(provider.sessions.formatted()) sessions").font(.caption).foregroundStyle(.secondary)
    }

    private func activityChart(_ summary: CompanionActivityRange) -> some View {
        Chart {
            ForEach(summary.providers) { provider in
                ForEach(summary.bucketStarts, id: \.self) { date in
                    let index = summary.bucketStarts.firstIndex(of: date) ?? 0
                    let value =
                        cost ? provider.bucketCost[index] : Double(provider.bucketTokens[index])
                    AreaMark(
                        x: .value("Date", date), y: .value(cost ? "USD" : "Tokens", value),
                        series: .value("Provider", provider.name), stacking: .unstacked
                    )
                    .foregroundStyle(Color.provider(provider.name).opacity(0.10))
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Date", date), y: .value(cost ? "USD" : "Tokens", value),
                        series: .value("Provider", provider.name)
                    )
                    .foregroundStyle(Color.provider(provider.name)).lineStyle(
                        StrokeStyle(lineWidth: 2)
                    )
                    .interpolationMethod(.monotone)
                }
            }
            if let index = selectionIndex(summary) {
                RuleMark(x: .value("Selected date", summary.bucketStarts[index]))
                    .foregroundStyle(.secondary.opacity(0.45)).lineStyle(
                        StrokeStyle(lineWidth: 1, dash: [4]))
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: axisDates(summary)) { value in
                AxisValueLabel(
                    anchor: value.index == 0
                        ? .topLeading : value.index == value.count - 1 ? .topTrailing : .top
                ) {
                    if let date = value.as(Date.self) {
                        if range == .day {
                            Text(date, format: .dateTime.hour()).font(.caption2)
                        } else {
                            Text(date, format: .dateTime.month(.abbreviated).day()).font(.caption2)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(
                            cost
                                ? CompanionFormat.cost(amount) : CompanionFormat.tokens(Int(amount))
                        )
                        .font(.caption2)
                    }
                }
            }
        }
        .chartLegend(.hidden).frame(height: 180)
        .environment(
            \.timeZone, TimeZone(identifier: activity?.timeZoneIdentifier ?? "") ?? .current
        )
        .accessibilityLabel(
            cost ? "API-equivalent cost by provider" : "Processed tokens by provider")
    }
    private func axisDates(_ summary: CompanionActivityRange) -> [Date] {
        let dates = summary.bucketStarts
        guard dates.count > 2 else { return dates }
        return [dates[0], dates[(dates.count - 1) / 2], dates[dates.count - 1]]
    }

    private func selectionIndex(_ summary: CompanionActivityRange) -> Int? {
        guard let selectedDate else { return nil }
        return summary.bucketStarts.indices.min {
            abs(summary.bucketStarts[$0].timeIntervalSince(selectedDate))
                < abs(summary.bucketStarts[$1].timeIntervalSince(selectedDate))
        }
    }
    @ViewBuilder private func selectionDetail(_ summary: CompanionActivityRange) -> some View {
        if let index = selectionIndex(summary) {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    summary.bucketStarts[index].formatted(
                        range == .day ? .dateTime.month().day().hour() : .dateTime.month().day())
                )
                .font(.caption.weight(.semibold))
                ForEach(summary.providers) { provider in
                    HStack {
                        Text(provider.name)
                        Spacer()
                        Text(
                            cost
                                ? CompanionFormat.cost(provider.bucketCost[index])
                                : CompanionFormat.tokens(provider.bucketTokens[index]))
                    }.font(.caption).foregroundStyle(Color.provider(provider.name))
                }
            }
        } else {
            Text("Touch and hold the chart to explore.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
