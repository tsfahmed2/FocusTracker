import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - FocusEvent
// ─────────────────────────────────────────────────────────────────────────────

struct FocusEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let appName: String
    let bundleID: String?
    let pid: Int32
    let trigger: Trigger
    let suspicion: Int          // 0–100
    let windowTitle: String?
    let windowCount: Int
    let triggerDetail: String
    let msSinceLastInput: Int?
    let lastInputType: String?
    let activationPolicy: String
    let anomalyTypes: [String]  // any anomalies that fired alongside this event

    /// Step-by-step scoring trace. Only populated when DebugMode is on
    /// (otherwise nil to keep stored payloads small for everyone else).
    let scoreBreakdown: ScoreBreakdown?

    enum Trigger: String, Codable, CaseIterable {
        case userInput    = "user_input"
        case programmatic = "programmatic"
        case unknown      = "unknown"

        var label: String {
            switch self {
            case .userInput:    return "User"
            case .programmatic: return "Programmatic"
            case .unknown:      return "Unknown"
            }
        }

        var emoji: String {
            switch self {
            case .userInput:    return "✓"
            case .programmatic: return "⚠"
            case .unknown:      return "?"
            }
        }
    }

    var isProbablyStealth: Bool {
        trigger == .programmatic && suspicion >= 40
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ScoreBreakdown
//
// A traceable record of how the suspicion score was computed. Each check
// the scorer ran is captured as a Step, regardless of whether it added to
// the score, so the full decision is reconstructible after the fact.
// ─────────────────────────────────────────────────────────────────────────────

struct ScoreBreakdown: Codable, Equatable {
    /// Ordered list of every check the scorer ran.
    let steps: [Step]

    /// Final score after all caps applied.
    let finalScore: Int

    /// True if a cap was applied that lowered the raw point total.
    let capApplied: String?    // e.g. "user_input cap (max 15)"

    /// Resolved trigger classification.
    let trigger: FocusEvent.Trigger

    struct Step: Codable, Equatable {
        let check: String           // "input timing", "activation policy", etc.
        let observation: String     // "follows 142ms after mouse_click"
        let pointsAdded: Int        // can be 0 if the check passed
        let runningTotal: Int       // total after this step
    }

    /// Render as a multi-line string for logs and tooltips.
    func multilineDescription() -> String {
        var lines: [String] = []
        lines.append("Suspicion breakdown — final: \(finalScore)/100, trigger: \(trigger.rawValue)")
        for (i, s) in steps.enumerated() {
            let sign = s.pointsAdded > 0 ? "+\(s.pointsAdded)"
                     : s.pointsAdded < 0 ? "\(s.pointsAdded)"
                     : "—"
            lines.append(String(format: "  %d. [%@] %@  %@  (running: %d)",
                                i + 1, s.check, s.observation, sign, s.runningTotal))
        }
        if let cap = capApplied {
            lines.append("  Cap: \(cap)")
        }
        return lines.joined(separator: "\n")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppSuspect
// ─────────────────────────────────────────────────────────────────────────────

struct AppSuspect: Identifiable {
    let id: String          // bundleID or appName
    let appName: String
    let bundleID: String?
    let totalActivations: Int
    let programmaticCount: Int
    let avgSuspicion: Int
    let windowTitles: [String]
    let lastSeen: Date?

    var programmaticPct: Int {
        guard totalActivations > 0 else { return 0 }
        return programmaticCount * 100 / totalActivations
    }

    var isDefinitiveSuspect: Bool {
        programmaticPct > 50 && avgSuspicion >= 40
    }

    /// Composite score for ranking (higher = more suspicious)
    var score: Int { programmaticPct * avgSuspicion / 100 }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppStats  (live counters shown in menu)
// ─────────────────────────────────────────────────────────────────────────────

struct AppStats {
    var totalEvents: Int = 0
    var programmaticEvents: Int = 0
    var highSuspicionEvents: Int = 0
    var lastStealTime: Date? = nil
    var lastStealApp: String? = nil
}
