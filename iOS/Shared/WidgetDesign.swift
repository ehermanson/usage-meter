import CompanionKit
import SwiftUI

/// Shared with the development gallery so visual checks exercise the shipped views.
enum MeterWidgetStyle {
    static func accent(_ name: String) -> Color {
        switch name {
        case "Claude": Color(red: 0.86, green: 0.39, blue: 0.22)
        case "Codex": Color(red: 0.18, green: 0.53, blue: 0.46)
        default: .blue
        }
    }
    static func quotaColor(_ fraction: Double, provider: String) -> Color {
        fraction >= 0.9
            ? Color(red: 0.95, green: 0.22, blue: 0.28)
            : fraction >= 0.75 ? Color(red: 0.90, green: 0.63, blue: 0.09) : accent(provider)
    }
    static func duration(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes < 1 { return "<1m" }
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
    static func age(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        if minutes < 1440 { return "\(minutes / 60)h ago" }
        return "\(minutes / 1440)d ago"
    }
    static func figure(tokens: Int, cost: Double, isCost: Bool) -> String {
        if isCost { return cost.formatted(.currency(code: "USD")) }
        if tokens >= 1_000_000_000 {
            return String(format: "%.2fB", Double(tokens) / 1_000_000_000)
        }
        if tokens >= 1_000_000 { return String(format: "%.2fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return tokens.formatted()
    }
}

struct MeterWidgetBackground: View {
    var accent: Color = .blue
    var body: some View {
        Color(uiColor: .systemBackground)
            .overlay(alignment: .topLeading) {
                LinearGradient(
                    colors: [accent.opacity(0.07), .clear], startPoint: .topLeading,
                    endPoint: .bottomTrailing)
            }
    }
}

struct MeterProviderMark: View {
    let name: String
    var size: CGFloat = 20
    var body: some View {
        Image(name == "Claude" ? "claude-logo" : name == "Codex" ? "openai-logo" : "gemini-logo")
            .resizable().renderingMode(.template).scaledToFit().frame(width: size, height: size)
            .foregroundStyle(MeterWidgetStyle.accent(name)).accessibilityHidden(true)
    }
}

struct MeterWidgetFreshness: View {
    let capturedAt: Date?
    let now: Date
    var unavailable = false
    private var stale: Bool {
        guard let capturedAt else { return true }
        return now.timeIntervalSince(capturedAt) >= 600 || capturedAt > now.addingTimeInterval(300)
    }
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: stale || unavailable ? "clock.badge.exclamationmark" : "clock")
                .font(.system(size: 9, weight: .medium))
            Text(caption).font(.system(size: 10, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
        .accessibilityLabel(caption)
    }
    private var caption: String {
        guard let capturedAt else { return "Waiting for a reading" }
        if capturedAt > now.addingTimeInterval(300) { return "Check Mac’s clock · Stale" }
        let suffix = unavailable ? " · Unavailable" : stale ? " · Stale" : ""
        return "Updated \(MeterWidgetStyle.age(capturedAt, now: now))\(suffix)"
    }
}

struct MeterLimitsDesign: View {
    let provider: CompanionProvider?
    let windows: [CompanionWindow]
    let now: Date
    let medium: Bool
    let remaining: Bool
    var connected = true
    var controlScope: String? = nil
    var availableProviders: [String] = []
    var selectedChoice = "tightest"
    var showControls = false
    private var lead: CompanionWindow? {
        medium ? windows.first : windows.max { $0.fraction < $1.fraction }
    }
    var body: some View {
        if let provider, !provider.isExpired(at: now), let lead {
            VStack(alignment: .leading, spacing: medium ? 5 : 2) {
                HStack(spacing: 7) {
                    MeterProviderMark(name: provider.name, size: medium ? 19 : 17)
                    Text(provider.name).font(.system(size: medium ? 16 : 14, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    if showControls {
                        MeterProviderControls(
                            scope: controlScope, names: availableProviders,
                            selected: selectedChoice, medium: medium, visibleProvider: provider.name
                        )
                    } else if medium, let plan = provider.plan {
                        Text(plan).font(.system(size: 10, weight: .medium)).foregroundStyle(
                            .secondary
                        )
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.primary.opacity(0.05), in: Capsule()).lineLimit(1)
                    }
                }
                if medium {
                    VStack(spacing: showControls ? 9 : 5) {
                        ForEach(Array(windows.prefix(2))) { window in
                            quotaRow(window, provider: provider.name)
                        }
                    }
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(percent(lead)).font(.system(size: 32, weight: .bold, design: .rounded))
                            .tracking(-1.5).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                        Text(remaining ? "left" : "used").font(.system(size: 10)).foregroundStyle(
                            .secondary)
                    }
                    Text(label(lead)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    MeterQuotaTrack(
                        value: value(lead),
                        color: MeterWidgetStyle.quotaColor(lead.fraction, provider: provider.name)
                    )
                    .frame(height: 6)
                    resetCaption(lead)
                    Spacer(minLength: 0)
                }
                MeterWidgetFreshness(
                    capturedAt: provider.capturedAt, now: now,
                    unavailable: provider.status != .available)
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                if showControls {
                    MeterProviderControls(
                        scope: controlScope, names: availableProviders,
                        selected: selectedChoice, medium: medium)
                }
                Image(systemName: connected ? "clock.arrow.circlepath" : "qrcode.viewfinder")
                    .font(.title2).foregroundStyle(.secondary)
                Text("Usage Meter").font(.headline)
                Text(
                    connected
                        ? "Waiting for a current reading from your Mac."
                        : "Open the app to connect your Mac."
                )
                .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
    private func value(_ window: CompanionWindow) -> Double {
        remaining ? 1 - window.fraction : window.fraction
    }
    private func percent(_ window: CompanionWindow) -> String {
        (value(window) * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }
    private func label(_ window: CompanionWindow) -> String {
        window.pool.map { "\(window.label) · \($0)" } ?? window.label
    }
    private func quotaRow(_ window: CompanionWindow, provider: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label(window)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if showControls, let reset = window.resetAt, reset > now {
                    Label(
                        MeterWidgetStyle.duration(reset, now: now), systemImage: "arrow.clockwise"
                    )
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Resets in \(MeterWidgetStyle.duration(reset, now: now))")
                }
                if showControls, window.needsNewReading(at: now) {
                    Text("Awaiting").font(.system(size: 9)).foregroundStyle(.secondary)
                        .accessibilityLabel("Reset passed, awaiting a new reading")
                }
                Spacer(minLength: 4)
                Text(percent(window)).font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(remaining ? "left" : "used").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            MeterQuotaTrack(
                value: value(window),
                color: MeterWidgetStyle.quotaColor(window.fraction, provider: provider)
            ).frame(height: 5)
            if !showControls { resetCaption(window) }
        }.accessibilityElement(children: .combine)
    }
    private func resetCaption(_ window: CompanionWindow) -> some View {
        Text(
            window.needsNewReading(at: now)
                ? "Reset passed · awaiting reading"
                : window.resetAt.map { "Resets in \(MeterWidgetStyle.duration($0, now: now))" }
                    ?? "No reset reported"
        )
        .font(.system(size: medium ? 9 : 10)).monospacedDigit().foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct MeterQuotaTrack: View {
    let value: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.07))
                Capsule().fill(
                    LinearGradient(
                        colors: [color.opacity(0.7), color], startPoint: .leading,
                        endPoint: .trailing)
                )
                .frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }.accessibilityHidden(true)
    }
}

struct MeterActivityDesign: View {
    let activity: CompanionActivity?
    let range: CompanionRange
    let now: Date
    let medium: Bool
    let isCost: Bool
    var controlScope: String? = nil
    var showControls = false
    private var summary: CompanionActivityRange? { activity?.ranges.first { $0.range == range } }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if showControls {
                    MeterMetricControls(scope: controlScope, isCost: isCost)
                } else {
                    Image(systemName: isCost ? "dollarsign.circle" : "chart.xyaxis.line")
                        .foregroundStyle(.secondary).font(.system(size: 15))
                    Text(isCost ? "API cost" : "Tokens").font(.system(size: 14, weight: .bold))
                }
                Spacer(minLength: 0)
                Text(range.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(
                    .secondary
                )
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.primary.opacity(0.05), in: Capsule())
            }
            if let summary, let activity {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(figure(summary.tokens, summary.cost))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .tracking(-1).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                        Text(isCost ? "Estimated USD" : "Processed tokens")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if medium {
                        MeterActivitySparkline(
                            values: summary.bucketStarts.indices.map { index in
                                summary.providers.reduce(0) { sum, provider in
                                    sum
                                        + (isCost
                                            ? provider.bucketCost[index]
                                            : Double(provider.bucketTokens[index]))
                                }
                            }
                        ).frame(maxWidth: .infinity).frame(height: 38)
                    }
                }
                if medium {
                    HStack(spacing: 16) {
                        ForEach(Array(summary.providers.prefix(3))) { provider in
                            HStack(spacing: 5) {
                                MeterProviderMark(name: provider.name, size: 11)
                                Text(figure(provider.tokens, provider.cost))
                                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                    .lineLimit(1)
                            }.accessibilityLabel(
                                "\(provider.name) \(figure(provider.tokens, provider.cost))")
                        }
                    }
                }
                Spacer(minLength: 0)
                MeterWidgetFreshness(capturedAt: activity.capturedAt, now: now)
            } else {
                Spacer(minLength: 0)
                Text("Open the app to sync activity from your Mac.").font(.caption).foregroundStyle(
                    .secondary)
                Spacer(minLength: 0)
            }
        }
    }
    private func figure(_ tokens: Int, _ cost: Double) -> String {
        MeterWidgetStyle.figure(tokens: tokens, cost: cost, isCost: isCost)
    }
}

private struct MeterActivitySparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geometry in
            let maximum = max(1, values.max() ?? 1)
            Path { path in
                for index in values.indices {
                    let point = CGPoint(
                        x: geometry.size.width * Double(index) / Double(max(1, values.count - 1)),
                        y: geometry.size.height * (1 - values[index] / maximum))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }.stroke(
                .secondary.opacity(0.5),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}

/// Widget gallery examples only; these values are never cached or published.
enum MeterWidgetSample {
    static var snapshot: CompanionSnapshot {
        let now = Date.now
        let dates = (0..<7).map { now.addingTimeInterval(Double($0 - 6) * 86400) }
        let tokens = [620_000, 1_200_000, 850_000, 1_580_000, 960_000, 1_440_000, 430_000]
        let costs = tokens.map { Double($0) * 0.000008 }
        let activity = CompanionActivity(
            capturedAt: now, timeZoneIdentifier: "UTC",
            ranges: CompanionRange.allCases.map {
                CompanionActivityRange(
                    range: $0, bucketStarts: dates,
                    providers: [
                        CompanionProviderActivity(
                            name: "Claude", tokens: tokens.reduce(0, +), cost: costs.reduce(0, +),
                            unpricedTokens: 0, sessions: 28, bucketTokens: tokens, bucketCost: costs
                        )
                    ])
            })
        return CompanionSnapshot(
            sourceID: UUID(uuidString: "3FD01E8D-73C9-4546-A4A7-D0D6213EC3F5")!,
            sourceName: "My Mac", revision: 0, publishedAt: now,
            providers: [
                CompanionProvider(
                    name: "Claude", plan: "Max", capturedAt: now, status: .available,
                    windows: [
                        CompanionWindow(
                            id: "5h", pool: nil, label: "5h", usedPercent: 14,
                            resetAt: now.addingTimeInterval(4020), duration: 18000),
                        CompanionWindow(
                            id: "weekly", pool: "all", label: "Weekly", usedPercent: 93,
                            resetAt: now.addingTimeInterval(50400), duration: 604800),
                    ]),
                CompanionProvider(
                    name: "Codex", plan: "Pro", capturedAt: now, status: .available,
                    windows: [
                        CompanionWindow(
                            id: "weekly", pool: nil, label: "Weekly", usedPercent: 24,
                            resetAt: now.addingTimeInterval(172800), duration: 604800)
                    ]),
            ], activity: activity)
    }
}
