<img src="docs/icon.png" width="128" alt="Snapframe app icon">

# Snapframe

A free menu-bar screenshot app for macOS 14 and later.

Snapframe has no accounts, uploads, online models, analytics or crash reporting. Its only network use is checking GitHub for app updates.

## Screenshots

![Snapframe Home window with capture tiles and recent captures](docs/screenshots/home.png)

![Annotate editor with markup tools and a background](docs/screenshots/annotate.png)

![Capture overlay with selection, aspect ratios and after-capture choices](docs/screenshots/overlay.png)

| Menu bar | Software update |
|---|---|
| ![Menu bar popover](docs/screenshots/popover.png) | ![Update window with changelog](docs/screenshots/update.png) |

| File names | Shortcuts |
|---|---|
| ![File name builder](docs/screenshots/settings.png) | ![Shortcut settings](docs/screenshots/shortcuts.png) |

## Features

- Capture an area, window or full screen, repeat the previous area, or use a self-timer
- Aspect ratios, freeze screen, edge snapping and a loupe with color readout
- A private library with search, tags, pinning and auto-delete
- A preview card after every capture, and floating images that stay on top
- An Annotate editor with arrows, shapes, text, counters, spotlight, redaction and backgrounds
- Editable projects, password-protected PDFs and the macOS share sheet
- Custom file names, PNG, JPEG or HEIC, and global shortcuts
- In-app updates with a changelog

## Install

1. Download the DMG from [Releases](https://github.com/sagarrokade006/snapframe/releases/latest).
2. Open it and drag Snapframe to Applications.
3. Open Snapframe. macOS will block the first launch because the app is not notarized. Go to System Settings > Privacy & Security and choose **Open Anyway**.
4. Grant Screen Recording when asked, then restart Snapframe from its window.

Snapframe has no Dock icon. Look for its icon in the menu bar. Opening the app again shows Home.

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
