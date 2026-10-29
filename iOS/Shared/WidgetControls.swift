import AppIntents
import CompanionKit
import SwiftUI
import WidgetKit

struct MeterWidgetSelectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Change widget display"
    static var isDiscoverable: Bool { false }
    @Parameter(title: "Widget configuration") var scope: String
    @Parameter(title: "Display") var value: String
    init() {}
    init(scope: String, value: String) { self.scope = scope; self.value = value }
    func perform() async throws -> some IntentResult {
        guard
            CompanionWidgetSelection.set(
                scope: scope, value: value,
                defaults: UserDefaults(suiteName: CompanionConfiguration.appGroup))
        else {
            throw SelectionError.invalid
        }
        WidgetCenter.shared.reloadTimelines(
            ofKind: scope.hasPrefix("limits.") ? "UsageMeterLimits" : "UsageMeterActivity")
        return .result()
    }
    private enum SelectionError: LocalizedError {
        case invalid
        var errorDescription: String? { "This widget selection is unavailable." }
    }
}

struct MeterWidgetChoiceButton<Label: View>: View {
    let scope: String?
    let value: String
    let selected: Bool
    let accessibilityTitle: String
    @ViewBuilder let label: Label
    var body: some View {
        Group {
            if let scope {
                Button(intent: MeterWidgetSelectionIntent(scope: scope, value: value)) {
                    appearance
                }
            } else {
                // Development gallery controls never change real widget preferences.
                Button {
                } label: {
                    appearance
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var appearance: some View {
        label.frame(minWidth: 28, minHeight: 28)
            .background(.primary.opacity(selected ? 0.09 : 0.025), in: Capsule())
            .overlay {
                Capsule().strokeBorder(.primary.opacity(selected ? 0.12 : 0), lineWidth: 0.5)
            }
    }
}

struct MeterProviderControls: View {
    let scope: String?
    let names: [String]
    let selected: String
    let medium: Bool
    var visibleProvider: String? = nil
    private var choices: [String] {
        names.map { $0.lowercased() }.filter { ["claude", "codex", "gemini"].contains($0) }
    }
    var body: some View {
        if medium {
            HStack(spacing: 4) {
                ForEach(choices, id: \.self) { choice in
                    MeterWidgetChoiceButton(
                        scope: scope, value: choice,
                        selected: (visibleProvider?.lowercased() ?? selected) == choice,
                        accessibilityTitle: "Show \(name(choice))"
                    ) {
                        MeterProviderMark(name: name(choice), size: 13)
                    }
                }
            }
        } else if choices.count > 1 || (visibleProvider == nil && !choices.isEmpty) {
            let current =
                selected == "tightest" ? visibleProvider?.lowercased() ?? selected : selected
            let index = choices.firstIndex(of: current) ?? -1
            let next = choices[(index + 1) % choices.count]
            MeterWidgetChoiceButton(
                scope: scope, value: next, selected: false,
                accessibilityTitle: "Switch to \(name(next))"
            ) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
    private func name(_ choice: String) -> String {
        switch choice {
        case "claude": "Claude";
        case "codex": "Codex";
        case "gemini": "Gemini";
        default: choice
        }
    }
}

struct MeterMetricControls: View {
    let scope: String?
    let isCost: Bool
    var body: some View {
        HStack(spacing: 2) {
            ForEach(["tokens", "cost"], id: \.self) { metric in
                MeterWidgetChoiceButton(
                    scope: scope, value: metric,
                    selected: (metric == "cost") == isCost,
                    accessibilityTitle: metric == "cost"
                        ? "Show API-equivalent cost" : "Show processed tokens"
                ) {
                    Text(metric == "cost" ? "Cost" : "Tokens")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle((metric == "cost") == isCost ? .primary : .secondary)
                        .padding(.horizontal, 6)
                }
            }
        }
    }
}
