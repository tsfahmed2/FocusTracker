import SwiftUI
import Combine
import ServiceManagement

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Root popover
// ─────────────────────────────────────────────────────────────────────────────

struct PopoverView: View {
    @ObservedObject private var store   = EventStore.shared
    @ObservedObject private var perms   = PermissionsManager.shared
    @State private var tab: Tab      = .recent

    enum Tab: String, CaseIterable {
        case recent   = "Recent"
        case suspects = "Suspects"
        case settings = "Settings"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !perms.allGranted {
                PermissionsBanner()
            }
            tabBar
            Divider()
            content
        }
        .frame(width: 400)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // ── Header ─────────────────────────────────────────────────────────────

    private var header: some View {
        HStack {
            Image(systemName: "eye.trianglebadge.exclamationmark")
                .font(.title3)
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Focus Tracker")
                    .font(.headline)
                statsLine
            }
            Spacer()
            quitButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var statsLine: some View {
        HStack(spacing: 8) {
            Label("\(store.stats.totalEvents)", systemImage: "arrow.up.arrow.down")
            if store.stats.programmaticEvents > 0 {
                Label("\(store.stats.programmaticEvents) suspicious",
                      systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
            }
            if let app = store.stats.lastStealApp {
                Text("Last: \(app)").foregroundColor(.secondary)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Image(systemName: "power")
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("Quit Focus Tracker")
    }

    // ── Tab bar ────────────────────────────────────────────────────────────

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                tabButton(t)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func tabButton(_ t: Tab) -> some View {
        Button {
            tab = t
        } label: {
            VStack(spacing: 3) {
                Text(tabLabel(t))
                    .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                    .foregroundColor(tab == t ? .primary : .secondary)
                Rectangle()
                    .frame(height: 2)
                    .foregroundColor(tab == t ? .orange : .clear)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private func tabLabel(_ t: Tab) -> String {
        switch t {
        case .recent:
            let prog = store.events.filter { $0.trigger == .programmatic }.count
            return prog > 0 ? "Recent (\(prog) ⚠)" : "Recent"
        case .suspects:
            let hot = store.suspects.filter { $0.isDefinitiveSuspect }.count
            return hot > 0 ? "Suspects (\(hot))" : "Suspects"
        case .settings:
            return "Settings"
        }
    }

    // ── Content ────────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .recent:   RecentView()
        case .suspects: SuspectsView()
        case .settings: SettingsView()
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Permissions banner
// ─────────────────────────────────────────────────────────────────────────────

struct PermissionsBanner: View {
    @ObservedObject private var perms = PermissionsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions needed for full functionality")
                .font(.caption).fontWeight(.semibold)
                .foregroundColor(.orange)
            if !perms.accessibilityGranted {
                permRow(
                    icon: "hand.raised",
                    label: "Accessibility — window titles",
                    action: { perms.requestAccessibility() },
                    openAction: { perms.openAccessibilitySettings() }
                )
            }
            if !perms.inputMonitoringGranted {
                permRow(
                    icon: "keyboard",
                    label: "Input Monitoring — trigger detection",
                    action: { perms.openInputMonitoringSettings() },
                    openAction: { perms.openInputMonitoringSettings() }
                )
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
        .overlay(Rectangle().frame(height: 1).foregroundColor(.orange.opacity(0.3)), alignment: .bottom)
    }

    private func permRow(icon: String, label: String, action: @escaping () -> Void,
                         openAction: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(.orange).frame(width: 16)
            Text(label).font(.caption).foregroundColor(.primary)
            Spacer()
            Button("Grant") { action() }
                .font(.caption).buttonStyle(.borderedProminent).tint(.orange)
            Button { openAction() } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain).foregroundColor(.secondary)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Recent tab
// ─────────────────────────────────────────────────────────────────────────────

struct RecentView: View {
    @ObservedObject private var store = EventStore.shared
    @State private var filter: FilterMode = .all

    enum FilterMode: String, CaseIterable {
        case all           = "All"
        case programmatic  = "Suspicious"
        case userInput     = "User"
    }

    private var displayedEvents: [FocusEvent] {
        let base = store.recentEvents(limit: 100)
        switch filter {
        case .all:          return base
        case .programmatic: return base.filter { $0.trigger == .programmatic }
        case .userInput:    return base.filter { $0.trigger == .userInput }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter pills
            HStack(spacing: 6) {
                ForEach(FilterMode.allCases, id: \.self) { mode in
                    filterPill(mode)
                }
                Spacer()
                Button("Clear") { store.clearAll() }
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            if displayedEvents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayedEvents) { event in
                            EventRow(event: event)
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
    }

    private func filterPill(_ mode: FilterMode) -> some View {
        Button { filter = mode } label: {
            Text(mode.rawValue)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(filter == mode ? Color.orange : Color(NSColor.controlBackgroundColor))
                .foregroundColor(filter == mode ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.largeTitle).foregroundColor(.green)
            Text("No events yet").foregroundColor(.secondary)
            Text("Switch between apps to start capturing").font(.caption).foregroundColor(.secondary)
        }
        .frame(height: 200)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - EventRow
// ─────────────────────────────────────────────────────────────────────────────

struct EventRow: View {
    let event: FocusEvent
    @State private var expanded = false

    private var triggerColor: Color {
        switch event.trigger {
        case .userInput:    return .green
        case .programmatic: return .orange
        case .unknown:      return .gray
        }
    }

    var body: some View {
        Button { expanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    // Trigger indicator
                    Circle()
                        .fill(triggerColor)
                        .frame(width: 8, height: 8)

                    // App name
                    Text(event.appName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    Spacer()

                    // Timestamp
                    Text(event.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    // Suspicion badge
                    if event.suspicion >= 30 {
                        suspicionBadge
                    }

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Window title (always visible)
                if let title = event.windowTitle, !title.isEmpty {
                    Text("⊞ \(title)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 16)
                }

                // Anomaly tags
                if !event.anomalyTypes.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(event.anomalyTypes, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.15))
                                .foregroundColor(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .padding(.leading, 16)
                }

                // Expanded detail
                if expanded {
                    expandedDetail
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .background(event.isProbablyStealth ? Color.orange.opacity(0.05) : Color.clear)
        .contextMenu {
            if let bid = event.bundleID {
                Button {
                    IgnoredAppsManager.shared.ignore(
                        bundleID: bid,
                        appName: event.appName,
                        reason: "Ignored from event row"
                    )
                } label: {
                    Label("Ignore \(event.appName)", systemImage: "speaker.slash")
                }
                Divider()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bid, forType: .string)
                } label: {
                    Label("Copy Bundle ID", systemImage: "doc.on.doc")
                }
            } else {
                Text("No bundle ID — cannot ignore").disabled(true)
            }
        }
    }

    private var suspicionBadge: some View {
        let color: Color = event.suspicion >= 70 ? .red : event.suspicion >= 40 ? .orange : .yellow
        return Text("\(event.suspicion)")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            detailRow("Bundle ID",    event.bundleID ?? "—")
            detailRow("PID",          "\(event.pid)")
            detailRow("Policy",       event.activationPolicy)
            detailRow("Trigger",      "\(event.trigger.emoji) \(event.trigger.label)")
            if let ms = event.msSinceLastInput {
                detailRow("Last input",   "\(ms)ms ago (\(event.lastInputType ?? "?"))")
            }
            detailRow("Windows",      "\(event.windowCount)")
            if !event.triggerDetail.isEmpty && event.triggerDetail != "normal" {
                detailRow("Detail", event.triggerDetail)
            }

            // Scoring breakdown (only present in DebugMode)
            if let breakdown = event.scoreBreakdown {
                Divider().padding(.vertical, 2)
                ScoringBreakdownView(breakdown: breakdown)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.leading, 16)
        .padding(.top, 4)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label + ":")
                .fontWeight(.medium)
                .frame(width: 72, alignment: .trailing)
            Text(value)
                .foregroundColor(.primary)
                .lineLimit(3)
            Spacer()
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Suspects tab
// ─────────────────────────────────────────────────────────────────────────────

struct SuspectsView: View {
    @ObservedObject private var store = EventStore.shared

    var body: some View {
        if store.suspects.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "person.fill.questionmark")
                    .font(.largeTitle).foregroundColor(.secondary)
                Text("No suspects yet").foregroundColor(.secondary)
                Text("Keep the app running to build a profile").font(.caption).foregroundColor(.secondary)
            }
            .frame(height: 200)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.suspects) { suspect in
                        SuspectRow(suspect: suspect)
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .frame(maxHeight: 380)
        }
    }
}

struct SuspectRow: View {
    let suspect: AppSuspect

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                // Definitive badge
                if suspect.isDefinitiveSuspect {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red).font(.caption)
                }
                Text(suspect.appName)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                scoreBar
            }

            if let bid = suspect.bundleID {
                Text(bid).font(.caption2).foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                statPill("Total",  "\(suspect.totalActivations)", .gray)
                statPill("Prog",   "\(suspect.programmaticCount) (\(suspect.programmaticPct)%)",
                          suspect.programmaticPct > 50 ? .orange : .gray)
                statPill("Avg susp", "\(suspect.avgSuspicion)",
                          suspect.avgSuspicion >= 60 ? .red : suspect.avgSuspicion >= 40 ? .orange : .gray)
            }
            .font(.caption)

            if !suspect.windowTitles.isEmpty {
                Text("Windows: " + suspect.windowTitles.prefix(3).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(suspect.isDefinitiveSuspect ? Color.red.opacity(0.05) : Color.clear)
        .contextMenu {
            if let bid = suspect.bundleID {
                Button {
                    IgnoredAppsManager.shared.ignore(
                        bundleID: bid,
                        appName: suspect.appName,
                        reason: "Ignored from suspects list"
                    )
                } label: {
                    Label("Ignore \(suspect.appName)", systemImage: "speaker.slash")
                }
            }
        }
    }

    private var scoreBar: some View {
        HStack(spacing: 2) {
            ForEach(0..<10) { i in
                Rectangle()
                    .frame(width: 4, height: 12)
                    .foregroundColor(i < suspect.score / 10 ? scoreColor : Color(NSColor.separatorColor))
                    .cornerRadius(1)
            }
        }
    }

    private var scoreColor: Color {
        suspect.score >= 60 ? .red : suspect.score >= 30 ? .orange : .yellow
    }

    private func statPill(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label + ":").foregroundColor(.secondary)
            Text(value).fontWeight(.medium).foregroundColor(color)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Settings tab
// ─────────────────────────────────────────────────────────────────────────────

struct SettingsView: View {
    @ObservedObject private var perms   = PermissionsManager.shared
    @ObservedObject private var launch  = LaunchAtLoginManager.shared
    @ObservedObject private var debug   = DebugMode.shared
    private let notifs = NotificationManager.shared

    @State private var notifEnabled: Bool   = NotificationManager.shared.notificationsEnabled
    @State private var threshold:    Double = Double(NotificationManager.shared.suspicionThreshold)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Launch at Login
                settingsSection("General") {
                    LaunchAtLoginRow(manager: launch)
                }

                // Notifications
                settingsSection("Notifications") {
                    Toggle("Alert when focus is stolen", isOn: $notifEnabled)
                        .onChange(of: notifEnabled) { _, v in
                            notifs.notificationsEnabled = v
                            if v { notifs.requestAuthorization() }
                        }

                    if notifEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Alert threshold: \(Int(threshold))/100 suspicion")
                                .font(.caption)
                            Slider(value: $threshold, in: 20...90, step: 5)
                                .onChange(of: threshold) { _, v in
                                    notifs.suspicionThreshold = Int(v)
                                }
                            Text("Lower = more alerts, higher = only definitive steals")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }

                // Permissions
                settingsSection("Permissions") {
                    permRow(
                        icon: "hand.raised",
                        label: "Accessibility",
                        granted: perms.accessibilityGranted,
                        detail: "Required for window titles",
                        action: { perms.requestAccessibility() }
                    )
                    permRow(
                        icon: "keyboard",
                        label: "Input Monitoring",
                        granted: perms.inputMonitoringGranted,
                        detail: "Required for trigger detection",
                        action: { perms.openInputMonitoringSettings() }
                    )
                }

                // Ignored apps
                settingsSection("Ignored Apps") {
                    IgnoreListSection()
                }

                // Logging
                settingsSection("Logs") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Focus Tracker logs to the macOS Unified System Log.")
                            .font(.caption).foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            Button {
                                if let url = NSWorkspace.shared.urlForApplication(
                                    withBundleIdentifier: "com.apple.Console") {
                                    NSWorkspace.shared.open(url)
                                }
                                let bid = Bundle.main.bundleIdentifier ?? "com.khan.FocusTracker"
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("subsystem:\(bid)", forType: .string)
                            } label: {
                                Label("Open Console", systemImage: "terminal")
                            }
                            .buttonStyle(.bordered).font(.caption)
                            Text("Filter copied to clipboard")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Text("Or run in Terminal: log stream --predicate 'subsystem == \"\(Bundle.main.bundleIdentifier ?? "com.khan.FocusTracker")\"'")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                // Debug
                settingsSection("Developer") {
                    DebugModeRow(debug: debug)
                }

                // About
                settingsSection("About") {
                    HStack {
                        Text("Version").foregroundColor(.secondary)
                        Spacer()
                        Text("2.0.0")
                    }
                    .font(.caption)
                }

                // Danger zone
                settingsSection("Data") {
                    Button("Clear in-app events") { EventStore.shared.clearAll() }
                        .foregroundColor(.red).font(.caption)
                    Text("Clears the in-app event list. System log entries are managed by macOS.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 380)
    }

    private func settingsSection<Content: View>(_ title: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func permRow(icon: String, label: String, granted: Bool,
                         detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundColor(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).fontWeight(.medium)
                Text(detail).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
            } else {
                Button("Grant") { action() }
                    .font(.caption).buttonStyle(.borderedProminent).tint(.orange)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Launch at Login Row
// ─────────────────────────────────────────────────────────────────────────────

struct LaunchAtLoginRow: View {
    @ObservedObject var manager: LaunchAtLoginManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { manager.isEnabled },
                set: { manager.setEnabled($0) }
            )) {
                Text("Launch at Login")
                    .font(.caption)
                    .fontWeight(.medium)
            }

            // Status line
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(manager.statusDescription)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // "Requires approval" deep-link
            if manager.requiresApproval {
                Button("Approve in System Settings →") {
                    manager.openLoginItemsSettings()
                }
                .font(.caption2)
                .foregroundColor(.orange)
                .buttonStyle(.plain)
            }

            // Error message
            if let error = manager.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { manager.refresh() }
    }

    private var statusColor: Color {
        switch SMAppService.mainApp.status {
        case .enabled:          return .green
        case .requiresApproval: return .orange
        default:                return Color(NSColor.separatorColor)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Scoring Breakdown View
//
// Shown inline in EventRow when a scoreBreakdown is present (which only
// happens when DebugMode is enabled). Displays the step-by-step scoring
// trace so users can audit why an event was flagged.
// ─────────────────────────────────────────────────────────────────────────────

struct ScoringBreakdownView: View {
    let breakdown: ScoreBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "function").foregroundColor(.purple)
                Text("Scoring breakdown")
                    .fontWeight(.semibold)
                    .foregroundColor(.purple)
                Spacer()
                Text("\(breakdown.finalScore)/100")
                    .fontWeight(.bold)
                    .foregroundColor(scoreColor)
            }

            ForEach(Array(breakdown.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 4) {
                    // step number
                    Text("\(i + 1).")
                        .frame(width: 14, alignment: .trailing)
                        .foregroundColor(.secondary)
                    // check name
                    Text(step.check)
                        .frame(width: 90, alignment: .leading)
                        .foregroundColor(.secondary)
                    // observation
                    Text(step.observation)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // points
                    pointsBadge(step.pointsAdded)
                }
                .font(.system(size: 10))
            }

            if let cap = breakdown.capApplied {
                HStack(spacing: 4) {
                    Image(systemName: "scissors").foregroundColor(.orange)
                    Text(cap).foregroundColor(.orange)
                }
                .font(.system(size: 10))
                .padding(.top, 2)
            }
        }
        .padding(8)
        .background(Color.purple.opacity(0.06))
        .cornerRadius(4)
    }

    private var scoreColor: Color {
        breakdown.finalScore >= 70 ? .red
            : breakdown.finalScore >= 40 ? .orange
            : breakdown.finalScore >= 15 ? .yellow
            : .green
    }

    private func pointsBadge(_ points: Int) -> some View {
        Group {
            if points > 0 {
                Text("+\(points)")
                    .fontWeight(.bold)
                    .foregroundColor(.red)
            } else if points < 0 {
                Text("\(points)")
                    .fontWeight(.bold)
                    .foregroundColor(.green)
            } else {
                Text("—").foregroundColor(.secondary)
            }
        }
        .frame(width: 28, alignment: .trailing)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Debug Mode Row (Settings)
// ─────────────────────────────────────────────────────────────────────────────

struct DebugModeRow: View {
    @ObservedObject var debug: DebugMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Debug mode", isOn: $debug.isEnabled)
                .font(.caption)
                .fontWeight(.medium)

            if debug.isEnabled {
                Text("Each event captures a full scoring trace, visible inline in the Recent tab and logged to Console under category 'scoring'.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Enable to see how each suspicion score is calculated, step by step.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Ignore List Section (Settings)
//
// Displays the current ignored-apps list with delete buttons, plus a
// browse-and-add picker for currently-running apps.
// ─────────────────────────────────────────────────────────────────────────────

struct IgnoreListSection: View {
    @ObservedObject private var manager = IgnoredAppsManager.shared
    @State private var showAddPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header line
            HStack {
                Text(manager.ignored.isEmpty
                     ? "No apps ignored"
                     : "\(manager.ignored.count) app\(manager.ignored.count == 1 ? "" : "s") ignored")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    showAddPicker = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }

            // List of ignored entries
            if !manager.ignored.isEmpty {
                VStack(spacing: 0) {
                    ForEach(manager.ignored) { entry in
                        IgnoreListRow(entry: entry) {
                            manager.unignore(bundleID: entry.bundleID)
                        }
                        if entry.id != manager.ignored.last?.id {
                            Divider().padding(.leading, 8)
                        }
                    }
                }
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)

                Button("Clear all", role: .destructive) {
                    manager.clearAll()
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundColor(.red)
            }

            // Help text
            Text("Right-click any event in Recent or Suspects to ignore that app.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .sheet(isPresented: $showAddPicker) {
            IgnorePickerSheet(isPresented: $showAddPicker)
        }
    }
}

// ── Single ignore-list row ────────────────────────────────────────────────────

struct IgnoreListRow: View {
    let entry: IgnoredAppsManager.IgnoredApp
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.appName).font(.caption).fontWeight(.medium)
                Text(entry.bundleID)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(entry.ignoredAt, style: .relative)
                .font(.caption2)
                .foregroundColor(.secondary)
            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from ignore list")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// ── Picker sheet showing currently-running candidates ────────────────────────

struct IgnorePickerSheet: View {
    @Binding var isPresented: Bool
    @State private var search = ""
    @State private var candidates: [(bundleID: String, name: String)] = []

    var filtered: [(bundleID: String, name: String)] {
        guard !search.isEmpty else { return candidates }
        let q = search.lowercased()
        return candidates.filter {
            $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Ignore an app")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.escape)
            }

            TextField("Search by name or bundle ID", text: $search)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.bundleID) { c in
                        Button {
                            IgnoredAppsManager.shared.ignore(
                                bundleID: c.bundleID,
                                appName: c.name,
                                reason: "Added from settings picker"
                            )
                            isPresented = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).font(.callout)
                                    Text(c.bundleID)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .frame(height: 280)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            Text("Showing \(filtered.count) of \(candidates.count) running apps. Apps already ignored are hidden.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            candidates = IgnoredAppsManager.shared.runningCandidates()
        }
    }
}
