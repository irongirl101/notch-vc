# Notch

`Notch` is a small macOS app that turns the menu-bar notch area into a hoverable control surface. It shows live media playback, battery status, clipboard history, quick system actions, and lightweight system stats inside a custom notch-shaped overlay.

This entire project was vibe coded end to end.
It is also intentionally hyper-specific to a narrow group of users, especially people who listen to music through Spotify in Brave.

## What it does

- Expands on hover and collapses back into a compact notch.
- Shows the current track, album art, playback state, and transport controls.
- Falls back to Spotify in Brave when system now-playing data is unavailable.
- Displays battery percentage, charging state, and low power mode.
- Keeps a short clipboard history and lets you copy items back with one click.
- Offers quick actions for mic mute, output mute, screenshot, and screen lock.
- Shows CPU, RAM, disk, network speed, and uptime when expanded.

## How it works

- The app is a borderless `NSWindow` pinned above the menu bar.
- Hovering the notch expands the window into a three-column dashboard.
- Media playback uses Apple’s private `MediaRemote` APIs when available.
- When Spotify is open in Brave, the app can scrape metadata and drive playback through AppleScript + JavaScript.
- Battery, clipboard, system controls, and system stats are polled from macOS APIs and command-line tools.

## Requirements

- macOS 12.0 or later
- Xcode Command Line Tools or a recent Swift toolchain
- Permission for Automation / Apple Events if you want Brave Spotify integration

## Build

From the repository root:

```bash
./build.sh
```

That script:

- Compiles `NotchApp.swift` into `Notch.app`
- Copies `Info.plist` and `AppIcon.icns`
- Signs the app bundle with a local identity used by the repo

If you prefer to build manually, the app entry point is `NotchApp.swift`.

## Run

After building:

```bash
open Notch.app
```

The app runs as a menu-bar style agent, so it does not show a Dock icon.

## Permissions

For the full experience, macOS may prompt for:

- Accessibility / Automation access for AppleScript control
- Permission to control Brave Browser if Spotify fallback is used

If Brave blocks JavaScript from Apple Events, the app will show a helper message in the now-playing panel.

## Repository layout

- `NotchApp.swift` - main app implementation
- `Info.plist` - bundle metadata and permissions text
- `build.sh` - build, bundle, and sign script
- `AppIcon.icns` - app icon
- `test_notch.swift` - simple notch UI test harness
- `test_notification.swift` - MediaRemote notification probe
- `mr_test.swift` - MediaRemote now-playing probe

## Notes

- Clipboard history currently keeps the most recent 5 text items.
- The Spotify fallback is intentionally scoped to Brave.
- The app is intentionally lightweight and mostly self-contained in a single Swift file.

## License

MIT
