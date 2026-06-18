import SwiftUI

struct UsageBarApp: App {
    @StateObject private var store = UsageStore.shared

    init() {
        Task { @MainActor in UsageStore.shared.startAutoRefresh() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            MenuBarLabel(peak: store.peakFiveHour, hasError: anyError)
        }
        .menuBarExtraStyle(.window)
    }

    private var anyError: Bool {
        store.providers.contains { $0.error != nil }
    }
}

/// Compact label shown in the menu bar itself.
private struct MenuBarLabel: View {
    let peak: Double
    let hasError: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: hasError ? "gauge.with.dots.needle.bottom.50percent"
                                       : "gauge.with.dots.needle.bottom.50percent")
            Text(Format.percent(peak))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }
}
