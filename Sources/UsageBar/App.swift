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
            MenuBarLabel(title: store.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Compact label shown in the menu bar itself. The icon is deliberately left
/// uncolored — only the in-dropdown bars change color with usage.
private struct MenuBarLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }
}
