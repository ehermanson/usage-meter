import SwiftUI

struct UsageBarApp: App {
    @State private var store = UsageStore.shared

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
