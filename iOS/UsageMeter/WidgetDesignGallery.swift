#if DEBUG
import CompanionKit
import SwiftUI

/// Development-only gallery of the exact widget content at Home Screen sizes.
struct WidgetDesignGallery: View {
    private let now = Date.now
    @Environment(\.colorScheme) private var scheme
    private var provider: CompanionProvider {
        CompanionProvider(
            name: "Claude", plan: "Max", capturedAt: now.addingTimeInterval(-1800),
            status: .available,
            windows: [
                CompanionWindow(
                    id: "5h", pool: nil, label: "5h", usedPercent: 14,
                    resetAt: now.addingTimeInterval(4020), duration: 18000),
                CompanionWindow(
                    id: "weekly", pool: "all", label: "Weekly", usedPercent: 93,
                    resetAt: now.addingTimeInterval(50400), duration: 604800),
            ])
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Widget design").font(.largeTitle.bold())
                Text("Limits · medium").font(.caption).foregroundStyle(.secondary)
                surface(width: 338, height: 158, accent: MeterWidgetStyle.accent("Claude")) {
                    MeterLimitsDesign(
                        provider: provider, windows: provider.windows, now: now,
                        medium: true, remaining: false, availableProviders: ["Claude", "Codex"],
                        selectedChoice: "claude", showControls: true)
                }
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Limits · small").font(.caption).foregroundStyle(.secondary)
                        surface(width: 158, height: 158, accent: MeterWidgetStyle.accent("Claude"))
                        {
                            MeterLimitsDesign(
                                provider: provider, windows: provider.windows, now: now,
                                medium: false, remaining: false,
                                availableProviders: ["Claude", "Codex"], selectedChoice: "claude",
                                showControls: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Cost · small").font(.caption).foregroundStyle(.secondary)
                        surface(width: 158, height: 158, accent: .gray) {
                            MeterActivityDesign(
                                activity: CompanionStore.demoActivity, range: .week,
                                now: now, medium: false, isCost: true, showControls: true)
                        }
                    }
                }
                Text("Tokens · medium").font(.caption).foregroundStyle(.secondary)
                surface(width: 338, height: 158, accent: .gray) {
                    MeterActivityDesign(
                        activity: CompanionStore.demoActivity, range: .week,
                        now: now, medium: true, isCost: false, showControls: true)
                }
                Text("Remaining quota · medium").font(.caption).foregroundStyle(.secondary)
                surface(width: 338, height: 158, accent: MeterWidgetStyle.accent("Claude")) {
                    MeterLimitsDesign(
                        provider: provider, windows: provider.windows, now: now,
                        medium: true, remaining: true, availableProviders: ["Claude", "Codex"],
                        selectedChoice: "claude", showControls: true)
                }
            }.padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
    private func surface<Content: View>(
        width: CGFloat, height: CGFloat, accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content().padding(16).frame(width: width, height: height)
            .background { MeterWidgetBackground(accent: accent) }
            .clipShape(.rect(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.04)) }
    }
}
#endif
