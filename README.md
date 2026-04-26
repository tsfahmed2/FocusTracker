# Focus Tracker

> A macOS menu bar app that detects which apps are stealing your focus — and tells you exactly why.

## Why this exists

Have you ever been mid-sentence, deep in thought, when some background app yanks focus to itself for a notification, an auth prompt, or no apparent reason at all?

That's a focus-stealing app. macOS provides no built-in way to identify what's doing it, when, or why.

Focus Tracker watches every focus change on your Mac and classifies each one as either user-initiated (you clicked or Cmd-Tabbed) or programmatic (an app stole focus on its own). When something steals focus, you get a record of what app, what window, and how suspicious the activity was.

---

## Features

- **Live focus monitoring** — every focus change classified within milliseconds
- **Suspicion scoring (0–100)** — composite score across 5 signals: input timing, app type, launch recency, switch frequency, window state
- **Menu bar status icon** — color-coded: idle (gray), recent steal (orange), sustained burst (red)
- **Native macOS notifications** — alerted only when something genuinely suspicious happens (rate-limited per app)
- **Suspect ranking** — apps repeatedly stealing focus surface to the top
- **Window title capture** — see exactly which dialog or window grabbed focus
- **Ignore list** — silence apps that legitimately need to take focus (your password manager, etc.)
- **Debug mode** — see every signal that contributed to a suspicion score
- **Unified system logging** — full forensic logs in Console.app for after-the-fact analysis
- **Launch at login** — runs quietly in the background

---

## Installation

1. Download the latest `.dmg` from https://github.com/tsfahmed2/FocusTracker/releases
2. Open the DMG and drag **Focus Tracker** to Applications
3. Launch from `/Applications/Focus Tracker.app`
4. The onboarding window will guide you through granting two permissions

### Permissions

Focus Tracker needs two macOS permissions:

| Permission | Why it's needed |
|---|---|
| **Accessibility** | Read the title of windows that take focus, so you can see which dialog is responsible |
| **Input Monitoring** | Detect when you click or type — only timing, never content. This is how user-initiated focus changes are distinguished from programmatic ones |

**Privacy guarantee:** Focus Tracker never reads keystrokes or window contents, only window titles and event timing. No data is sent anywhere — everything stays on your Mac.

---

## How it works

When an app takes focus, Focus Tracker examines five signals:

1. **Input timing** — was there user input within the last ~300ms? (mouse click, Cmd-Tab, keypress)
2. **Activation policy** — is this a regular app, a background helper, or something that shouldn't normally have focus?
3. **Launch timing** — did this app just launch in the last 2 seconds?
4. **Switch frequency** — is there a burst of rapid focus changes happening?
5. **Window state** — does the app have any visible windows?

Each signal contributes points to a 0–100 suspicion score. The final score determines the trigger classification:

- **User-initiated** (green dot, score 0–15): clearly your action
- **Unknown** (gray dot, score 5–15): ambiguous timing
- **Programmatic** (orange dot, score 35–100): no recent input, likely an app acting on its own

Turn on **Debug mode** in Settings to see every signal that contributed to a score. Each event's full trace is also written to Console.app for later analysis.

---

## Usage

### Menu bar icon

| State | Appearance | Meaning |
|---|---|---|
| Idle | Monochrome eye | Everything normal, monitoring quietly |
| Recent steal | Orange eye + `!` badge | Focus was just stolen (last 8 seconds) |
| Sustained | Red eye + count badge | Multiple steals in the last minute |
| Permission needed | Gray eye + `?` badge | Accessibility or Input Monitoring not granted |

**Click** to open the popover.
**Right-click** for quick actions (open Console, privacy settings, quit).

### Recent tab

Live feed of the last 50–100 focus events, newest first. Filter pills:
- **All** — every event
- **Suspicious** — programmatic events only
- **User** — user-initiated events only

Click any row to expand full details. Right-click any event to ignore that app.

### Suspects tab

Apps ranked by composite suspicion (programmatic % × average score). Apps with both >50% programmatic activations and ≥40 average suspicion are flagged as **Definitive Suspects** with a red badge.

### Settings tab

- **Launch at Login** — start automatically when you log in
- **Notifications** — banner alerts above a configurable threshold
- **Permissions** — grant/revoke at any time
- **Ignored Apps** — manage the per-app ignore list
- **Logs** — open Console.app filtered to Focus Tracker
- **Debug mode** — show full scoring breakdowns inline
- **Data** — clear in-app event history

---

## Viewing logs

Focus Tracker writes to the macOS unified system log under subsystem `com.khan.FocusTracker`.

**In Console.app:**
1. Open **Console.app**
2. Search for `subsystem:com.khan.FocusTracker`
3. Optionally filter by category: `lifecycle`, `focus-event`, `anomaly`, `permissions`, `scoring`

**From Terminal:**
```bash
# Live tail
log stream --predicate 'subsystem == "com.khan.FocusTracker"' --level info

# Last hour
log show --last 1h --predicate 'subsystem == "com.khan.FocusTracker"' --info

# Just suspicious events
log show --last 1h --predicate 'subsystem == "com.khan.FocusTracker" AND category == "focus-event" AND eventMessage CONTAINS "programmatic"'
```

---

## Uninstalling

macOS doesn't provide an automated way for apps to clean up their privacy permissions on uninstall. To fully remove Focus Tracker:

1. Quit Focus Tracker (menu bar → Quit)
2. Drag **Focus Tracker** from `/Applications` to Trash
3. Open **System Settings → Privacy & Security → Accessibility**, find **Focus Tracker**, click the minus (−) button
4. Repeat in **System Settings → Privacy & Security → Input Monitoring**
5. (Optional) Open **System Settings → General → Login Items**, remove **Focus Tracker** if listed
6. (Optional) Remove cached preferences:
   ```bash
   defaults delete com.khan.FocusTracker
   ```

---

## Building from source

### Requirements
- macOS 13.0 or later
- Xcode 15+
- Apple Developer Program membership (for distribution; not for local builds)

### Build steps
1. Clone this repository
2. Open `FocusTracker.xcodeproj` in Xcode
3. Select your team in **Signing & Capabilities**
4. Build & run with ⌘R

For full notarization and DMG packaging instructions, see `BUILD.md`.

---

## Architecture

```
AppDelegate           ← status bar item, popover host, permission tracking
    │
    ├── FocusMonitor      ← CGEvent input tap, NSWorkspace observers, scoring
    │
    ├── EventStore        ← ring buffer (500), persistence (100), suspect ranking
    │
    ├── PermissionsManager ← polls AX & Input Monitoring grants
    ├── IgnoredAppsManager ← per-bundle-ID filter
    ├── NotificationManager ← rate-limited UN alerts
    ├── LaunchAtLoginManager ← SMAppService wrapper
    ├── MenuBarIconManager ← 4-state icon machine
    ├── DebugMode          ← global toggle for verbose scoring
    ├── AppLogger          ← os.Logger structured logging
    │
    ├── PopoverView (SwiftUI) ← Recent / Suspects / Settings tabs
    └── OnboardingView (SwiftUI) ← first-launch + revocation prompt
```

---

## FAQ

**Q: Will this slow down my Mac?**
No. The app uses ~30–60 MB of RAM and minimal CPU. The CGEvent tap is listen-only (it observes events, doesn't intercept). All AX calls have a 250ms timeout to prevent any unresponsive apps from hanging the UI.

**Q: Can it record my keystrokes?**
No. The CGEvent tap only records *when* input happens, not what was typed. The code is open source — verify for yourself in `FocusMonitor.swift`.

**Q: Why is Xcode flagged as suspicious?**
When you switch back to Xcode after time away, the gap may exceed the 800ms threshold for "programmatic." This is technically correct behavior — the focus change wasn't user-initiated within the threshold window. Right-click the event to add Xcode to the ignore list.

**Q: Why is Focus Tracker not catching X?**
- Make sure both Accessibility and Input Monitoring permissions are granted
- Some focus changes happen at a system level outside what NSWorkspace exposes (rare)
- Apps in the ignore list are filtered at the source

**Q: Does it run all the time?**
Only when you launch it. Enable **Launch at Login** in Settings to have it start automatically.

---

## License

MIT

---

## Contributing

Issues and pull requests welcome. Please file bugs with:
- macOS version
- Output of: `log show --last 5m --predicate 'subsystem == "com.khan.FocusTracker"' --info`
- Steps to reproduce

---

