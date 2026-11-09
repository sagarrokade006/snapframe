#if DEBUG
import AppKit
import ImageIO
import SnapframeCore
import SwiftUI

/// Debug-only check: draws the overlay and exercises file output with a synthetic screen,
/// so both can be inspected without Screen Recording permission.
@MainActor
enum PreviewRenderer {
    private static let size = CGSize(width: 1280, height: 800)
    private static let scale: CGFloat = 2

    static func run(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let snapshot = DisplaySnapshot(
            displayID: 1,
            frame: CGRect(origin: .zero, size: size),
            scale: scale,
            image: syntheticScreen()
        )
        let window = VisibleWindow(
            windowID: 42,
            frame: CGRect(x: 180, y: 70, width: 920, height: 600),
            appName: "Field Notes",
            title: "Launch notes"
        )
        let environment = CaptureEnvironment(displays: [snapshot], windows: [window])

        func session(_ mode: OverlaySession.Mode, adjust: Bool = false) -> OverlaySession {
            OverlaySession(environment: environment, mode: mode, timer: 0, freeze: true, adjustBeforeCapture: adjust)
        }

        let idle = session(.area)
        idle.mouseMoved(to: CGPoint(x: 640, y: 300), on: snapshot)
        write(idle, snapshot, "1-area-idle", directory)

        let drawing = session(.area)
        drawing.mouseMoved(to: CGPoint(x: 400, y: 170), on: snapshot)
        drawing.mouseDown(at: CGPoint(x: 400, y: 170), on: snapshot)
        drawing.mouseDragged(to: CGPoint(x: 1000, y: 500), on: snapshot)
        write(drawing, snapshot, "2-area-drawing", directory)

        let adjusting = session(.area, adjust: true)
        adjusting.mouseMoved(to: CGPoint(x: 400, y: 170), on: snapshot)
        adjusting.mouseDown(at: CGPoint(x: 400, y: 170), on: snapshot)
        adjusting.mouseDragged(to: CGPoint(x: 1000, y: 500), on: snapshot)
        adjusting.mouseUp(on: snapshot)
        write(adjusting, snapshot, "3-area-adjusting", directory)

        let windowMode = session(.window)
        windowMode.mouseMoved(to: CGPoint(x: 640, y: 300), on: snapshot)
        write(windowMode, snapshot, "4-window", directory)

        let fullscreen = session(.fullscreen)
        fullscreen.mouseMoved(to: CGPoint(x: 640, y: 300), on: snapshot)
        write(fullscreen, snapshot, "5-fullscreen", directory)

        writeHosted(SettingsView(pane: .general), "6-settings-general", CGSize(width: 760, height: 580), directory)
        writeHosted(SettingsView(pane: .screenshots), "7-settings-screenshots", CGSize(width: 760, height: 580), directory)
        writeHosted(SettingsView(pane: .shortcuts), "8-settings-shortcuts", CGSize(width: 760, height: 580), directory)
        writeHosted(OnboardingView(close: {}), "9-onboarding", CGSize(width: 440, height: 300), directory)

        await checkOutput(snapshot: snapshot, directory: directory)
    }

    /// Exercises real capture and shortcut registration. Prints only sizes and counts, and writes nothing.
    static func liveCheck() async {
        let service = CaptureService()
        let options = CaptureOptions(showsCursor: false, convertToSRGB: true, windowShadow: true)
        print("preflight granted: \(PermissionManager.isScreenRecordingGranted)")
        do {
            let environment = try await service.environment(options: options)
            for display in environment.displays {
                print("display \(Int(display.frame.width))x\(Int(display.frame.height)) scale \(display.scale) image \(display.image.width)x\(display.image.height)")
            }
            print("windows found: \(environment.windows.count)")
            if let display = environment.displays.first {
                let region = try await service.captureRegion(displayID: display.displayID, rect: CGRect(x: 10, y: 20, width: 100, height: 50), options: options)
                print("region 100x50 pt: \(region.image.width)x\(region.image.height) scale \(region.scale)")
            }
            if let window = environment.windows.first {
                let plain = try await service.captureWindow(id: window.windowID, includeWallpaper: false, options: options)
                print("window \(Int(window.frame.width))x\(Int(window.frame.height)) pt: \(plain.image.width)x\(plain.image.height)")
                let framed = try await service.captureWindow(id: window.windowID, includeWallpaper: true, options: options)
                print("window on wallpaper: \(framed.image.width)x\(framed.image.height)")
            }
        } catch {
            print("capture error: \(error)")
        }
        HotKeyCenter.shared.register(Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) }))
        print("shortcuts refused: \(HotKeyCenter.shared.failed.count) of \(ShortcutAction.allCases.count)")
    }

    private static func write(_ session: OverlaySession, _ snapshot: DisplaySnapshot, _ name: String, _ directory: URL) {
        let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: size), session: session, snapshot: snapshot)
        save(view, name, directory)
    }

    private static func writeHosted<V: View>(_ root: V, _ name: String, _ viewSize: CGSize, _ directory: URL) {
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: viewSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        save(host, name, directory)
    }

    private static func save(_ view: NSView, _ name: String, _ directory: URL) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = bitmap.representation(using: .png, properties: [:])
        try? data?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func checkOutput(snapshot: DisplaySnapshot, directory: URL) async {
        let output = directory.appendingPathComponent("output")
        try? FileManager.default.removeItem(at: output)

        let crop = SelectionGeometry.pixelCrop(
            CGRect(x: 400, y: 170, width: 600, height: 330),
            scale: scale,
            imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height)
        )
        guard let image = snapshot.image.cropping(to: crop) else {
            print("output: crop failed")
            return
        }

        for (format, oneX) in [(ImageFormat.png, false), (.jpeg, false), (.heic, false), (.png, true), (.png, false)] {
            let request = OutputRequest(
                image: image, scale: scale, modeName: "Area", saves: true, copies: false,
                format: format, quality: 0.9, scaleTo1x: oneX,
                namePattern: "{mode} fixed", directory: output
            )
            do {
                let result = try await OutputService.process(request)
                guard let url = result.savedURL,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                else {
                    print("output \(format.title): failed \(result.saveError ?? "")")
                    continue
                }
                print("output \(url.lastPathComponent): \(info[kCGImagePropertyPixelWidth] ?? "?")x\(info[kCGImagePropertyPixelHeight] ?? "?") dpi \(info[kCGImagePropertyDPIWidth] ?? "?")")
            } catch {
                print("output \(format.title): \(error)")
            }
        }
    }

    private static func syntheticScreen() -> CGImage {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(srgbRed: 0.18, green: 0.25, blue: 0.27, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        context.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 180, y: 130, width: 920, height: 600))
        context.setFillColor(CGColor(srgbRed: 0.91, green: 0.91, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 180, y: 690, width: 920, height: 40))

        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.48, alpha: 1))
        for row in 0..<14 {
            let lineWidth = CGFloat(420 + (row * 53) % 260)
            context.fill(CGRect(x: 240, y: 640 - CGFloat(row) * 34, width: lineWidth, height: 10))
        }
        return context.makeImage()!
    }
}
#endif
