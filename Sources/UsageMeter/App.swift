import SwiftUI

struct UsageMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu-bar item and its dropdown are built in the AppDelegate via a
        // custom NSStatusItem + NSPanel (see StatusBarController) so we control
        // the panel's placement; SwiftUI's MenuBarExtra positions it unreliably.
        // This empty Settings scene just satisfies the App protocol.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(store: .shared)
        UsageStore.shared.startAutoRefresh()
        Task { await UpdateChecker.shared.check() }
    }
}
