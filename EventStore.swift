import Foundation
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - EventStore
//
// In-memory ring buffer (last 500 events) + UserDefaults persistence (last
// 100). Acts as the single source of truth for the UI.
//
// Performance design:
//
// • saveToDisk is debounced — at most one write per second, even if 50
//   events arrive in that window. This prevents UserDefaults I/O from
//   blocking the main thread on bursts.
//
// • Suspect tracking is incremental. Rather than re-scanning all 500
//   events every time one arrives (O(n²) over time), we maintain a
//   running per-bundleID accumulator and rebuild only the sorted output.
// ─────────────────────────────────────────────────────────────────────────────

final class EventStore: ObservableObject {
    static let shared = EventStore()

    @Published private(set) var events:   [FocusEvent] = []    // newest first
    @Published private(set) var stats   = AppStats()
    @Published private(set) var suspects: [AppSuspect] = []

    private let maxMemory  = 500
    private let maxPersist = 100
    // v2: added scoreBreakdown field. Bump key to skip old payloads
    // rather than write a custom decoder.
    private let persistKey = "ft.recentEvents.v2"

    // Incremental suspect tracking
    private struct Acc {
        var name: String
        var bid:  String?
        var total   = 0
        var prog    = 0
        var suspSum = 0
        var titles: Set<String> = []
        var lastSeen: Date?
    }
    private var byKey: [String: Acc] = [:]

    // Debounced save
    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.ft.eventstore.save", qos: .utility)

    private init() {
        // One-time migration: remove the v1 key. v1 events lacked
        // scoreBreakdown and would fail to decode against the new model.
        UserDefaults.standard.removeObject(forKey: "ft.recentEvents")

        loadFromDisk()
        rebuildAccumulator()
        rebuildSuspects()
    }

    // ── Write ──────────────────────────────────────────────────────────────

    func append(_ event: FocusEvent) {
        AppLogger.shared.logFocusEvent(
            appName:          event.appName,
            bundleID:         event.bundleID,
            pid:              event.pid,
            trigger:          event.trigger.rawValue,
            suspicion:        event.suspicion,
            windowTitle:      event.windowTitle,
            triggerDetail:    event.triggerDetail,
            msSinceLastInput: event.msSinceLastInput,
            anomalyTypes:     event.anomalyTypes
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.events.insert(event, at: 0)

            // If we're over the memory cap, drop the oldest event AND
            // remove its contribution from the accumulator.
            if self.events.count > self.maxMemory {
                let dropped = self.events.removeLast()
                self.deaccumulate(dropped)
            }

            self.accumulate(event)
            self.updateStats(for: event)
            self.rebuildSuspects()
            self.scheduleSave()
        }
    }

    // ── Stats ──────────────────────────────────────────────────────────────

    private func updateStats(for event: FocusEvent) {
        stats.totalEvents += 1
        if event.trigger == .programmatic { stats.programmaticEvents += 1 }
        if event.suspicion >= 60          { stats.highSuspicionEvents += 1 }
        if event.isProbablyStealth {
            stats.lastStealTime = event.timestamp
            stats.lastStealApp  = event.appName
        }
    }

    // ── Incremental suspect accumulation ───────────────────────────────────

    private func accumulate(_ e: FocusEvent) {
        let key = e.bundleID ?? e.appName
        var acc = byKey[key] ?? Acc(name: e.appName, bid: e.bundleID)
        acc.total   += 1
        if e.trigger == .programmatic { acc.prog += 1 }
        acc.suspSum += e.suspicion
        if let wt = e.windowTitle { acc.titles.insert(wt) }
        if acc.lastSeen == nil || e.timestamp > acc.lastSeen! { acc.lastSeen = e.timestamp }
        byKey[key] = acc
    }

    private func deaccumulate(_ e: FocusEvent) {
        let key = e.bundleID ?? e.appName
        guard var acc = byKey[key] else { return }
        acc.total   -= 1
        if e.trigger == .programmatic { acc.prog -= 1 }
        acc.suspSum -= e.suspicion
        // Note: we don't remove window titles — they're a Set and we don't
        // track per-event provenance. This is a slight over-retention but
        // bounded by the unique-titles count for that app.

        if acc.total <= 0 {
            byKey.removeValue(forKey: key)
        } else {
            byKey[key] = acc
        }
    }

    private func rebuildAccumulator() {
        byKey = [:]
        for e in events { accumulate(e) }
    }

    private func rebuildSuspects() {
        suspects = byKey.values
            .filter { $0.total >= 2 }
            .map { acc in
                AppSuspect(
                    id: acc.bid ?? acc.name,
                    appName: acc.name,
                    bundleID: acc.bid,
                    totalActivations: acc.total,
                    programmaticCount: acc.prog,
                    avgSuspicion: acc.total > 0 ? acc.suspSum / acc.total : 0,
                    windowTitles: Array(acc.titles).sorted(),
                    lastSeen: acc.lastSeen
                )
            }
            .sorted { $0.score > $1.score }
    }

    // ── Persistence (debounced) ────────────────────────────────────────────

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performSave()
        }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func performSave() {
        // Snapshot off the main thread, then write.
        // We can't read self.events from saveQueue directly without sync.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let snapshot = Array(self.events.prefix(self.maxPersist))
            self.saveQueue.async {
                if let data = try? JSONEncoder().encode(snapshot) {
                    UserDefaults.standard.set(data, forKey: self.persistKey)
                }
            }
        }
    }

    private func loadFromDisk() {
        guard let data  = UserDefaults.standard.data(forKey: persistKey),
              let saved = try? JSONDecoder().decode([FocusEvent].self, from: data)
        else { return }
        events = saved
        for e in saved { updateStats(for: e) }
    }

    // ── Queries ────────────────────────────────────────────────────────────

    func recentEvents(limit: Int = 50) -> [FocusEvent] { Array(events.prefix(limit)) }
    func programmaticEvents() -> [FocusEvent] { events.filter { $0.trigger == .programmatic } }

    func clearAll() {
        AppLogger.shared.logUserClearedEvents()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.events    = []
            self.stats     = AppStats()
            self.suspects  = []
            self.byKey     = [:]
            self.pendingSave?.cancel()
            UserDefaults.standard.removeObject(forKey: self.persistKey)
        }
    }
}
