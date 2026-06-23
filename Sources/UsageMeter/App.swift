import SwiftUI

struct UsageMeterApp: App {
    @State private var store = UsageStore.shared

    init() {
        Task { @MainActor in UsageStore.shared.startAutoRefresh() }
        Task { @MainActor in await UpdateChecker.shared.check() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            Image(
                nsImage: MenuBarRenderer.image(
                    icon: store.menuBarIcon,
                    title: store.menuBarTitle))
        }
        .menuBarExtraStyle(.window)
    }
}
