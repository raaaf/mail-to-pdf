import Observation
import ServiceManagement
import os

/// Wraps `SMAppService.mainApp` for the "Bei Anmeldung starten" settings toggle.
@MainActor
@Observable
final class LoginItemManager {
    private static let logger = Logger(subsystem: "de.rafaelalex.MailToPDF", category: "login-item")

    /// `.requiresApproval` (the user hasn't confirmed it in System Settings yet) and
    /// `.notFound`/`.notRegistered` all read as "not enabled"; only `.enabled` is true.
    var isEnabled: Bool

    init() {
        isEnabled = Self.currentlyEnabled()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Self.logger.error("Failed to \(enabled ? "register" : "unregister", privacy: .public) login item: \(String(describing: error), privacy: .public)")
        }
        // Re-read rather than assume success: register() can leave status at .requiresApproval
        // instead of .enabled, and a failed call should visibly snap the toggle back.
        isEnabled = Self.currentlyEnabled()
    }

    private static func currentlyEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }
}
