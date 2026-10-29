import AppIntents
import CloudKit
import CompanionKit
import SwiftUI
import WidgetKit

enum WidgetProviderChoice: String, AppEnum {
    case tightest, claude, codex, gemini
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .tightest: "Closest to limit", .claude: "Claude", .codex: "Codex", .gemini: "Gemini",
    ]
    var providerName: String? {
        switch self {
        case .tightest: nil
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }
}

struct LimitsWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage limits"
    static let description = IntentDescription(
        "Choose a provider from your connected Mac.")
    @Parameter(title: "Provider", default: .tightest) var provider: WidgetProviderChoice
}

struct LimitsEntry: TimelineEntry {
    let date: Date
    let snapshot: CompanionSnapshot?
    let choice: WidgetProviderChoice
    var configuredChoice: WidgetProviderChoice = .tightest

    var connectedProviders: [CompanionProvider] {
        (snapshot?.providers ?? []).filter(\.hasConnectedLimits)
    }

    var windows: [CompanionWindow] {
        let windows = provider?.windows ?? []
        return choice == .tightest ? windows.sorted { $0.fraction > $1.fraction } : windows
    }

    var provider: CompanionProvider? {
        if let name = choice.providerName {
            return connectedProviders.first { $0.name == name } ?? connectedProviders.first
        }
        return connectedProviders.filter { !$0.isExpired(at: date) }
            .max {
                ($0.windows.map(\.fraction).max() ?? 0)
                    < ($1.windows.map(\.fraction).max() ?? 0)
            }
    }
}

struct LimitsTimelineProvider: AppIntentTimelineProvider {
    var skipNetwork = false
    func placeholder(in context: Context) -> LimitsEntry {
        LimitsEntry(date: .now, snapshot: MeterWidgetSample.snapshot, choice: .tightest)
    }

    func snapshot(
        for configuration: LimitsWidgetConfiguration, in context: Context
    ) async -> LimitsEntry {
        if context.isPreview {
            return LimitsEntry(
                date: .now, snapshot: MeterWidgetSample.snapshot, choice: configuration.provider,
                configuredChoice: configuration.provider)
        }
        return await timeline(for: configuration, in: context).entries[0]
    }

    func timeline(
        for configuration: LimitsWidgetConfiguration, in context: Context
    ) async -> Timeline<LimitsEntry> {
        var cache = CompanionCacheFile.load(from: CompanionCacheFile.url)
        let defaults = UserDefaults(suiteName: CompanionConfiguration.appGroup)
        let scope = "limits.\(configuration.provider.rawValue)"
        let useCache =
            skipNetwork
            || CompanionWidgetSelection.recentlyChanged(scope: scope, defaults: defaults)
        if let sourceID = cache.selectedSourceID, !useCache {
            do {
                let cloud = CloudSnapshotService()
                let identity = try await cloud.accountID()
                if identity != cache.accountID {
                    cache = try CompanionCacheFile.clear(
                        ifMatching: cache, at: CompanionCacheFile.url)
                } else {
                    let fresh = try await cloud.fetch(sourceID)
                    cache = try CompanionCacheFile.refresh(
                        fresh, accountID: identity, at: CompanionCacheFile.url)
                }
            } catch {
                if (error as? CompanionError) == .noAccount
                    || (error as? CKError)?.code == .notAuthenticated
                {
                    cache =
                        (try? CompanionCacheFile.clear(
                            ifMatching: cache, at: CompanionCacheFile.url)) ?? CompanionCache()
                } else if let error = error as? CompanionError, case .sourceNotFound = error {
                    cache =
                        (try? CompanionCacheFile.clear(
                            ifMatching: cache, at: CompanionCacheFile.url)) ?? CompanionCache()
                }
                // Network failure keeps the last reading with its original date.
            }
        }
        // Another process may have changed selection during any network outcome.
        cache = CompanionCacheFile.load(from: CompanionCacheFile.url)
        let now = Date.now
        var dates: Set<Date> = [now]
        // Compact ages update locally even when iOS delays a network reload.
        for minutes in [5, 15, 30, 45, 60] + (2...24).map({ $0 * 60 }) {
            dates.insert(now.addingTimeInterval(Double(minutes) * 60))
        }
        for provider in cache.snapshot?.providers ?? [] {
            if let captured = provider.capturedAt {
                for date in [captured.addingTimeInterval(600), captured.addingTimeInterval(86400)]
                where date > now {
                    dates.insert(date)
                }
            }
            for window in provider.windows {
                if let reset = window.resetAt, reset > now { dates.insert(reset) }
            }
        }
        // Future entries label stale, reset, and expired readings even if iOS
        // postpones network reloads. They never fabricate fresh provider values.
        let choice =
            WidgetProviderChoice(
                rawValue: CompanionWidgetSelection.value(
                    scope: scope, fallback: configuration.provider.rawValue, defaults: defaults))
            ?? configuration.provider
        let entries = dates.sorted().map {
            LimitsEntry(
                date: $0, snapshot: cache.snapshot, choice: choice,
                configuredChoice: configuration.provider)
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(900)))
    }
}

struct LimitsWidgetView: View {
    let entry: LimitsEntry
    @Environment(\.widgetFamily) private var family
    @AppStorage("showRemaining", store: UserDefaults(suiteName: CompanionConfiguration.appGroup))
    private var showRemaining = false

    var body: some View {
        MeterLimitsDesign(
            provider: entry.provider, windows: entry.windows, now: entry.date,
            medium: family == .systemMedium, remaining: showRemaining,
            connected: entry.snapshot != nil,
            controlScope: "limits.\(entry.configuredChoice.rawValue)",
            availableProviders: entry.connectedProviders.map(\.name),
            selectedChoice: entry.choice.rawValue, showControls: true
        )
        .containerBackground(for: .widget) {
            MeterWidgetBackground(accent: MeterWidgetStyle.accent(entry.provider?.name ?? ""))
        }
        .widgetURL(URL(string: "usagemeter://dashboard"))
    }
}

struct UsageMeterWidgets: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "UsageMeterLimits", intent: LimitsWidgetConfiguration.self,
            provider: LimitsTimelineProvider()
        ) { entry in LimitsWidgetView(entry: entry) }
        .configurationDisplayName("Usage limits")
        .description("Limits and reset times collected by your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

enum ActivityWidgetMetric: String, AppEnum {
    case tokens, cost
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Metric")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .tokens: "Tokens", .cost: "API-equivalent cost",
    ]
}

enum ActivityWidgetRange: String, AppEnum {
    case day, week, month, quarter
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Range")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .day: "24 hours", .week: "7 days", .month: "30 days", .quarter: "90 days",
    ]
}

struct ActivityWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Activity"
    static let description = IntentDescription("Tokens or estimated API cost from your Mac.")
    @Parameter(title: "Metric", default: .tokens) var metric: ActivityWidgetMetric
    @Parameter(title: "Range", default: .week) var range: ActivityWidgetRange
}

struct ActivityWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: CompanionSnapshot?
    let metric: ActivityWidgetMetric
    let range: ActivityWidgetRange
    var configuredMetric: ActivityWidgetMetric = .tokens
}

struct ActivityTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ActivityWidgetEntry {
        ActivityWidgetEntry(
            date: .now, snapshot: MeterWidgetSample.snapshot, metric: .tokens, range: .week)
    }
    func snapshot(
        for configuration: ActivityWidgetConfiguration, in context: Context
    ) async -> ActivityWidgetEntry {
        if context.isPreview {
            return ActivityWidgetEntry(
                date: .now, snapshot: MeterWidgetSample.snapshot,
                metric: configuration.metric, range: configuration.range,
                configuredMetric: configuration.metric)
        }
        return await timeline(for: configuration, in: context).entries[0]
    }
    func timeline(
        for configuration: ActivityWidgetConfiguration, in context: Context
    ) async -> Timeline<ActivityWidgetEntry> {
        let defaults = UserDefaults(suiteName: CompanionConfiguration.appGroup)
        let scope = "activity.\(configuration.metric.rawValue).\(configuration.range.rawValue)"
        let recent = CompanionWidgetSelection.recentlyChanged(scope: scope, defaults: defaults)
        let limits = await LimitsTimelineProvider(skipNetwork: recent).timeline(
            for: LimitsWidgetConfiguration(), in: context)
        let snapshot = limits.entries[0].snapshot
        let now = Date.now
        var dates = [now]
        for minutes in [5, 15, 30, 45, 60] + (2...24).map({ $0 * 60 }) {
            dates.append(now.addingTimeInterval(Double(minutes) * 60))
        }
        if let captured = snapshot?.activity?.capturedAt {
            let stale = captured.addingTimeInterval(600)
            if stale > now { dates.append(stale) }
        }
        let metric =
            ActivityWidgetMetric(
                rawValue: CompanionWidgetSelection.value(
                    scope: scope, fallback: configuration.metric.rawValue, defaults: defaults))
            ?? configuration.metric
        return Timeline(
            entries: dates.sorted().map {
                ActivityWidgetEntry(
                    date: $0, snapshot: snapshot, metric: metric,
                    range: configuration.range, configuredMetric: configuration.metric)
            }, policy: .after(now.addingTimeInterval(900)))
    }
}

struct ActivityWidgetView: View {
    let entry: ActivityWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        MeterActivityDesign(
            activity: entry.snapshot?.activity,
            range: CompanionRange(rawValue: entry.range.rawValue) ?? .week,
            now: entry.date, medium: family == .systemMedium, isCost: entry.metric == .cost,
            controlScope: "activity.\(entry.configuredMetric.rawValue).\(entry.range.rawValue)",
            showControls: true
        )
        .containerBackground(for: .widget) { MeterWidgetBackground(accent: .gray) }
        .widgetURL(
            URL(
                string:
                    "usagemeter://dashboard?tab=\(entry.metric.rawValue)&range=\(entry.range.rawValue)"
            ))
    }
}

struct UsageMeterActivityWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "UsageMeterActivity", intent: ActivityWidgetConfiguration.self,
            provider: ActivityTimelineProvider()
        ) { ActivityWidgetView(entry: $0) }
        .configurationDisplayName("Tokens & Cost")
        .description("Activity summaries from your Mac. Choose tokens or API-equivalent cost.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct UsageMeterWidgetBundle: WidgetBundle {
    var body: some Widget { UsageMeterWidgets(); UsageMeterActivityWidget() }
}
