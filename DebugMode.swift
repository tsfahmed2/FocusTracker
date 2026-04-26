import Foundation
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DebugMode
//
// Global toggle that controls verbose scoring traces.
//
// When enabled:
//   • Every FocusEvent gets a populated `scoreBreakdown` field
//   • Every event's full breakdown is written to the unified log
//     (subsystem:com.khan.FocusTracker, category:scoring)
//   • The Recent tab shows a "Show scoring breakdown" expander on each row
//
// When disabled (default):
//   • `scoreBreakdown` is nil — no per-event memory or log overhead
//   • UI shows the existing summary line only
//
// Off by default because most users don't need it. On for development
// and for users investigating "why was my browser flagged?"
// ─────────────────────────────────────────────────────────────────────────────

final class DebugMode: ObservableObject {
    static let shared = DebugMode()

    private let key = "ft.debugMode"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: key) }
    }

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: key)
    }
}
