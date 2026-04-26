import UserNotifications
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NotificationManager
//
// Wraps UNUserNotificationCenter for "focus stolen" alerts.
//
// Design notes:
//
// • Rate-limited per bundle ID: a single misbehaving app stealing focus
//   repeatedly would otherwise spam the user with banners. We collapse
//   alerts from the same bundle ID inside a 60s window.
//
// • Notifications are enabled by default on first install. The OS-level
//   authorization dialog is the real gate. If the user denies that, our
//   in-app toggle being "on" is harmless because center.add will simply
//   no-op.
//
// • Authorization status is cached and refreshed on a slow timer rather
//   than queried on every event. UNUserNotificationCenter API is async
//   and can be slow under load.
// ─────────────────────────────────────────────────────────────────────────────

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    // Rate-limit: at most one notification per bundle ID per window.
    private let rateLimitWindow: TimeInterval = 60
    private var lastNotifiedAt: [String: Date] = [:]

    // Cached auth status (refreshed on a slow timer)
    private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    // ── Settings (persisted) ───────────────────────────────────────────────

    var suspicionThreshold: Int {
        get { UserDefaults.standard.integer(forKey: "ft.notifThreshold").nonZero ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "ft.notifThreshold") }
    }

    var notificationsEnabled: Bool {
        get {
            // Default: ON. The OS dialog is the real gate.
            if UserDefaults.standard.object(forKey: "ft.notifEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "ft.notifEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "ft.notifEnabled") }
    }

    private override init() {
        super.init()
        center.delegate = self
        refreshAuthorizationStatus()
        // Refresh cached auth status periodically — user could change
        // notification permission in System Settings without our knowledge.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshAuthorizationStatus()
        }
    }

    // ── Authorization ──────────────────────────────────────────────────────

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if let error {
                AppLogger.shared.logError("notifications",
                    "Authorization error: \(error.localizedDescription)")
            }
            self?.refreshAuthorizationStatus()
            DispatchQueue.main.async {
                AppLogger.shared.logPermissionChange(
                    name: "notifications",
                    granted: granted
                )
            }
        }
    }

    private func refreshAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            self?.authorizationStatus = settings.authorizationStatus
        }
    }

    // ── Send ───────────────────────────────────────────────────────────────

    func considerNotifying(for event: FocusEvent) {
        guard notificationsEnabled,
              authorizationStatus == .authorized || authorizationStatus == .provisional,
              event.suspicion >= suspicionThreshold,
              event.trigger == .programmatic
        else { return }

        // Rate-limit per bundle ID. Use bundleID if present, else app name
        // (so unidentifiable apps don't all share one rate-limit slot).
        let key = event.bundleID ?? "name:\(event.appName)"
        if let last = lastNotifiedAt[key],
           Date().timeIntervalSince(last) < rateLimitWindow {
            return
        }
        lastNotifiedAt[key] = Date()

        send(
            title: "Focus Stolen by \(event.appName)",
            body: buildBody(for: event),
            identifier: "steal-\(event.id.uuidString)"
        )
    }

    private func buildBody(for event: FocusEvent) -> String {
        var parts: [String] = []
        parts.append("Suspicion: \(event.suspicion)/100")
        if let ms = event.msSinceLastInput {
            parts.append("\(ms)ms since last input")
        }
        if let title = event.windowTitle, !title.isEmpty {
            parts.append("Window: \"\(title)\"")
        }
        if !event.triggerDetail.isEmpty && event.triggerDetail != "normal" {
            parts.append(event.triggerDetail)
        }
        return parts.joined(separator: " · ")
    }

    func send(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        content.categoryIdentifier = "FOCUS_STEAL"

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                AppLogger.shared.logError("notifications",
                    "Failed to deliver: \(error.localizedDescription)")
            }
        }
    }

    // ── Delegate ───────────────────────────────────────────────────────────

    /// Allow notifications even when app is in foreground.
    /// (Menu bar apps are always "foreground" from UNUNC's perspective.)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler handler: @escaping () -> Void
    ) {
        // User clicked a notification — open the popover
        DispatchQueue.main.async {
            AppDelegate.shared?.showPopover()
        }
        handler()
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
