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
            MenuBarLabel(icon: store.menuBarIcon, title: store.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Compact label shown in the menu bar itself. The gauge needle tracks the
/// pinned provider's 5hr usage; the icon is deliberately left uncolored —
/// only the in-dropdown bars change color with usage.
private struct MenuBarLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }
}
