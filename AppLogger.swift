import Foundation
import os

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppLogger
//
// Implements macOS unified logging (os.Logger) for the app.
//
// Why unified logging for a distributed app:
//   • Users inspect logs via Console.app — the standard macOS workflow
//   • Logs are automatically size-limited and rotated by the OS
//   • Privacy controls built in (we mark fields .public/.private explicitly)
//   • Survives reboots and integrates with sysdiagnose for support tickets
//   • No need for "where do my logs go?" UI — Console.app handles it
//
// Console.app filtering:
//   subsystem:com.khan.FocusTracker
//
// Or from terminal:
//   log stream --predicate 'subsystem == "com.khan.FocusTracker"' --level info
// ─────────────────────────────────────────────────────────────────────────────

final class AppLogger {
    static let shared = AppLogger()

    private let subsystem = Bundle.main.bundleIdentifier ?? "com.khan.FocusTracker"

    // Separate categories so users can filter on what they care about
    private lazy var lifecycle  = Logger(subsystem: subsystem, category: "lifecycle")
    private lazy var focus      = Logger(subsystem: subsystem, category: "focus-event")
    private lazy var anomaly    = Logger(subsystem: subsystem, category: "anomaly")
    private lazy var permission = Logger(subsystem: subsystem, category: "permissions")
    private lazy var scoring    = Logger(subsystem: subsystem, category: "scoring")

    private init() {}

    // ── Lifecycle ──────────────────────────────────────────────────────────

    func logStartup(inputMonitoring: Bool, accessibility: Bool) {
        lifecycle.info("""
        FocusTracker started — \
        accessibility=\(accessibility, privacy: .public) \
        inputMonitoring=\(inputMonitoring, privacy: .public)
        """)
    }

    func logShutdown() {
        lifecycle.info("FocusTracker stopping")
    }

    func logUserClearedEvents() {
        lifecycle.notice("User cleared in-memory event history")
    }

    // ── Focus events ───────────────────────────────────────────────────────

    /// Log a focus event in a Console-friendly format.
    /// App names and window titles are marked .public so they're readable
    /// in Console.app. (They're already visible in the menu bar UI; this
    /// just matches that visibility level.)
    func logFocusEvent(
        appName: String,
        bundleID: String?,
        pid: Int32,
        trigger: String,
        suspicion: Int,
        windowTitle: String?,
        triggerDetail: String,
        msSinceLastInput: Int?,
        anomalyTypes: [String]
    ) {
        let inputMs = msSinceLastInput.map(String.init) ?? "—"
        let title   = windowTitle ?? "—"
        let bid     = bundleID ?? "—"
        let anom    = anomalyTypes.isEmpty ? "—" : anomalyTypes.joined(separator: ",")

        // Use .info for normal events, .notice for programmatic/suspicious ones.
        // .notice is preserved longer in the system log buffer.
        if trigger == "programmatic" || suspicion >= 60 {
            focus.notice("""
            FOCUS \(trigger, privacy: .public) \
            susp=\(suspicion, privacy: .public)/100 \
            app=\(appName, privacy: .public) (\(bid, privacy: .public)) \
            pid=\(pid, privacy: .public) \
            window=\(title, privacy: .public) \
            input_ms=\(inputMs, privacy: .public) \
            anomalies=[\(anom, privacy: .public)] \
            detail=\(triggerDetail, privacy: .public)
            """)
        } else {
            focus.info("""
            FOCUS \(trigger, privacy: .public) \
            susp=\(suspicion, privacy: .public) \
            app=\(appName, privacy: .public) \
            window=\(title, privacy: .public)
            """)
        }
    }

    // ── Anomalies ──────────────────────────────────────────────────────────

    func logAnomaly(type: String, detail: String,
                    appName: String, bundleID: String, pid: Int32) {
        anomaly.notice("""
        ANOMALY \(type, privacy: .public) — \
        app=\(appName, privacy: .public) (\(bundleID, privacy: .public)) \
        pid=\(pid, privacy: .public) \
        detail=\(detail, privacy: .public)
        """)
    }

    // ── Permissions ────────────────────────────────────────────────────────

    func logPermissionChange(name: String, granted: Bool) {
        if granted {
            permission.info("Permission granted: \(name, privacy: .public)")
        } else {
            permission.notice("Permission revoked or not granted: \(name, privacy: .public)")
        }
    }

    func logPermissionError(_ message: String) {
        permission.error("\(message, privacy: .public)")
    }

    // ── Ignore list ────────────────────────────────────────────────────────

    func logIgnoreChange(bundleID: String, ignored: Bool) {
        if ignored {
            lifecycle.notice("App added to ignore list: \(bundleID, privacy: .public)")
        } else {
            lifecycle.notice("App removed from ignore list: \(bundleID, privacy: .public)")
        }
    }

    // ── Scoring (debug mode only) ──────────────────────────────────────────
    /// Logs a complete scoring breakdown for a single focus event.
    /// Only called when DebugMode is enabled.
    func logScoring(appName: String, breakdown: ScoreBreakdown) {
        // The full breakdown contains explanations the user wrote (.public)
        scoring.debug("""
        SCORING TRACE for \(appName, privacy: .public)
        \(breakdown.multilineDescription(), privacy: .public)
        """)
    }

    // ── Generic error path ─────────────────────────────────────────────────

    func logError(_ category: String, _ message: String) {
        Logger(subsystem: subsystem, category: category)
            .error("\(message, privacy: .public)")
    }
}
