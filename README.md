# Snapframe

A free menu-bar screenshot app for macOS 14 and later.

Snapframe has no accounts, uploads, online models, analytics or crash reporting. Its only network use is checking GitHub for app updates.

## Install

1. Download the DMG from [Releases](https://github.com/sagarrokade006/snapframe/releases/latest).
2. Open it and drag Snapframe to Applications.
3. Open Snapframe. macOS will block the first launch because the app is not notarized. Go to System Settings > Privacy & Security and choose **Open Anyway**.
4. Grant Screen Recording when asked, then restart Snapframe from its window.

Later versions install from inside the app, and your settings and permissions stay as they are.

## Default shortcuts

| Action | Shortcut |
|---|---|
| All-In-One | ⌃⌥1 |
| Capture Area | ⌃⌥4 |
| Capture Previous Area | ⌃⌥P |
| Capture Window | ⌃⌥5 |
| Capture Fullscreen | ⌃⌥3 |
| Self-Timer | ⌃⌥T |

In the overlay, press A, W or F to switch modes, T to cycle the timer, Return to confirm and Esc to cancel. Hold Shift for a square area or to include the wallpaper with a window. Hold Control to copy without saving. Hold Command to turn off edge snapping.

## Development

```bash
swift build
swift test
```
