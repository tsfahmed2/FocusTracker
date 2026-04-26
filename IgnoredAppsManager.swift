import Foundation
import Combine
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - IgnoredAppsManager
//
// User-curated list of apps that should be ignored by the focus monitor.
// Events from ignored apps are dropped at the source — they don't appear in
// the Recent feed, don't contribute to suspect rankings, and don't trigger
// notifications. The list itself remains visible in Settings so users can
// audit and undo ignores.
//
// Persistence: UserDefaults, keyed by bundle ID (stable across renames and
// localizations, unlike app names).
// ─────────────────────────────────────────────────────────────────────────────

final class IgnoredAppsManager: ObservableObject {
    static let shared = IgnoredAppsManager()

    /// Each ignored app captured with enough metadata to display nicely
    /// in Settings even if the app is uninstalled later.
    struct IgnoredApp: Codable, Identifiable, Equatable {
        let bundleID: String
        let appName: String        // last-known display name
        let ignoredAt: Date
        let reason: String?        // optional user note

        var id: String { bundleID }
    }

    @Published private(set) var ignored: [IgnoredApp] = []

    private let key = "ft.ignoredApps"
    private var bundleIDSet: Set<String> = []

    private init() {
        load()
    }

    // ── Query (hot path — must be fast) ────────────────────────────────────

    /// True if the given app should be ignored. Called on every focus event,
    /// so we use a Set lookup rather than scanning the array.
    func shouldIgnore(bundleID: String?) -> Bool {
        guard let bid = bundleID else { return false }
        return bundleIDSet.contains(bid)
    }

    // ── Mutation ───────────────────────────────────────────────────────────

    func ignore(bundleID: String, appName: String, reason: String? = nil) {
        // De-dupe — if already ignored, just update the reason
        if let idx = ignored.firstIndex(where: { $0.bundleID == bundleID }) {
            ignored[idx] = IgnoredApp(
                bundleID: bundleID, appName: appName,
                ignoredAt: ignored[idx].ignoredAt,    // preserve original time
                reason: reason ?? ignored[idx].reason
            )
        } else {
            ignored.append(IgnoredApp(
                bundleID: bundleID, appName: appName,
                ignoredAt: Date(), reason: reason
            ))
        }
        bundleIDSet.insert(bundleID)
        save()
        AppLogger.shared.logIgnoreChange(bundleID: bundleID, ignored: true)
    }

    func unignore(bundleID: String) {
        ignored.removeAll { $0.bundleID == bundleID }
        bundleIDSet.remove(bundleID)
        save()
        AppLogger.shared.logIgnoreChange(bundleID: bundleID, ignored: false)
    }

    func clearAll() {
        for entry in ignored {
            AppLogger.shared.logIgnoreChange(bundleID: entry.bundleID, ignored: false)
        }
        ignored = []
        bundleIDSet = []
        save()
    }

    // ── Convenience: list of running apps the user might want to ignore ────

    /// Returns currently-running apps that aren't already ignored.
    /// Used by Settings to offer a "browse" picker.
    func runningCandidates() -> [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .compactMap { app -> (String, String)? in
                guard let bid = app.bundleIdentifier,
                      !bundleIDSet.contains(bid),
                      let name = app.localizedName
                else { return nil }
                return (bid, name)
            }
            // Distinct by bundleID (helper-process apps can have multiple instances)
            .reduce(into: [String: (String, String)]()) { acc, pair in
                acc[pair.0] = pair
            }.values
            .sorted { $0.1.lowercased() < $1.1.lowercased() }
    }

    // ── Persistence ────────────────────────────────────────────────────────

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([IgnoredApp].self, from: data)
        else { return }
        ignored = saved
        bundleIDSet = Set(saved.map { $0.bundleID })
    }

    private func save() {
        if let data = try? JSONEncoder().encode(ignored) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
