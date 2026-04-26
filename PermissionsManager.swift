import AppKit
import ApplicationServices
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PermissionsManager
//
// Polls system permission state every 2 seconds so the UI reacts when the
// user grants or revokes permissions in System Settings without us needing
// to be relaunched.
//
// Two important constraints:
//
// 1. We cache positive Input Monitoring results and DO NOT re-probe.
//    Every CGEvent.tapCreate call with no permission triggers a system
//    log entry. Once we know we have it, the FocusMonitor's tap will
//    keep working — there's no way to lose Input Monitoring while the
//    process is running (revocation only takes effect after relaunch).
//
// 2. @Published values are only assigned when they actually change.
//    Otherwise SwiftUI re-renders every 2 seconds even when nothing
//    is happening, wasting CPU.
// ─────────────────────────────────────────────────────────────────────────────

final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published private(set) var accessibilityGranted: Bool = false
    @Published private(set) var inputMonitoringGranted: Bool = false

    /// True when the app has everything it needs for full functionality.
    var allGranted: Bool { accessibilityGranted && inputMonitoringGranted }

    private var pollTimer: Timer?

    /// True once we've successfully created a CGEvent tap. Once true,
    /// stays true for the process lifetime — Input Monitoring revocation
    /// only takes effect after relaunch.
    private var inputMonitoringConfirmed = false

    private init() {
        refresh()
        startPolling()
    }

    // ── Check ──────────────────────────────────────────────────────────────

    func refresh() {
        let newAcc   = AXIsProcessTrusted()
        let newInput = checkInputMonitoring()

        // Only assign if changed — prevents SwiftUI re-render storms.
        if newAcc != accessibilityGranted {
            accessibilityGranted = newAcc
        }
        if newInput != inputMonitoringGranted {
            inputMonitoringGranted = newInput
        }
    }

    /// Input Monitoring has no direct API to check — we probe by attempting
    /// to create a passive event tap. We cache the positive result to avoid
    /// re-probing every poll cycle (each probe creates a system log entry).
    private func checkInputMonitoring() -> Bool {
        if inputMonitoringConfirmed { return true }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passRetained(event) },
            userInfo: nil
        ) else { return false }

        // Got the tap → permission is granted. Tear down and remember.
        CFMachPortInvalidate(tap)
        inputMonitoringConfirmed = true
        return true
    }

    // ── Request / Open Settings ────────────────────────────────────────────

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    func openInputMonitoringSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        )
    }

    // ── Polling (so UI reacts when user grants mid-session) ────────────────

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
