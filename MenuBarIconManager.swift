import AppKit
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Icon States
// ─────────────────────────────────────────────────────────────────────────────
//
//  .idle             Normal monitoring — monochrome eye, template mode
//                    Adapts automatically to light/dark menu bar.
//
//  .recentSteal      Something suspicious just happened (< 8s ago).
//                    Eye turns orange with a filled exclamation badge.
//                    Reverts to .idle automatically.
//
//  .sustained        High-frequency stealing — 3+ steals in 60s.
//                    Eye turns red with a count badge (e.g. "5").
//                    Stays until the burst subsides.
//
//  .needsPermission  Accessibility or Input Monitoring not granted.
//                    Eye is gray with a small question-mark overlay.
//                    Disappears once permissions are granted.
//
// ─────────────────────────────────────────────────────────────────────────────

enum MenuBarIconState: Equatable {
    case idle
    case recentSteal(appName: String)
    case sustained(count: Int)
    case needsPermission
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - MenuBarIconManager
// ─────────────────────────────────────────────────────────────────────────────

final class MenuBarIconManager {

    private weak var button: NSStatusBarButton?
    private(set) var state: MenuBarIconState = .needsPermission

    // Burst tracking for .sustained state
    private var recentStealTimes: [Date] = []
    private let sustainedWindow: TimeInterval = 60
    private let sustainedThreshold = 3

    // Revert timer for .recentSteal
    private var revertTimer: Timer?

    // Cache drawn images so we don't redraw on every event
    private var imageCache: [MenuBarIconState: NSImage] = [:]

    init(button: NSStatusBarButton) {
        self.button = button
        applyState(.needsPermission, tooltip: "Focus Tracker — grant permissions to begin")
    }

    // ── External API ───────────────────────────────────────────────────────

    func handleSteal(appName: String) {
        recentStealTimes.append(Date())
        let cutoff = Date().addingTimeInterval(-sustainedWindow)
        recentStealTimes = recentStealTimes.filter { $0 > cutoff }

        if recentStealTimes.count >= sustainedThreshold {
            transition(to: .sustained(count: recentStealTimes.count))
        } else {
            transition(to: .recentSteal(appName: appName))
            scheduleRevert(after: 8)
        }
    }

    func handlePermissionsResolved() {
        if case .needsPermission = state {
            transition(to: .idle)
        }
    }

    func handlePermissionsMissing() {
        revertTimer?.invalidate()
        transition(to: .needsPermission)
    }

    func handleIdle() {
        recentStealTimes.removeAll()
        transition(to: .idle)
    }

    // ── Transitions ────────────────────────────────────────────────────────

    private func transition(to newState: MenuBarIconState) {
        guard newState != state else { return }
        state = newState

        // .sustained overrides the revert timer
        if case .sustained = newState { revertTimer?.invalidate() }

        // Check if sustained has subsided
        if case .sustained(let count) = newState, count < sustainedThreshold {
            transition(to: .idle)
            return
        }

        let tooltip: String
        switch newState {
        case .idle:
            tooltip = "Focus Tracker — monitoring"
        case .recentSteal(let name):
            tooltip = "Focus stolen by \(name)"
        case .sustained(let count):
            tooltip = "\(count) focus steals in the last minute"
        case .needsPermission:
            tooltip = "Focus Tracker — permissions needed"
        }

        applyState(newState, tooltip: tooltip)
    }

    private func applyState(_ s: MenuBarIconState, tooltip: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.button else { return }

            let img = self.image(for: s)
            button.image = img
            // Only use template (auto light/dark) for idle state
            button.image?.isTemplate = (s == .idle)
            button.toolTip = tooltip

            // Accessibility label for VoiceOver
            button.setAccessibilityLabel(tooltip)
        }
    }

    private func scheduleRevert(after seconds: TimeInterval) {
        revertTimer?.invalidate()
        revertTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            // Only revert if we haven't moved to sustained
            if case .recentSteal = self.state {
                self.transition(to: .idle)
            }
        }
    }

    // ── Image rendering ────────────────────────────────────────────────────
    //
    // We draw the icon programmatically so it works without asset catalogs
    // and scales correctly for Retina. The base glyph is the SF Symbol
    // "eye" — we composite badge overlays on top.
    //
    // Size: 18×18 pt (standard menu bar icon size)

    private func image(for state: MenuBarIconState) -> NSImage {
        // Cache key collapses identical visual outputs:
        // - All .recentSteal(*) draw the same icon (no app name in artwork)
        // - .sustained(N) varies by displayed digit (cap at 9+, so 11 keys max)
        // This prevents unbounded cache growth over a long session.
        let cacheKey: MenuBarIconState
        switch state {
        case .recentSteal:                  cacheKey = .recentSteal(appName: "")
        case .sustained(let count):
            // We only display 0-9 or "9+", so collapse 10+ to one key
            cacheKey = .sustained(count: min(count, 10))
        case .idle, .needsPermission:       cacheKey = state
        }
        if let cached = imageCache[cacheKey] { return cached }
        let img = drawIcon(for: state)
        imageCache[cacheKey] = img
        return img
    }

    private func drawIcon(for state: MenuBarIconState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img  = NSImage(size: size, flipped: false) { rect in
            self.drawGlyph(state: state, in: rect)
            return true
        }
        img.isTemplate = false
        return img
    }

    private func drawGlyph(state: MenuBarIconState, in rect: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext

        // ── Eye glyph (SF Symbol "eye", rendered at 14pt) ─────────────────
        let eyeColor: NSColor
        switch state {
        case .idle:            eyeColor = NSColor(white: 0, alpha: 0.85)  // becomes template
        case .recentSteal:     eyeColor = NSColor.systemOrange
        case .sustained:       eyeColor = NSColor.systemRed
        case .needsPermission: eyeColor = NSColor.secondaryLabelColor
        }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let eyeSymbol = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
            eyeSymbol.lockFocus()
            eyeColor.set()
            NSRect(origin: .zero, size: eyeSymbol.size).fill(using: .sourceAtop)
            eyeSymbol.unlockFocus()

            // Center the eye glyph in the 18×18 canvas
            let eyeSize = eyeSymbol.size
            let origin  = NSPoint(
                x: (rect.width  - eyeSize.width)  / 2,
                y: (rect.height - eyeSize.height) / 2 + 1
            )
            eyeSymbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // ── Badge overlay ──────────────────────────────────────────────────
        switch state {

        case .idle, .needsPermission:
            // No badge for idle. For needsPermission, draw a small "?" dot.
            if case .needsPermission = state {
                drawDot(ctx: ctx, color: NSColor.systemYellow, x: 13, y: 13, radius: 3.5)
                drawText("?", ctx: ctx, x: 13, y: 12.5, size: 6,
                         color: NSColor(white: 0, alpha: 0.9))
            }

        case .recentSteal:
            // Orange filled circle with "!" 
            drawDot(ctx: ctx, color: NSColor.systemOrange, x: 13.5, y: 13.5, radius: 3.5)
            drawText("!", ctx: ctx, x: 13.5, y: 13, size: 7,
                     color: .white)

        case .sustained(let count):
            // Red filled circle with count (cap at 9+)
            drawDot(ctx: ctx, color: NSColor.systemRed, x: 13.5, y: 13.5, radius: 4)
            let label = count >= 10 ? "9+" : "\(count)"
            drawText(label, ctx: ctx, x: 13.5, y: 13, size: label.count > 1 ? 5 : 7,
                     color: .white)
        }
    }

    private func drawDot(ctx: CGContext, color: NSColor, x: CGFloat, y: CGFloat, radius: CGFloat) {
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius,
                                   width: radius * 2, height: radius * 2))
    }

    private func drawText(_ text: String, ctx: CGContext, x: CGFloat, y: CGFloat,
                           size: CGFloat, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
        ]
        let str  = NSAttributedString(string: text, attributes: attrs)
        let w    = str.size().width
        let h    = str.size().height
        str.draw(at: NSPoint(x: x - w / 2, y: y - h / 2))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Equatable conformance for caching
// ─────────────────────────────────────────────────────────────────────────────

extension MenuBarIconState: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .idle:                   hasher.combine(0)
        case .recentSteal(let name):  hasher.combine(1); hasher.combine(name)
        case .sustained(let count):   hasher.combine(2); hasher.combine(count)
        case .needsPermission:        hasher.combine(3)
        }
    }
}
