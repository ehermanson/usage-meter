import CompanionKit
import SwiftUI

extension Color {
    static let companionCanvas = Color(uiColor: .systemGroupedBackground)
    static let companionCard = Color(uiColor: .secondarySystemGroupedBackground)
    static func provider(_ name: String) -> Color {
        switch name {
        case "Claude": Color(red: 0.85, green: 0.40, blue: 0.23)
        case "Codex": Color(red: 0.22, green: 0.52, blue: 0.48)
        default: .blue
        }
    }
}

struct CompanionCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.companionCard, in: .rect(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.05)) }
    }
}

struct ProviderHeading: View {
    let name: String
    var plan: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            Image(
                name == "Claude" ? "claude-logo" : name == "Codex" ? "openai-logo" : "gemini-logo"
            )
            .resizable().renderingMode(.template).scaledToFit().frame(width: 25, height: 25)
            .accessibilityHidden(true)
            Text(name).font(.title3.weight(.bold))
            if let plan {
                Text(plan).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.primary.opacity(0.05), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }
}

enum CompanionFormat {
    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return value.formatted()
    }
    static func cost(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
    static func countdown(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes < 1 { return "<1m" }
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

struct CompanionLimitsCard: View {
    let provider: CompanionProvider
    let now: Date
    let showRemaining: Bool
    var body: some View {
        CompanionCard {
            VStack(alignment: .leading, spacing: 22) {
                ProviderHeading(name: provider.name, plan: provider.plan)
                if provider.isExpired(at: now) {
                    Label("No current reading", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(provider.windows) { window in
                        CompanionQuotaRow(
                            window: window, now: now, showRemaining: showRemaining,
                            showPace: !provider.isStale(at: now) && provider.status == .available,
                            accent: .provider(provider.name))
                    }
                }
                if let credits = provider.resetCredits, credits.available > 0,
                    !provider.isExpired(at: now)
                {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Label(
                            "\(credits.available) free reset\(credits.available == 1 ? "" : "s")",
                            systemImage: "arrow.counterclockwise"
                        )
                        .font(.subheadline.weight(.semibold))
                        if let expiry = credits.earliestExpiry {
                            Text(
                                expiry <= now
                                    ? "Credit expiry passed · awaiting a new reading"
                                    : "First expires \(expiry.formatted(.dateTime.month(.abbreviated).day()))"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Redeem a reset from your Mac.").font(.caption).foregroundStyle(
                            .secondary)
                    }
                }
                if let captured = provider.capturedAt {
                    HStack(spacing: 4) {
                        Text("Observed")
                        Text(captured, style: .relative)
                        Text("ago")
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                if provider.status != .available || provider.isStale(at: now)
                    || provider.windows.isEmpty
                {
                    Label(status, systemImage: "info.circle").font(.caption).foregroundStyle(
                        .secondary)
                }
            }
        }
    }
    private var status: String {
        if provider.status == .needsSetup { return "Finish setup on your Mac." }
        if provider.status == .temporarilyUnavailable {
            return "Provider unavailable. Showing the last observation."
        }
        if provider.windows.isEmpty { return "No usage windows reported by this provider." }
        return
            "Waiting for a fresh reading from your Mac. Make sure it’s awake and iPhone sync is enabled."
    }
}

private struct CompanionQuotaRow: View {
    let window: CompanionWindow
    let now: Date
    let showRemaining: Bool
    let showPace: Bool
    let accent: Color
    private var value: Double { showRemaining ? 1 - window.fraction : window.fraction }
    private var color: Color {
        window.fraction >= 0.9 ? .red : window.fraction >= 0.75 ? .yellow : accent
    }
    private var elapsed: Double? {
        guard showPace, let reset = window.resetAt, let duration = window.duration,
            duration > 0, reset > now, reset.timeIntervalSince(now) <= duration + 120,
            window.usedPercent < 100
        else { return nil }
        return max(0, 1 - reset.timeIntervalSince(now) / duration)
    }
    private var caption: String {
        if window.needsNewReading(at: now) { return "Reset passed · awaiting a new reading" }
        guard let elapsed else { return "" }
        let expected = elapsed * 100
        let projected = elapsed > 0 ? window.usedPercent / elapsed : .infinity
        if projected >= 110 && window.usedPercent - expected >= 3 { return "Ahead of pace" }
        if projected <= 85 && window.usedPercent - expected <= -3 {
            let percent = showRemaining ? max(0, 100 - projected) : projected
            return
                "Room to spare · ~\(Int(percent.rounded()))% \(showRemaining ? "left at reset" : "at reset")"
        }
        return "On pace"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title; Spacer(minLength: 8); percentage
                }
                VStack(alignment: .leading, spacing: 5) {
                    title; percentage
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.07))
                    Capsule().fill(color.gradient).frame(width: geometry.size.width * value)
                    if let elapsed {
                        Capsule().fill(.primary.opacity(0.42)).frame(width: 2, height: 14)
                            .offset(
                                x: max(
                                    0,
                                    geometry.size.width * (showRemaining ? 1 - elapsed : elapsed)
                                        - 1))
                    }
                }
            }.frame(height: 10).accessibilityHidden(true)
            if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(window.pool.map { "\(window.label) · \($0)" } ?? window.label).font(
                .subheadline.weight(.semibold))
            if let reset = window.resetAt, reset > now {
                Text(CompanionFormat.countdown(reset, now: now)).font(.caption).foregroundStyle(
                    .secondary
                )
                .monospacedDigit()
            }
        }
    }
    private var percentage: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text((value * 100).formatted(.number.precision(.fractionLength(0))) + "%")
                .font(.headline).monospacedDigit()
            Text(showRemaining ? "left" : "used").font(.caption).foregroundStyle(.secondary)
        }
    }
}
