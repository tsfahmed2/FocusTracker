import AppKit
import SwiftUI
import Combine
import ServiceManagement

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - App Entry Point
// ─────────────────────────────────────────────────────────────────────────────

@main
struct FocusTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppDelegate
// ─────────────────────────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var statusItem:        NSStatusItem!
    private var popover:           NSPopover!
    private var onboardingWindow:  NSWindow?
    private var monitor:           FocusMonitor!
    private var iconManager:       MenuBarIconManager!
    private var cancellables       = Set<AnyCancellable>()

    // Track previous permission state so we can detect revocation
    private var lastPermissionState: (acc: Bool, input: Bool)?

    private let onboardingKey = "ft.onboardingComplete"

    func applicationDidFinishLaunching(_ note: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        startMonitoring()
        subscribeToEvents()
        subscribeToPermissions()
        NotificationManager.shared.requestAuthorization()

        let perms = PermissionsManager.shared
        AppLogger.shared.logStartup(
            inputMonitoring: perms.inputMonitoringGranted,
            accessibility:   perms.accessibilityGranted
        )

        // Show onboarding on first launch, OR if any permission is missing.
        // This handles three cases at once:
        //   1. Fresh install (onboardingKey is false)
        //   2. App reinstalled — permissions still set from before
        //   3. Permissions revoked between launches
        if shouldShowOnboarding() {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        AppLogger.shared.logShutdown()
    }

    // ── Onboarding ─────────────────────────────────────────────────────────

    private func shouldShowOnboarding() -> Bool {
        let firstLaunch = !UserDefaults.standard.bool(forKey: onboardingKey)
        let missing     = !PermissionsManager.shared.allGranted
        return firstLaunch || missing
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let controller = NSHostingController(rootView: OnboardingView {
                self.completeOnboarding()
            })
            let window = NSWindow(contentViewController: controller)
            window.title          = "Welcome to Focus Tracker"
            window.styleMask      = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: onboardingKey)
        onboardingWindow?.close()
    }

    // ── Status bar ─────────────────────────────────────────────────────────

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(handleStatusBarClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        iconManager = MenuBarIconManager(button: button)
    }

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        event.type == .rightMouseUp ? showContextMenu() : togglePopover()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Focus Tracker",
                     action: #selector(showPopoverFromMenu), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "View Logs in Console",
                     action: #selector(openConsole), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Privacy Settings",
                     action: #selector(openPrivacySettings), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Focus Tracker",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showPopoverFromMenu() { showPopover() }

    @objc private func openConsole() {
        // Open Console.app and put a useful filter string on the clipboard.
        // (Console.app doesn't accept filter args from URL or AppleScript,
        // so the best we can do is one paste away.)
        let bid = Bundle.main.bundleIdentifier ?? "com.khan.FocusTracker"
        let filter = "subsystem:\(bid)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(filter, forType: .string)

        // Open Console.app via NSWorkspace
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openPrivacySettings() {
        PermissionsManager.shared.openAccessibilitySettings()
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Note: popover.behavior = .transient already auto-dismisses on
        // outside clicks. We previously had a global event monitor here
        // but it leaked one observer per popover open and was redundant.
    }

    // ── Popover ────────────────────────────────────────────────────────────

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior  = .transient
        popover.animates  = true
        popover.contentViewController = NSHostingController(
            rootView: PopoverView().frame(width: 400, height: 500)
        )
    }

    // ── Monitoring ─────────────────────────────────────────────────────────

    private func startMonitoring() {
        monitor = FocusMonitor()
        monitor.start()
    }

    // ── Icon subscriptions ─────────────────────────────────────────────────

    private func subscribeToEvents() {
        EventStore.shared.$stats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stats in
                guard let self else { return }
                if let app = stats.lastStealApp,
                   let time = stats.lastStealTime,
                   Date().timeIntervalSince(time) < 1.0 {
                    self.iconManager.handleSteal(appName: app)
                }
            }
            .store(in: &cancellables)
    }

    // ── Permission tracking + auto re-prompt ───────────────────────────────

    private func subscribeToPermissions() {
        PermissionsManager.shared.$accessibilityGranted
            .combineLatest(PermissionsManager.shared.$inputMonitoringGranted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] acc, input in
                self?.handlePermissionStateChange(acc: acc, input: input)
            }
            .store(in: &cancellables)
    }

    /// Called whenever permission state changes. Detects revocation
    /// (granted → not granted) and re-shows the onboarding window.
    private func handlePermissionStateChange(acc: Bool, input: Bool) {
        // Log every transition
        if let prev = lastPermissionState {
            if prev.acc != acc {
                AppLogger.shared.logPermissionChange(name: "accessibility", granted: acc)
            }
            if prev.input != input {
                AppLogger.shared.logPermissionChange(name: "input-monitoring", granted: input)
            }
        }

        let wasFullyGranted = lastPermissionState.map { $0.acc && $0.input } ?? false
        let isFullyGranted  = acc && input
        lastPermissionState = (acc, input)

        // Update menu bar icon
        if isFullyGranted {
            iconManager.handlePermissionsResolved()
        } else {
            iconManager.handlePermissionsMissing()
        }

        // Re-prompt logic:
        // If we WERE fully granted and are NOT anymore, the user revoked
        // something in System Settings. Re-show onboarding.
        if wasFullyGranted && !isFullyGranted {
            AppLogger.shared.logPermissionError("Permissions revoked at runtime — re-prompting user")
            showOnboarding()
        }
    }

    // ── Launch at Login ────────────────────────────────────────────────────

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLogger.shared.logError("launch-at-login",
                "Failed to \(enabled ? "register" : "unregister"): \(error.localizedDescription)")
        }
    }
}
