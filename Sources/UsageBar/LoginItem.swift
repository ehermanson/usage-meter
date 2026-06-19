import Foundation
import ServiceManagement

/// Registers the app as a macOS login item via SMAppService (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true on success. Failures are logged and reported back so the UI
    /// toggle can revert.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("[UsageBar] Login-item toggle failed: \(error.localizedDescription)")
            return false
        }
    }
}
