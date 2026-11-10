import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

/// Hides desktop icons by placing the wallpaper just above them. Finder's own settings are never changed.
@MainActor
final class DesktopIconCover: ObservableObject {
    static let shared = DesktopIconCover()

    @Published private(set) var isVisible = false

    private var windows: [NSWindow] = []
    private var spaceObserver: NSObjectProtocol?

    /// Captures must include these windows, otherwise the icons would reappear in the image.
    var windowIDs: Set<CGWindowID> { Set(windows.map { CGWindowID($0.windowNumber) }) }

    private init() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                Task { await self.rebuild() }
            }
        }
    }

    func toggle() async {
        if isVisible { hide() } else { await show() }
    }

    func show() async {
        guard !isVisible else { return }
        isVisible = true
        await rebuild()
    }

    func hide() {
        isVisible = false
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func rebuild() async {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        for screen in NSScreen.screens {
            guard let picture = await wallpaper(for: screen), isVisible else { continue }
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.animationBehavior = .none
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

            let view = NSImageView(image: picture)
            view.imageScaling = .scaleAxesIndependently
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }
        // Gives the window server a moment, so an immediate capture sees the cover.
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    private func wallpaper(for screen: NSScreen) async -> NSImage? {
        if PermissionManager.isScreenRecordingGranted, let image = await capturedWallpaper(for: screen) {
            return image
        }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Rendering the real wallpaper window also handles dynamic and picture-shuffle wallpapers.
    private func capturedWallpaper(for screen: NSScreen) async -> NSImage? {
        guard let id = screen.displayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id })
        else { return nil }

        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let backdrops = content.windows.filter { $0.windowLayer < iconLevel && $0.frame.intersects(display.frame) }
        guard !backdrops.isEmpty else { return nil }

        let filter = SCContentFilter(display: display, including: backdrops)
        let configuration = SCStreamConfiguration()
        configuration.width = display.width * Int(filter.pointPixelScale)
        configuration.height = display.height * Int(filter.pointPixelScale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        return NSImage(cgImage: image, size: screen.frame.size)
    }
}
