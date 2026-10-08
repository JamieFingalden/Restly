# Restly

[![CI](https://github.com/JamieFingalden/Restly/actions/workflows/ci.yml/badge.svg)](https://github.com/JamieFingalden/Restly/actions/workflows/ci.yml)
[![Download](https://img.shields.io/github/v/release/JamieFingalden/Restly)](https://github.com/JamieFingalden/Restly/releases/latest)

[中文说明](README.zh-CN.md)

Restly is a lightweight, native macOS menu bar app that reminds you to drink water, rest your eyes, and stand up — plus a pomodoro timer for focused work.

It doesn't track keyboard or mouse activity. Instead, the question of "is the user away" is left entirely to macOS — locking the screen, display sleep, closing the lid, or switching users all count as leaving. This works beautifully with video players and meeting apps, which actively prevent display sleep: watching a movie or joining a video call won't be misjudged as being away, even though that's exactly when eye-rest reminders matter most.

## Requirements

- macOS 13 or later
- Apple Silicon or Intel Mac (one universal download)
- The app runs without Xcode or any development tools
- Building from source requires Xcode 26.2 or later, selected with `xcode-select`

## Install & Use

1. [Download Restly.dmg](https://github.com/JamieFingalden/Restly/releases/latest/download/Restly.dmg) from the [latest release](https://github.com/JamieFingalden/Restly/releases/latest).
2. Open the DMG and drag `Restly.app` onto the `Applications` shortcut.
3. Open Restly from Applications. The same DMG works on Apple Silicon and Intel Macs.

Releases are ad-hoc signed and are not notarized by Apple. If macOS blocks the first launch, go to **System Settings → Privacy & Security → Open Anyway**, then confirm Open. This is Apple's [documented way to open an app from an unidentified developer](https://support.apple.com/en-us/102445).

You can also download `SHA256SUMS.txt` from the same release and verify the DMG in the directory containing both files:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

Once launched, Restly shows no Dock icon. It lives in the top-right menu bar behind a heart icon; while paused, the icon becomes a crossed-out heart.

The app interface is currently in Chinese. No account or subscription is required.

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
dist/SHA256SUMS.txt
```

The app is built for both `arm64` and `x86_64` and ad-hoc signed. Validate the package before distributing it:

```bash
./scripts/verify-release.sh
```

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

## CI & Releases

GitHub Actions runs the tests on Intel/macOS 15 and Apple Silicon/macOS 26, then builds and validates a universal DMG on every push to `main` and every pull request. Installers are saved as workflow artifacts.

To publish a release, update `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist`, commit the change, and push a matching tag such as `v0.2.0`. The same workflow tests and packages the tagged source, checks that the tag matches the app version, and publishes the DMG and SHA-256 checksum only after all checks pass. Published release assets are never overwritten by a rerun.

## Contributing

Issues and pull requests are welcome! Please open an issue first to discuss significant changes.

## License

[MIT](LICENSE)
