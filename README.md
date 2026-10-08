# Restly

[中文说明](README.zh-CN.md)

Restly is a lightweight, native macOS menu bar app that reminds you to drink water, rest your eyes, and stand up — plus a pomodoro timer for focused work.

It doesn't track keyboard or mouse activity. Instead, the question of "is the user away" is left entirely to macOS — locking the screen, display sleep, closing the lid, or switching users all count as leaving. This works beautifully with video players and meeting apps, which actively prevent display sleep: watching a movie or joining a video call won't be misjudged as being away, even though that's exactly when eye-rest reminders matter most.

## Requirements

- macOS 13 or later
- The app runs without Xcode or any development tools
- Building from source requires Xcode Command Line Tools

## Install & Use

Open [`dist/Restly.dmg`](dist/Restly.dmg) and drag `Restly.app` onto the `Applications` shortcut inside the DMG.

Once launched, Restly shows no Dock icon. It lives in the top-right menu bar behind a heart icon; while paused, the icon becomes a crossed-out heart.

Restly never uses system notifications and never asks for notification permission. Water and stand reminders appear in custom-drawn floating windows; eye rest takes over every display with a full-screen overlay.

## Features

- All three reminders share a single timer scheduled directly on the next trigger point, so the CPU wakes up only once every few dozen minutes in normal use
- **Water**: floating window with "Done" and "Remind me in 5 minutes"
- **Stand**: floating window with "I'm up" and "Remind me in 5 minutes", plus an optional click-to-lock action (uses the native system lock screen — same path as Ctrl+Cmd+Q, with fade-in animation)
- **Eye rest**: full-screen overlay with a pure black background, circular countdown, `Esc` to skip, "Remind me in 10 minutes", and auto-close when the countdown ends
- **Pomodoro**: focus/short-break/long-break cycles with configurable durations and long-break interval; while running, the menu bar shows a live countdown next to the heart icon
- Breaks auto-start when a focus ends (configurable); after a break, the next focus waits for you to press start — no mindless tomato chains
- Locking the screen freezes a running pomodoro and resumes it on unlock; a running pomodoro also survives app restarts (if the app was closed longer than the remaining time, that tomato counts as completed)
- Lock screen / display sleep / lid close / fast user switch all count as being away — no timers tick, no reminders pop
- Coming back after being away longer than the threshold (2 minutes by default) resets the eye-rest and stand timers; the water timer is *not* reset, because being away doesn't mean you drank anything
- Absences shorter than the threshold are ignored, and frozen time is added back
- Pause for 30 minutes, 1 hour, 2 hours, or until manually resumed
- Changing one reminder's settings never resets another's running timer
- Settings stored locally in UserDefaults; launch-at-login via the system login-item service
- No accounts, no backend, no network services, no database

## Settings

- **Reminders**: per-type switches and intervals, eye-rest duration, whether floating windows auto-dismiss after 5 seconds, and the away-reset threshold
- **Pomodoro**: focus/short-break/long-break durations, long-break interval, auto-start behavior, and whether the menu bar shows the countdown
- **General**: launch at login

## Build

```bash
./scripts/build.sh
```

This produces:

```text
dist/Restly.app
dist/Restly.dmg
```

The app is ad-hoc signed locally, which is fine for personal use; there is no Developer ID signing or notarization pipeline.

## Development Mode

Development mode shortens intervals to 30s (eye rest) / 60s (water) / 90s (stand) and pomodoro phases to 30s / 10s / 20s, without touching your real settings:

```bash
swift run Restly --development-mode
```

Or run an already-built app:

```bash
RESTLY_DEVELOPMENT_MODE=1 ./dist/Restly.app/Contents/MacOS/Restly
```

In development mode, the settings window also exposes a "Test Full-Screen Eye Rest Now" button.

Available debug flags:

| Flag | Effect |
| --- | --- |
| `--development-mode` | Shorten all three reminder intervals and the pomodoro phases |
| `--show-eye-rest` | Show the full-screen eye rest 1s after launch |
| `--show-settings` | Open the settings window at launch |
| `--show-menu-preview` | Show the menu bar panel as a standalone window |
| `--show-water-preview` | Pop the water reminder immediately |
| `--show-stand-preview` | Pop the stand reminder immediately |
| `--show-pomodoro-preview` | Pop the pomodoro phase-end toast immediately |
| `--open-menu` | Click the real menu bar panel open 2s after launch (for debugging/screenshots) |

## Tests

```bash
swift test
```

## Contributing

Issues and pull requests are welcome! Please open an issue first to discuss significant changes.

## License

[MIT](LICENSE)
