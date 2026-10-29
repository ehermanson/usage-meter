import BackgroundTasks
import SwiftUI
import UIKit

@main
struct UsageMeterCompanionApp: App {
    @UIApplicationDelegateAdaptor(CompanionAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = CompanionStore.shared

    var body: some Scene {
        WindowGroup {
            rootView
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        await store.refresh()
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    }
                }
                .onOpenURL { url in
                    if url.host == "connect" { Task { await store.connect(url) } }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { CompanionAppDelegate.scheduleRefresh() }
                }
        }
    }
    @ViewBuilder private var rootView: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--widget-design-preview") {
            WidgetDesignGallery()
        } else {
            CompanionDashboard(store: store)
        }
        #else
        CompanionDashboard(store: store)
        #endif
    }

}

@MainActor
final class CompanionAppDelegate: NSObject, UIApplicationDelegate {
    static let refreshID = "com.erichermanson.usagemeter.ios.refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
            Task { @MainActor in
                guard let task = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false); return
                }
                Self.scheduleRefresh()
                let work = Task { await CompanionStore.shared.refresh() }
                task.expirationHandler = { work.cancel() }
                let success = await work.value
                task.setTaskCompleted(success: success && !work.isCancelled)
            }
        }
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let changed = await CompanionStore.shared.refresh()
            completionHandler(changed ? .newData : .noData)
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date.now.addingTimeInterval(900)
        try? BGTaskScheduler.shared.submit(request)
    }
}
