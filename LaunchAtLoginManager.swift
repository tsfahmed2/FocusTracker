import Foundation
import ServiceManagement
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - LaunchAtLoginManager
//
// Wraps SMAppService.mainApp so SwiftUI views can bind to it directly.
// SMAppService handles the system registration — no LaunchAgent plist needed.
//
// Requirements:
//   • macOS 13+  (SMAppService was introduced in Ventura)
//   • The app must be in /Applications or ~/Applications for registration
//     to succeed. Running from Xcode's DerivedData will return an error.
// ─────────────────────────────────────────────────────────────────────────────

final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    /// Whether the app is currently registered to launch at login.
    @Published private(set) var isEnabled: Bool = false

    /// Non-nil when the last register/unregister call failed.
    @Published private(set) var lastError: String? = nil

    private init() {
        refresh()
    }

    // ── Read current state ─────────────────────────────────────────────────

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    // ── Toggle ─────────────────────────────────────────────────────────────

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            // Common failure: app is not in /Applications.
            // Surface a friendly message instead of a raw error code.
            lastError = friendlyError(error, enabling: enabled)
            // Revert the published value to match actual state
            isEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    // ── Status description (for Settings UI) ──────────────────────────────

    var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Enabled — will launch at login"
        case .requiresApproval:
            return "Pending — approve in System Settings → General → Login Items"
        case .notRegistered:
            return "Disabled"
        case .notFound:
            return "Not available — move app to /Applications first"
        @unknown default:
            return "Unknown"
        }
    }

    var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    private func friendlyError(_ error: Error, enabling: Bool) -> String {
        let action = enabling ? "enable" : "disable"
        let code   = (error as NSError).code

        // SMAppService error codes
        switch code {
        case 1: return "Cannot \(action) launch at login — move Focus Tracker to /Applications first."
        case 2: return "Launch at login was blocked by a system policy."
        default: return "Could not \(action) launch at login: \(error.localizedDescription)"
        }
    }

    // ── Open Login Items settings ──────────────────────────────────────────

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
