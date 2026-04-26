import AppKit
import CoreGraphics
import ApplicationServices

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - FocusMonitor
// Core focus monitoring. Publishes FocusEvent values to EventStore
// and fires notifications.
// ─────────────────────────────────────────────────────────────────────────────

final class FocusMonitor {

    // Thresholds
    private let inputUserMs:    Double       = 300
    private let inputProgramMs: Double       = 800
    private let rapidWindow:    TimeInterval = 5.0
    private let rapidThreshold: Int          = 6
    private let justLaunchedWindow: TimeInterval = 2.0

    // State
    private var lastInputTime: CFAbsoluteTime = 0
    private var lastInputType: String         = "none"
    private var inputTapAvailable             = false
    private var lastFrontmost: pid_t?
    private var recentActivations: [Date]     = []
    private var recentlyLaunched: Set<pid_t>  = []
    private var knownBundles: Set<String>     = []

    private let store  = EventStore.shared
    private let notifs = NotificationManager.shared

    // ── Start ──────────────────────────────────────────────────────────────

    func start() {
        installInputTap()
        registerWorkspaceNotifications()
        startPolling()
    }

    // ── CGEvent tap ────────────────────────────────────────────────────────

    private func installInputTap() {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)  |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue)        |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<FocusMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.recordInput(type: type, event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: selfPtr
        ) else {
            // Tap creation failed (typically Input Monitoring permission denied).
            // Balance the passRetained above so we don't leak self forever.
            Unmanaged<FocusMonitor>.fromOpaque(selfPtr).release()
            return
        }
        inputTapAvailable = true
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func recordInput(type: CGEventType, event: CGEvent) {
        lastInputTime = CFAbsoluteTimeGetCurrent()
        switch type {
        case .leftMouseDown, .rightMouseDown:
            lastInputType = "mouse_click"
        case .keyDown:
            let kc    = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            lastInputType = (kc == 48 && flags.contains(.maskCommand)) ? "cmd_tab" : "key_down"
        case .flagsChanged:
            lastInputType = "modifier_key"
        default:
            lastInputType = "input"
        }
    }

    // ── Workspace notifications ────────────────────────────────────────────

    private func registerWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func appLaunched(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        recentlyLaunched.insert(app.processIdentifier)
        DispatchQueue.main.asyncAfter(deadline: .now() + justLaunchedWindow + 0.1) { [weak self] in
            self?.recentlyLaunched.remove(app.processIdentifier)
        }
    }

    @objc private func appTerminated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        recentlyLaunched.remove(app.processIdentifier)
    }

    @objc private func appActivated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        guard !isSelf(app) else { return }
        guard !IgnoredAppsManager.shared.shouldIgnore(bundleID: app.bundleIdentifier) else { return }
        let event = buildEvent(for: app)
        store.append(event)
        notifs.considerNotifying(for: event)
    }

    // ── Polling safety net ─────────────────────────────────────────────────

    private func startPolling() {
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard let current = NSWorkspace.shared.frontmostApplication else { return }
        let pid = current.processIdentifier
        guard pid != lastFrontmost else { return }
        lastFrontmost = pid
        // Skip self — we activate ourselves whenever the popover opens, which
        // is by definition not "stealing focus" from anyone.
        guard !isSelf(current) else { return }
        // Skip user-ignored apps
        guard !IgnoredAppsManager.shared.shouldIgnore(bundleID: current.bundleIdentifier) else { return }
        let event = buildEvent(for: current, source: "poll")
        store.append(event)
        notifs.considerNotifying(for: event)
    }

    /// True if the given app is Focus Tracker itself.
    /// We compare by bundle ID rather than process ID so this still works
    /// if (somehow) we end up with multiple processes.
    private func isSelf(_ app: NSRunningApplication) -> Bool {
        guard let ours = Bundle.main.bundleIdentifier else { return false }
        return app.bundleIdentifier == ours
    }

    // ── Event construction ─────────────────────────────────────────────────

    private func buildEvent(for app: NSRunningApplication, source: String = "notification") -> FocusEvent {
        // Input timing
        let ms: Double? = inputTapAvailable && lastInputTime > 0
            ? (CFAbsoluteTimeGetCurrent() - lastInputTime) * 1000
            : nil

        // Window info
        let winfo = windowInfo(for: app.processIdentifier)

        // Recent activation rate
        let cutoff = Date().addingTimeInterval(-rapidWindow)
        recentActivations = recentActivations.filter { $0 > cutoff }
        recentActivations.append(Date())

        // Suspicion
        let justLaunched = recentlyLaunched.contains(app.processIdentifier)
        let (trigger, suspicion, detail, breakdown) = score(
            app: app,
            ms: ms,
            windowCount: winfo.windowCount,
            justLaunched: justLaunched,
            recentCount: recentActivations.count
        )

        // First seen?
        var anomalyTypes: [String] = []
        if let bid = app.bundleIdentifier, !knownBundles.contains(bid) {
            knownBundles.insert(bid)
            anomalyTypes.append("UNKNOWN_BUNDLE")
        }
        if recentActivations.count >= rapidThreshold { anomalyTypes.append("RAPID_FOCUS") }
        if app.activationPolicy != .regular          { anomalyTypes.append("NON_REGULAR") }
        if justLaunched                              { anomalyTypes.append("JUST_LAUNCHED") }
        if suspicion >= 60                           { anomalyTypes.append("HIGH_SUSPICION") }

        // Only include the breakdown when DebugMode is on — keeps memory and
        // log overhead off everyone else's machine.
        let included = DebugMode.shared.isEnabled ? breakdown : nil

        // Log full breakdown to unified log when debug mode is on
        if DebugMode.shared.isEnabled {
            AppLogger.shared.logScoring(
                appName: app.localizedName ?? "Unknown",
                breakdown: breakdown
            )
        }

        return FocusEvent(
            id: UUID(),
            timestamp: Date(),
            appName: app.localizedName ?? "Unknown",
            bundleID: app.bundleIdentifier,
            pid: app.processIdentifier,
            trigger: trigger,
            suspicion: suspicion,
            windowTitle: winfo.title,
            windowCount: winfo.windowCount,
            triggerDetail: detail,
            msSinceLastInput: ms.map { Int($0) },
            lastInputType: inputTapAvailable ? lastInputType : nil,
            activationPolicy: policyName(app.activationPolicy),
            anomalyTypes: anomalyTypes,
            scoreBreakdown: included
        )
    }

    // ── Scoring ────────────────────────────────────────────────────────────

    private func score(
        app: NSRunningApplication,
        ms: Double?,
        windowCount: Int,
        justLaunched: Bool,
        recentCount: Int
    ) -> (FocusEvent.Trigger, Int, String, ScoreBreakdown) {

        var steps: [ScoreBreakdown.Step] = []
        var points = 0
        let trigger: FocusEvent.Trigger

        // ── Step 1: Input timing ──────────────────────────────────────────
        if let ms {
            if ms <= inputUserMs {
                trigger = .userInput
                steps.append(.init(
                    check: "input timing",
                    observation: "follows \(Int(ms))ms after \(lastInputType) (≤\(Int(inputUserMs))ms threshold → user-initiated)",
                    pointsAdded: 0, runningTotal: points))
            } else if ms >= inputProgramMs {
                trigger = .programmatic
                points += 35
                steps.append(.init(
                    check: "input timing",
                    observation: "no user input for \(Int(ms))ms (≥\(Int(inputProgramMs))ms threshold → programmatic)",
                    pointsAdded: 35, runningTotal: points))
            } else {
                trigger = .unknown
                points += 10
                steps.append(.init(
                    check: "input timing",
                    observation: "ambiguous gap (\(Int(ms))ms is between \(Int(inputUserMs)) and \(Int(inputProgramMs)))",
                    pointsAdded: 10, runningTotal: points))
            }
        } else {
            trigger = .unknown
            points += 5
            steps.append(.init(
                check: "input timing",
                observation: "input monitoring unavailable (permission not granted?)",
                pointsAdded: 5, runningTotal: points))
        }

        // ── Step 2: Activation policy ─────────────────────────────────────
        switch app.activationPolicy {
        case .accessory:
            points += 30
            steps.append(.init(
                check: "activation policy",
                observation: "accessory app — background helpers shouldn't normally take focus",
                pointsAdded: 30, runningTotal: points))
        case .prohibited:
            points += 40
            steps.append(.init(
                check: "activation policy",
                observation: "prohibited policy — apps with this policy should never have focus",
                pointsAdded: 40, runningTotal: points))
        case .regular:
            steps.append(.init(
                check: "activation policy",
                observation: "regular app (Dock-visible)",
                pointsAdded: 0, runningTotal: points))
        @unknown default:
            steps.append(.init(
                check: "activation policy",
                observation: "unknown policy",
                pointsAdded: 0, runningTotal: points))
        }

        // ── Step 3: Just launched ─────────────────────────────────────────
        if justLaunched {
            points += 20
            steps.append(.init(
                check: "launch timing",
                observation: "activated within \(Int(justLaunchedWindow))s of process launch",
                pointsAdded: 20, runningTotal: points))
        } else {
            steps.append(.init(
                check: "launch timing",
                observation: "process was already running (>\(Int(justLaunchedWindow))s old)",
                pointsAdded: 0, runningTotal: points))
        }

        // ── Step 4: Rapid-switch cluster ──────────────────────────────────
        if recentCount >= rapidThreshold {
            points += 15
            steps.append(.init(
                check: "switch frequency",
                observation: "\(recentCount) focus changes in last \(Int(rapidWindow))s (threshold: \(rapidThreshold))",
                pointsAdded: 15, runningTotal: points))
        } else {
            steps.append(.init(
                check: "switch frequency",
                observation: "\(recentCount) focus changes in last \(Int(rapidWindow))s (below threshold of \(rapidThreshold))",
                pointsAdded: 0, runningTotal: points))
        }

        // ── Step 5: Visible window count ──────────────────────────────────
        if windowCount == 0 {
            points += 10
            steps.append(.init(
                check: "window count",
                observation: "app has 0 visible windows but took focus",
                pointsAdded: 10, runningTotal: points))
        } else {
            steps.append(.init(
                check: "window count",
                observation: "app has \(windowCount) visible window(s)",
                pointsAdded: 0, runningTotal: points))
        }

        // ── Cap & finalize ────────────────────────────────────────────────
        let rawPoints = points
        var capApplied: String? = nil
        let finalScore: Int

        if trigger == .userInput && rawPoints > 15 {
            finalScore = 15
            capApplied = "user_input cap: \(rawPoints) → 15 (user clearly initiated; downweight other signals)"
        } else if rawPoints > 100 {
            finalScore = 100
            capApplied = "max cap: \(rawPoints) → 100"
        } else {
            finalScore = rawPoints
        }

        // Human-readable summary (only the steps that added points)
        let summary = steps
            .filter { $0.pointsAdded > 0 }
            .map { $0.observation }
            .joined(separator: "; ")

        let breakdown = ScoreBreakdown(
            steps: steps,
            finalScore: finalScore,
            capApplied: capApplied,
            trigger: trigger
        )

        return (trigger, finalScore, summary.isEmpty ? "normal" : summary, breakdown)
    }

    // ── Accessibility window info ──────────────────────────────────────────
    //
    // AXUIElementCopyAttributeValue can block for several seconds on
    // misbehaving apps (especially Electron apps mid-launch). We protect
    // the menu bar from freezing by using AXUIElementSetMessagingTimeout
    // to enforce a per-call ceiling. We also avoid force-casts that
    // would crash on type mismatches.

    private func windowInfo(for pid: pid_t) -> (title: String?, windowCount: Int) {
        let app = AXUIElementCreateApplication(pid)

        // Cap each AX call at 250ms — if an app is unresponsive, we'd rather
        // drop the window title than freeze the menu bar.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var title: String? = nil

        // Fetch focused window
        var focusedWinRef: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &focusedWinRef)

        // Use a CFGetTypeID check rather than a force-cast.
        // This pattern is safe even when the AX call returns success
        // with a value of unexpected type (rare but possible).
        if focusedErr == .success,
           let cfRef = focusedWinRef,
           CFGetTypeID(cfRef) == AXUIElementGetTypeID() {
            let focusedWin = cfRef as! AXUIElement   // safe after type check
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                focusedWin, kAXTitleAttribute as CFString, &titleRef) == .success {
                title = titleRef as? String
            }
        }

        // Fetch window count
        var windowsRef: CFTypeRef?
        var count = 0
        if AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let wins = windowsRef as? [AXUIElement] {
            count = wins.count
        }

        return (title, count)
    }

    private func policyName(_ p: NSApplication.ActivationPolicy) -> String {
        switch p {
        case .regular:    return "regular"
        case .accessory:  return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }
}
