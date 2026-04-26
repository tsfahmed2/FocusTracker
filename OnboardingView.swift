import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - OnboardingView
//
// First-launch welcome and permission setup window. Also re-shown when
// permissions are revoked at runtime. Always-on-top, modal-feeling but
// not actually modal (so the menu bar still works).
// ─────────────────────────────────────────────────────────────────────────────

struct OnboardingView: View {
    @ObservedObject private var perms = PermissionsManager.shared

    /// Called when the user clicks Continue once everything is granted.
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // ── Header ─────────────────────────────────────────────────────────────

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.trianglebadge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Welcome to Focus Tracker")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Detect which apps are stealing your focus")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // ── Permission rows ────────────────────────────────────────────────────

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Focus Tracker needs two permissions to work:")
                .font(.callout)

            permissionCard(
                icon: "hand.raised.fill",
                title: "Accessibility",
                description: "Read window titles when an app takes focus, so we can identify exactly which dialog or notification is responsible.",
                granted: perms.accessibilityGranted,
                primary: { perms.requestAccessibility() },
                secondary: { perms.openAccessibilitySettings() }
            )

            permissionCard(
                icon: "keyboard.fill",
                title: "Input Monitoring",
                description: "Observe when you click or type — only the timing, never the content. This is how we tell user-initiated focus changes from programmatic ones.",
                granted: perms.inputMonitoringGranted,
                primary: { perms.openInputMonitoringSettings() },
                secondary: { perms.openInputMonitoringSettings() }
            )

            // Privacy note
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your data stays on your Mac")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("Focus Tracker never reads keystrokes or window contents, only window titles and event timing. No data is sent anywhere.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color.green.opacity(0.06))
            .cornerRadius(6)
        }
        .padding(20)
    }

    private func permissionCard(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        primary: @escaping () -> Void,
        secondary: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(granted ? .green : .orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.callout)
                        .fontWeight(.semibold)
                    Spacer()
                    if granted {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Granted")
                        }
                        .font(.caption)
                        .foregroundColor(.green)
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !granted {
                    HStack(spacing: 6) {
                        Button("Grant", action: primary)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                        Button("Open Settings", action: secondary)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(12)
        .background(granted ? Color.green.opacity(0.06) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // ── Footer ─────────────────────────────────────────────────────────────

    private var footer: some View {
        HStack {
            Button("Skip for now") { onComplete() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

            Spacer()

            Button(perms.allGranted ? "Continue" : "Continue with Limited Functionality") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .tint(perms.allGranted ? .green : .gray)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
