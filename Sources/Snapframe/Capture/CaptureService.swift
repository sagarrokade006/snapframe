import AppKit
import ScreenCaptureKit
import SnapframeCore

struct DisplaySnapshot {
    let displayID: CGDirectDisplayID
    /// Global Quartz coordinates: points, origin at the top-left of the primary display.
    let frame: CGRect
    let scale: CGFloat
    let image: CGImage

    var localBounds: CGRect { CGRect(origin: .zero, size: frame.size) }
}

struct VisibleWindow {
    let windowID: CGWindowID
    /// Global Quartz coordinates.
    let frame: CGRect
    let appName: String
    let title: String
}

/// Everything the overlay needs, gathered before it appears.
struct CaptureEnvironment {
    let displays: [DisplaySnapshot]
    /// Front-most first.
    let windows: [VisibleWindow]
}

struct CaptureOptions {
    var showsCursor: Bool
    var convertToSRGB: Bool
    var windowShadow: Bool
}

enum CaptureError: LocalizedError {
    case displayNotFound
    case windowNotFound
    case emptySelection
    case nothingStitched

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "That display is no longer connected."
        case .windowNotFound: return "That window has closed."
        case .emptySelection: return "The selection is empty."
        case .nothingStitched: return "Nothing scrolled. Try again and scroll the page, or select only the part that scrolls."
        }
    }
}

/// All pixels come from ScreenCaptureKit. The app's own windows are always excluded.
@MainActor
final class CaptureService {
    private func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private func ownApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        content.applications.filter { $0.processID == getpid() }
    }

    private func configuration(width: CGFloat, height: CGFloat, options: CaptureOptions) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(width.rounded())
        config.height = Int(height.rounded())
        config.showsCursor = options.showsCursor
        config.captureResolution = .best
        if options.convertToSRGB {
            config.colorSpaceName = CGColorSpace.sRGB
        }
        return config
    }

    private func displayFilter(_ display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        SCContentFilter(
            display: display,
            excludingApplications: ownApplications(in: content),
            exceptingWindows: content.windows.filter { DesktopIconCover.shared.windowIDs.contains($0.windowID) }
        )
    }

    private func capture(_ display: SCDisplay, content: SCShareableContent, options: CaptureOptions) async throws -> DisplaySnapshot {
        let filter = displayFilter(display, content: content)
        let scale = CGFloat(filter.pointPixelScale)
        let config = configuration(
            width: CGFloat(display.width) * scale,
            height: CGFloat(display.height) * scale,
            options: options
        )
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return DisplaySnapshot(displayID: display.displayID, frame: display.frame, scale: scale, image: image)
    }

    func environment(options: CaptureOptions) async throws -> CaptureEnvironment {
        let content = try await content()
        var snapshots: [DisplaySnapshot] = []
        for display in content.displays {
            snapshots.append(try await capture(display, content: content, options: options))
        }
        return CaptureEnvironment(displays: snapshots, windows: visibleWindows(in: content))
    }

    /// CoreGraphics reports stacking order, which ScreenCaptureKit does not guarantee.
    private func visibleWindows(in content: SCShareableContent) -> [VisibleWindow] {
        let known = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        let entries = list as? [[String: Any]] ?? []

        return entries.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? pid_t) != getpid(),
                  ((entry[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 40, bounds.height >= 40,
                  let window = known[id]
            else { return nil }
            return VisibleWindow(
                windowID: id,
                frame: bounds,
                appName: window.owningApplication?.applicationName ?? "Window",
                title: window.title ?? ""
            )
        }
    }

    func captureDisplay(id: CGDirectDisplayID, options: CaptureOptions) async throws -> DisplaySnapshot {
        let content = try await content()
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.displayNotFound
        }
        return try await capture(display, content: content, options: options)
    }

    /// Captures a display-local rectangle from the live screen.
    func captureRegion(
        displayID: CGDirectDisplayID,
        rect: CGRect,
        options: CaptureOptions
    ) async throws -> (image: CGImage, scale: CGFloat) {
        let content = try await content()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let bounds = CGRect(x: 0, y: 0, width: display.width, height: display.height)
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            throw CaptureError.emptySelection
        }

        let filter = displayFilter(display, content: content)
        let scale = CGFloat(filter.pointPixelScale)
        let config = configuration(width: clipped.width * scale, height: clipped.height * scale, options: options)
        config.sourceRect = clipped
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    func captureWindow(
        id: CGWindowID,
        includeWallpaper: Bool,
        options: CaptureOptions
    ) async throws -> (image: CGImage, scale: CGFloat) {
        let content = try await content()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CaptureError.windowNotFound
        }

        if includeWallpaper {
            return try await captureWindowOnWallpaper(window, content: content, options: options)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let size = filter.contentRect.size
        let config = configuration(width: size.width * scale, height: size.height * scale, options: options)
        config.ignoreShadowsSingleWindow = !options.windowShadow
        config.shouldBeOpaque = false
        config.backgroundColor = .clear
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Renders only the wallpaper and the chosen window, so other apps stay out of the picture.
    private func captureWindowOnWallpaper(
        _ window: SCWindow,
        content: SCShareableContent,
        options: CaptureOptions
    ) async throws -> (image: CGImage, scale: CGFloat) {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) else {
            throw CaptureError.displayNotFound
        }

        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let wallpaper = content.windows.filter { $0.windowLayer < iconLevel && $0.windowID != window.windowID }
        let filter = SCContentFilter(display: display, including: wallpaper + [window])
        let scale = CGFloat(filter.pointPixelScale)

        let margin: CGFloat = 60
        let region = window.frame.insetBy(dx: -margin, dy: -margin)
            .intersection(display.frame)
            .offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)

        let config = configuration(width: region.width * scale, height: region.height * scale, options: options)
        config.sourceRect = region
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }
}
